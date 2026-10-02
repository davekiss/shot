import AppKit
import CoreImage

/// What a mark is drawn in: the ink, and the halo keyline that separates it from what's underneath.
struct Ink {
    let ink: CGColor, halo: CGColor

    static let dark = CGColor(srgbRed: 0.08, green: 0.08, blue: 0.08, alpha: 1)
    static let light = CGColor(srgbRed: 0.97, green: 0.97, blue: 0.96, alpha: 1)

    /// The halo always matches what's underneath, so it separates the mark
    /// without outlining it. With no color given, the ink is the opposite:
    /// near-black on light screens, near-white on dark ones.
    static func resolve(_ value: Any?, over region: CGRect, in img: CGImage) -> Ink {
        let bright = region.isEmpty ? true : Annotator.luminance(img, region) > 0.5
        let halo = bright ? light.copy(alpha: 0.95)! : dark.copy(alpha: 0.85)!
        if value != nil { return Ink(ink: color(value, defaultColor), halo: halo) }
        return Ink(ink: bright ? dark : light, halo: halo)
    }

    static func opposite(of c: CGColor) -> CGColor { luminance(of: c) < 0.6 ? light : dark }

    static func luminance(of c: CGColor) -> Double {
        guard let s = c.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components, s.count >= 3 else { return 0 }
        return 0.2126 * Double(s[0]) + 0.7152 * Double(s[1]) + 0.0722 * Double(s[2])
    }
}

