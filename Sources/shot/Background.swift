import AppKit
import CoreImage

/// Evens out uneven margins around a screenshot's content (CleanShot's "Auto-balance").
/// Finds the run of uniform-colored rows/columns on each edge and trims every side down to the smallest one.
enum Balance {
    static func compute(_ img: CGImage, tolerance: Int = 12) -> (rect: CGRect, margins: [String: Int])? {
        let W = img.width, H = img.height
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = ctx.data else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
        let px = data.bindMemory(to: UInt8.self, capacity: W * H * 4)
        let o0 = 0
        let ref = (Int(px[o0]), Int(px[o0 + 1]), Int(px[o0 + 2]))
        func near(_ x: Int, _ y: Int) -> Bool {
            let o = (y * W + x) * 4
            return abs(Int(px[o]) - ref.0) <= tolerance && abs(Int(px[o + 1]) - ref.1) <= tolerance && abs(Int(px[o + 2]) - ref.2) <= tolerance
        }
        guard near(W - 1, 0), near(0, H - 1), near(W - 1, H - 1) else { return nil }
        func row(_ y: Int) -> Bool { (0..<W).allSatisfy { near($0, y) } }
        func col(_ x: Int) -> Bool { (0..<H).allSatisfy { near(x, $0) } }
        var top = 0
        while top < H && row(top) { top += 1 }
        guard top < H else { return nil }
        var bottom = 0
        while bottom < H - top && row(H - 1 - bottom) { bottom += 1 }
        var left = 0
        while left < W && col(left) { left += 1 }
        var right = 0
        while right < W - left && col(W - 1 - right) { right += 1 }
        let m = min(top, bottom, left, right)
        let rect = CGRect(x: left - m, y: top - m, width: W - (left - m) - (right - m), height: H - (top - m) - (bottom - m))
        return (rect, ["top": top, "bottom": bottom, "left": left, "right": right, "balanced_to": m])
    }
}

enum Background {
    static let presets: [String: [String]] = [
        "violet": ["#8E2DE2", "#4A00E0"], "sunset": ["#FF7E5F", "#FEB47B"], "ocean": ["#2E3192", "#1BFFFF"],
        "mint": ["#43E97B", "#38F9D7"], "dusk": ["#141E30", "#243B55"], "peach": ["#FFDDE1", "#EE9CA7"],
        "candy": ["#FC5C7D", "#6A82FB"], "slate": ["#373B44", "#4286F4"],
    ]