/// Draws annotations onto an image. Coordinates are pixels of the original input, top-left origin;
/// `offset` is where the current image starts within that input (after crop/balance).
enum Annotator {
    static func apply(_ anns: [Args], to base: CGImage, offset: CGPoint, unit: CGFloat) throws -> CGImage {
        var img = base
        let redactions = anns.filter { ["pixelate", "blur"].contains($0["type"] as? String ?? "") }
        if !redactions.isEmpty { img = try redact(img, redactions, offset, unit) }

        let W = img.width, H = img.height
        guard let ctx = makeContext(W, H, space: rgbSpace(img)) else { throw ShotError("Couldn't create a drawing context") }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
        // Flip so annotation coordinates match image pixels with a top-left origin.
        ctx.translateBy(x: 0, y: CGFloat(H))
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let spots = anns.filter { $0["type"] as? String == "spotlight" }
        if !spots.isEmpty { try spotlight(ctx, spots, offset, CGRect(x: 0, y: 0, width: W, height: H), unit) }

        var counter = 0
        let bounds = CGRect(x: 0, y: 0, width: W, height: H)
        for (i, a) in anns.enumerated() {
            let type = a["type"] as? String ?? ""
            let isLine = type == "arrow" || type == "line"
            let w = CGFloat(num(a, "stroke") ?? (isLine ? num(a, "width") : nil) ?? Double(unit * 0.85))
            func rect() throws -> CGRect {
                guard var r = box(a) else { throw ShotError("annotation \(i) (\(type)) needs x, y, width, height") }
                r.origin = r.origin - offset
                return r
            }
            func pt(_ key: String) throws -> CGPoint {
                guard let p = point(a[key]) else { throw ShotError("annotation \(i) (\(type)) needs \(key) as [x, y]") }
                return p - offset
            }
            // Ink is chosen from what sits under the mark (sampled before
            // anything is drawn), so it reads on light and dark screens alike.
            func ink(over region: CGRect) -> Ink { Ink.resolve(a["color"], over: region.intersection(bounds), in: img) }
            switch type {
            case "arrow":
                let p0 = try pt("from"), p1 = try pt("to")
                let region = CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y), width: abs(p1.x - p0.x), height: abs(p1.y - p0.y)).insetBy(dx: -w * 3, dy: -w * 3)
                drawArrow(ctx, from: p0, to: p1, width: w, ink: ink(over: region))
            case "line":
                let p0 = try pt("from"), p1 = try pt("to")
                let path = CGMutablePath(); path.move(to: p0); path.addLine(to: p1)
                let region = CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y), width: abs(p1.x - p0.x), height: abs(p1.y - p0.y)).insetBy(dx: -w * 3, dy: -w * 3)
                stroke(ctx, path, width: w, ink: ink(over: region))
            case "rect", "rectangle", "ellipse", "circle":
                let r = try rect()
                let path = type.hasPrefix("rect")
                    ? CGPath(roundedRect: r, cornerWidth: min(w * 1.5, r.width / 2), cornerHeight: min(w * 1.5, r.height / 2), transform: nil)
                    : CGPath(ellipseIn: r, transform: nil)
                let k = ink(over: r.insetBy(dx: -w * 2, dy: -w * 2))
                if a["fill"] != nil {
                    ctx.setFillColor(a["fill"] is String ? color(a["fill"], defaultColor) : k.ink.copy(alpha: 0.18) ?? k.ink)
                    ctx.addPath(path); ctx.fillPath()
                }
                stroke(ctx, path, width: w, ink: k)
            case "redact":
                ctx.setFillColor(color(a["color"], "#000000")); ctx.fill(try rect())
            case "highlight":
                // A marker: multiply on light content, so the text stays crisp;
                // on dark content multiply vanishes, so add light instead.
                let r = try rect()
                let marker = color(a["color"], "#FFE14D")
                ctx.saveGState()
                if luminance(img, r) > 0.45 {
                    ctx.setBlendMode(.multiply); ctx.setFillColor(marker)
                } else {
                    ctx.setBlendMode(.plusLighter); ctx.setFillColor(marker.copy(alpha: 0.38) ?? marker)
                }
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(unit * 0.5, r.height / 4), cornerHeight: min(unit * 0.5, r.height / 4), transform: nil))
                ctx.fillPath()
                ctx.restoreGState()
            case "text":
                let at = try pt("at")
                let size = textSize(a, unit)
                let est = CGRect(x: at.x, y: at.y, width: CGFloat((a["text"] as? String ?? "").count) * size * 0.6, height: size * 1.6)
                drawText(a, at: at, unit: unit, ink: ink(over: est))
            case "counter":
                if let n = num(a, "number") { counter = Int(n) } else { counter += 1 }
                let c = try pt("at"), r = CGFloat(num(a, "size") ?? Double(counterRadius(unit)))
                drawCounter(ctx, at: c, label: a["label"] as? String ?? "\(counter)", radius: r, style: a["font"] as? String,
                            ink: ink(over: CGRect(x: c.x - r * 2, y: c.y - r * 2, width: r * 4, height: r * 4)))
            case "pixelate", "blur", "spotlight":
                break
            default:
                throw ShotError("annotation \(i): unknown type '\(type)'")
            }
        }
        guard let out = ctx.makeImage() else { throw ShotError("Couldn't render annotations") }
        return out
    }

    /// Average luminance (0-1) of a region, sampled by drawing it into an 8x8 bitmap.
    static func luminance(_ img: CGImage, _ r: CGRect) -> Double {
        guard let part = img.cropping(to: r.integral), let ctx = makeContext(8, 8), let data = ctx.data else { return 1 }
        ctx.interpolationQuality = .medium
        ctx.draw(part, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        let p = data.bindMemory(to: UInt8.self, capacity: 8 * ctx.bytesPerRow)
        var total = 0.0
        for y in 0..<8 {
            for x in 0..<8 {
                let o = y * ctx.bytesPerRow + x * 4
                total += (0.2126 * Double(p[o]) + 0.7152 * Double(p[o + 1]) + 0.0722 * Double(p[o + 2])) / 255
            }
        }
        return total / 64
    }

    /// A soft drop shadow that sits below the mark. Shadow offsets ignore the
    /// flipped CTM, so a negative y lands below in the image.
    private static func withShadow(_ ctx: CGContext, _ w: CGFloat, _ draw: () throws -> Void) rethrows {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -max(1, w * 0.4)), blur: w * 1.6, color: CGColor(gray: 0, alpha: 0.22))
        try draw()
        ctx.restoreGState()
    }

    static func haloWidth(_ w: CGFloat) -> CGFloat { max(1.5, w * 0.55) }

    /// Strokes `path` in ink over a halo keyline, so the mark holds its edge on busy content.
    static func stroke(_ ctx: CGContext, _ path: CGPath, width w: CGFloat, ink: Ink) {
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        withShadow(ctx, w) {
            ctx.setStrokeColor(ink.halo); ctx.setLineWidth(w + haloWidth(w) * 2)
            ctx.addPath(path); ctx.strokePath()
        }
        ctx.setStrokeColor(ink.ink); ctx.setLineWidth(w)
        ctx.addPath(path); ctx.strokePath()
    }

    /// Tapered arrow: thin at the tail, a solid head at `to`.
    static func drawArrow(_ ctx: CGContext, from p0: CGPoint, to p1: CGPoint, width w: CGFloat, ink: Ink) {
        let dx = p1.x - p0.x, dy = p1.y - p0.y, len = hypot(dx, dy)
        guard len > 1 else { return }
        let u = CGPoint(x: dx / len, y: dy / len), n = CGPoint(x: -u.y, y: u.x)
        let headLen = min(len * 0.6, w * 4.6), headHalf = w * 2.4
        let base = CGPoint(x: p1.x - u.x * headLen, y: p1.y - u.y * headLen)
        func off(_ p: CGPoint, _ d: CGFloat) -> CGPoint { CGPoint(x: p.x + n.x * d, y: p.y + n.y * d) }
        let path = CGMutablePath()
        path.addLines(between: [
            off(p0, w * 0.25), off(base, w * 0.6), off(base, headHalf), p1,
            off(base, -headHalf), off(base, -w * 0.6), off(p0, -w * 0.25),
        ])
        path.closeSubpath()
        ctx.setLineJoin(.round)
        withShadow(ctx, w) {
            ctx.setStrokeColor(ink.halo); ctx.setLineWidth(haloWidth(w) * 2)
            ctx.addPath(path); ctx.strokePath()
        }
        ctx.setFillColor(ink.ink); ctx.setStrokeColor(ink.ink); ctx.setLineWidth(w * 0.25)
        ctx.addPath(path); ctx.drawPath(using: .fillStroke)
    }

    static func textSize(_ a: Args, _ unit: CGFloat) -> CGFloat { CGFloat(num(a, "size") ?? Double(unit * 3)) }

    /// Text box whose top-left is `p`. With `background`, a tag in ink (or the
    /// given color) with text in the opposite tone; otherwise ink text on a halo.
    static func drawText(_ a: Args, at p: CGPoint, unit: CGFloat, ink: Ink) {
        let text = a["text"] as? String ?? ""
        let size = textSize(a, unit)
        let font = Fonts.font(a["font"] as? String, size: size, bold: flag(a, "bold", true))
        let bgValue = a["background"]
        let hasBG = bgValue is String || (bgValue as? NSNumber)?.boolValue == true
        let tag = bgValue is String ? color(bgValue, defaultColor) : ink.ink
        let textColor = a["text_color"] != nil ? color(a["text_color"], "#FFFFFF") : (hasBG ? Ink.opposite(of: tag) : ink.ink)
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: textColor) ?? .white, .kern: Fonts.kern(font)]
        let maxW = CGFloat(num(a, "max_width") ?? 100_000)
        let opts: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let bounds = (text as NSString).boundingRect(with: CGSize(width: maxW, height: 100_000), options: opts, attributes: attrs)
        let padX = hasBG ? size * 0.6 : 0, padY = hasBG ? size * 0.3 : 0
        var textRect = CGRect(x: p.x + padX, y: p.y + padY, width: ceil(bounds.width) + 1, height: ceil(bounds.height) + 1)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // A label placed near an edge slides back inside rather than being cut
        // off: the background is added after annotations, so nothing past the
        // image's edge survives.
        let outer = textRect.insetBy(dx: -padX, dy: -padY)
        let dx = outer.maxX > CGFloat(ctx.width) ? CGFloat(ctx.width) - outer.maxX : 0
        let dy = outer.maxY > CGFloat(ctx.height) ? CGFloat(ctx.height) - outer.maxY : 0
        textRect = textRect.offsetBy(dx: max(dx, -outer.minX), dy: max(dy, -outer.minY))
        if hasBG {
            let pill = textRect.insetBy(dx: -padX, dy: -padY)
            let path = CGPath(roundedRect: pill, cornerWidth: size * 0.32, cornerHeight: size * 0.32, transform: nil)
            withShadow(ctx, unit) {
                ctx.setStrokeColor(Ink.opposite(of: tag).copy(alpha: 0.9) ?? ink.halo); ctx.setLineWidth(haloWidth(unit) * 2)
                ctx.addPath(path); ctx.strokePath()
            }
            ctx.setFillColor(tag); ctx.addPath(path); ctx.fillPath()
        } else {
            // The halo is a stroke drawn first, so the fill on top keeps every glyph whole.
            var halo = attrs
            halo[.foregroundColor] = NSColor.clear
            halo[.strokeColor] = NSColor(cgColor: ink.halo) ?? .white
            halo[.strokeWidth] = 22
            (text as NSString).draw(with: textRect, options: opts, attributes: halo)
        }
        attrs[.foregroundColor] = NSColor(cgColor: textColor) ?? .white
        (text as NSString).draw(with: textRect, options: opts, attributes: attrs)
    }

    static func counterRadius(_ unit: CGFloat) -> CGFloat { unit * 2.4 }

    /// An ink disc on a halo ring, its numeral in the opposite tone and
    /// centered on cap height, not the line box, so it sits optically level.
    static func drawCounter(_ ctx: CGContext, at c: CGPoint, label: String, radius r: CGFloat, style: String?, ink: Ink) {
        let circle = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        let ring = r * 0.14
        withShadow(ctx, r * 0.35) {
            ctx.setFillColor(ink.halo); ctx.fillEllipse(in: circle.insetBy(dx: -ring, dy: -ring))
        }
        ctx.setFillColor(ink.ink); ctx.fillEllipse(in: circle)
        let font = Fonts.font(style, size: r * (label.count > 1 ? 0.9 : 1.1), bold: true)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: Ink.opposite(of: ink.ink)) ?? .white]
        let w = (label as NSString).size(withAttributes: attrs).width
        (label as NSString).draw(at: CGPoint(x: c.x - w / 2, y: c.y + font.capHeight / 2 - font.ascender), withAttributes: attrs)
    }

    /// Dims everything except the given boxes.
    static func spotlight(_ ctx: CGContext, _ spots: [Args], _ offset: CGPoint, _ full: CGRect, _ unit: CGFloat) throws {
        let path = CGMutablePath()
        path.addRect(full)
        var opacity = 0.55
        for (i, s) in spots.enumerated() {
            guard var r = box(s) else { throw ShotError("spotlight \(i) needs x, y, width, height") }
            r.origin = r.origin - offset
            if s["shape"] as? String == "ellipse" { path.addEllipse(in: r) }
            else { path.addRoundedRect(in: r, cornerWidth: unit, cornerHeight: unit) }
            if let o = num(s, "opacity") { opacity = o > 1 ? o / 100 : o }
        }
        ctx.saveGState()
        ctx.setFillColor(CGColor(gray: 0, alpha: opacity))
        ctx.addPath(path)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }

    static func redact(_ img: CGImage, _ regions: [Args], _ offset: CGPoint, _ unit: CGFloat) throws -> CGImage {
        let base = CIImage(cgImage: img)
        let H = CGFloat(img.height)
        var out = base
        for (i, r) in regions.enumerated() {
            guard var b = box(r) else { throw ShotError("\(r["type"] ?? "redaction") \(i) needs x, y, width, height") }
            b.origin = b.origin - offset
            let ciRect = CGRect(x: b.minX, y: H - b.maxY, width: b.width, height: b.height).integral
            let f: CIFilter?
            if r["type"] as? String == "blur" {
                f = CIFilter(name: "CIGaussianBlur")
                f?.setValue(num(r, "amount") ?? Double(unit * 1.4), forKey: kCIInputRadiusKey)
            } else {
                f = CIFilter(name: "CIPixellate")
                f?.setValue(num(r, "amount") ?? Double(unit * 1.8), forKey: kCIInputScaleKey)
                f?.setValue(CIVector(x: ciRect.minX, y: ciRect.minY), forKey: kCIInputCenterKey)
            }
            f?.setValue(base.clampedToExtent(), forKey: kCIInputImageKey)
            if let filtered = f?.outputImage?.cropped(to: ciRect) { out = filtered.composited(over: out) }
        }
        guard let cg = CIContext().createCGImage(out, from: base.extent, format: .RGBA8, colorSpace: rgbSpace(img)) else {
            throw ShotError("Couldn't render pixelate/blur")
        }
        return cg
    }
}