    static func apply(_ bg: Args, to img: CGImage, unit: CGFloat) throws -> CGImage {
        let short = CGFloat(min(img.width, img.height))
        let inset = CGFloat(num(bg, "inset") ?? 0)
        let padding = CGFloat(num(bg, "padding") ?? Double((short * 0.08).rounded()))
        let radius = CGFloat(num(bg, "corner_radius") ?? Double(unit))
        let shadow = CGFloat(num(bg, "shadow") ?? 40)
        let cw = CGFloat(img.width) + inset * 2, ch = CGFloat(img.height) + inset * 2
        var W = cw + padding * 2, H = ch + padding * 2
        if let r = ratio(bg["ratio"]) {
            if W / H < r { W = (H * r).rounded() } else { H = (W / r).rounded() }
        }
        let (fx, fy) = alignment(bg["alignment"] as? String ?? "center")
        let ox = padding + (W - padding * 2 - cw) * fx, oy = padding + (H - padding * 2 - ch) * fy

        guard let ctx = makeContext(Int(W), Int(H), space: rgbSpace(img)) else { throw ShotError("Couldn't create a canvas") }
        let canvas = CGRect(x: 0, y: 0, width: Int(W), height: Int(H))
        try fill(ctx, canvas, bg, img)

        let content = CGRect(x: ox, y: H - oy - ch, width: cw, height: ch)
        let path = CGPath(roundedRect: content, cornerWidth: min(radius, cw / 2), cornerHeight: min(radius, ch / 2), transform: nil)
        let insetColor = bg["inset_color"] != nil ? color(bg["inset_color"], "#FFFFFF") : pixelColor(img)
        if shadow > 0 {
            let blur = shadow / 100 * short * 0.06
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -blur * 0.3), blur: blur, color: CGColor(gray: 0, alpha: min(0.6, 0.25 + shadow / 250)))
            ctx.setFillColor(insetColor)
            ctx.addPath(path); ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        if inset > 0 { ctx.setFillColor(insetColor); ctx.fill(content) }
        ctx.draw(img, in: CGRect(x: content.minX + inset, y: content.minY + inset, width: CGFloat(img.width), height: CGFloat(img.height)))
        ctx.restoreGState()
        guard let out = ctx.makeImage() else { throw ShotError("Couldn't render the background") }
        return out
    }

    private static func ratio(_ v: Any?) -> CGFloat? {
        if let n = v as? NSNumber { return CGFloat(n.doubleValue) }
        guard let s = v as? String else { return nil }
        let parts = s.split(whereSeparator: { $0 == ":" || $0 == "/" || $0 == "x" }).compactMap { Double($0) }
        return parts.count == 2 && parts[1] > 0 ? CGFloat(parts[0] / parts[1]) : nil
    }

    private static func alignment(_ s: String) -> (CGFloat, CGFloat) {
        let x: CGFloat = s.contains("left") ? 0 : s.contains("right") ? 1 : 0.5
        let y: CGFloat = s.contains("top") ? 0 : s.contains("bottom") ? 1 : 0.5
        return (x, y)
    }

    private static func fill(_ ctx: CGContext, _ canvas: CGRect, _ bg: Args, _ img: CGImage) throws {
        let type = bg["type"] as? String ?? (bg["image"] != nil ? "image" : bg["color"] != nil ? "color" : "gradient")
        switch type {
        case "none", "transparent":
            break
        case "color":
            ctx.setFillColor(color(bg["color"], "#FFFFFF")); ctx.fill(canvas)
        case "gradient":
            let hexes = bg["colors"] as? [String] ?? presets[bg["preset"] as? String ?? "violet"] ?? presets["violet"]!
            let g = CGGradient(colorsSpace: sRGB, colors: hexes.map { color($0, "#000000") } as CFArray, locations: nil)!
            // angle: 0 = left→right, 90 = top→bottom
            let a = CGFloat(num(bg, "angle") ?? 135) * .pi / 180
            let half = (abs(cos(a)) * canvas.width + abs(sin(a)) * canvas.height) / 2
            let d = CGPoint(x: cos(a) * half, y: -sin(a) * half)
            ctx.drawLinearGradient(g, start: CGPoint(x: canvas.midX - d.x, y: canvas.midY - d.y),
                                   end: CGPoint(x: canvas.midX + d.x, y: canvas.midY + d.y),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case "blurred":
            try drawFilling(ctx, canvas, img, blur: true)
        case "wallpaper":
            try drawFilling(ctx, canvas, try wallpaper(), blur: flag(bg, "blur"))
        case "image":
            guard let p = bg["image"] as? String else { throw ShotError("background type image needs an image path") }
            try drawFilling(ctx, canvas, try loadImage(p), blur: flag(bg, "blur"))
        default:
            throw ShotError("unknown background type '\(type)' (use gradient, color, blurred, wallpaper, image or none)")
        }
    }

    /// Draws `img` scaled to cover the canvas, optionally blurred.
    private static func drawFilling(_ ctx: CGContext, _ canvas: CGRect, _ img: CGImage, blur: Bool) throws {
        var src = img
        if blur {
            let ci = CIImage(cgImage: img)
            let f = CIFilter(name: "CIGaussianBlur")!
            f.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
            f.setValue(Double(max(img.width, img.height)) * 0.025, forKey: kCIInputRadiusKey)
            if let out = f.outputImage?.cropped(to: ci.extent),
               let cg = CIContext().createCGImage(out, from: ci.extent) { src = cg }
        }
        let scale = max(canvas.width / CGFloat(src.width), canvas.height / CGFloat(src.height))
        let w = CGFloat(src.width) * scale, h = CGFloat(src.height) * scale
        ctx.interpolationQuality = .high
        ctx.draw(src, in: CGRect(x: canvas.midX - w / 2, y: canvas.midY - h / 2, width: w, height: h))
    }

    private static func wallpaper() throws -> CGImage {
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { throw ShotError("Couldn't find the desktop wallpaper") }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            throw ShotError("The wallpaper is a rotating folder; pass background.image with a file path instead")
        }
        return try loadImage(url.path)
    }
}
