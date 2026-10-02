import AppKit
import CoreImage

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
        for (i, a) in anns.enumerated() {
            let type = a["type"] as? String ?? ""
            let col = color(a["color"], defaultColor)
            let isLine = type == "arrow" || type == "line"
            let w = CGFloat(num(a, "stroke") ?? (isLine ? num(a, "width") : nil) ?? Double(unit))
            func rect() throws -> CGRect {
                guard var r = box(a) else { throw ShotError("annotation \(i) (\(type)) needs x, y, width, height") }
                r.origin = r.origin - offset
                return r
            }
            func pt(_ key: String) throws -> CGPoint {
                guard let p = point(a[key]) else { throw ShotError("annotation \(i) (\(type)) needs \(key) as [x, y]") }
                return p - offset
            }
            switch type {
            case "arrow":
                drawArrow(ctx, from: try pt("from"), to: try pt("to"), width: w, color: col)
            case "line":
                let p0 = try pt("from"), p1 = try pt("to")
                withShadow(ctx, w) {
                    ctx.setStrokeColor(col); ctx.setLineWidth(w); ctx.setLineCap(.round)
                    ctx.move(to: p0); ctx.addLine(to: p1); ctx.strokePath()
                }
            case "rect", "rectangle":
                let r = try rect()
                let path = CGPath(roundedRect: r, cornerWidth: min(w, r.width / 2), cornerHeight: min(w, r.height / 2), transform: nil)
                withShadow(ctx, w) {
                    if a["fill"] != nil {
                        ctx.setFillColor(a["fill"] is String ? color(a["fill"], defaultColor) : col)
                        ctx.addPath(path); ctx.fillPath()
                    }
                    ctx.setStrokeColor(col); ctx.setLineWidth(w); ctx.setLineJoin(.round)
                    ctx.addPath(path); ctx.strokePath()
                }
            case "ellipse", "circle":
                let r = try rect()
                withShadow(ctx, w) {
                    if a["fill"] != nil {
                        ctx.setFillColor(a["fill"] is String ? color(a["fill"], defaultColor) : col)
                        ctx.fillEllipse(in: r)
                    }
                    ctx.setStrokeColor(col); ctx.setLineWidth(w); ctx.strokeEllipse(in: r)
                }
            case "redact":
                ctx.setFillColor(color(a["color"], "#000000")); ctx.fill(try rect())
            case "highlight":
                // Marker-style multiply only shows on light content; on dark content use a translucent wash.
                let r = try rect()
                ctx.saveGState()
                if luminance(img, r) > 0.45 {
                    ctx.setBlendMode(.multiply)
                    ctx.setFillColor(color(a["color"], "#FFE14D"))
                } else {
                    ctx.setFillColor(color(a["color"], "#FFE14D").copy(alpha: 0.32) ?? CGColor(gray: 1, alpha: 0.3))
                }
                ctx.fill(r)
                ctx.restoreGState()
            case "text":
                drawText(a, at: try pt("at"), unit: unit, accent: col)
            case "counter":
                if let n = num(a, "number") { counter = Int(n) } else { counter += 1 }
                drawCounter(ctx, at: try pt("at"), label: a["label"] as? String ?? "\(counter)",
                            radius: CGFloat(num(a, "size") ?? Double(unit * 1.9)), color: col)
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

    private static func withShadow(_ ctx: CGContext, _ w: CGFloat, _ draw: () throws -> Void) rethrows {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: w * 0.7, color: CGColor(gray: 0, alpha: 0.3))
        try draw()
        ctx.restoreGState()
    }

    /// Tapered arrow: thin at the tail, a solid head at `to`.
    static func drawArrow(_ ctx: CGContext, from p0: CGPoint, to p1: CGPoint, width w: CGFloat, color: CGColor) {
        let dx = p1.x - p0.x, dy = p1.y - p0.y, len = hypot(dx, dy)
        guard len > 1 else { return }
        let u = CGPoint(x: dx / len, y: dy / len), n = CGPoint(x: -u.y, y: u.x)
        let headLen = min(len * 0.6, w * 4.2), headHalf = w * 2.3
        let base = CGPoint(x: p1.x - u.x * headLen, y: p1.y - u.y * headLen)
        func off(_ p: CGPoint, _ d: CGFloat) -> CGPoint { CGPoint(x: p.x + n.x * d, y: p.y + n.y * d) }
        let path = CGMutablePath()
        path.addLines(between: [
            off(p0, w * 0.2), off(base, w * 0.6), off(base, headHalf), p1,
            off(base, -headHalf), off(base, -w * 0.6), off(p0, -w * 0.2),
        ])
        path.closeSubpath()
        withShadow(ctx, w) {
            ctx.setFillColor(color)
            ctx.setStrokeColor(color); ctx.setLineWidth(w * 0.25); ctx.setLineJoin(.round)
            ctx.addPath(path); ctx.drawPath(using: .fillStroke)
        }
    }

    /// Text box whose top-left is `p`. With `background`, draws a pill in that color (or the accent
    /// color when `background: true`) and white text; otherwise accent-colored text with a white outline.
    static func drawText(_ a: Args, at p: CGPoint, unit: CGFloat, accent: CGColor) {
        let text = a["text"] as? String ?? ""
        let size = CGFloat(num(a, "size") ?? Double(unit * 2.4))
        let font = NSFont.systemFont(ofSize: size, weight: flag(a, "bold", true) ? .bold : .regular)
        let bgValue = a["background"]
        let hasBG = bgValue is String || (bgValue as? NSNumber)?.boolValue == true
        let textColor = hasBG ? color(a["text_color"], "#FFFFFF") : (a["text_color"] != nil ? color(a["text_color"], defaultColor) : accent)
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: textColor) ?? .white]
        let maxW = CGFloat(num(a, "max_width") ?? 100_000)
        let opts: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let bounds = (text as NSString).boundingRect(with: CGSize(width: maxW, height: 100_000), options: opts, attributes: attrs)
        let padX = hasBG ? size * 0.45 : 0, padY = hasBG ? size * 0.22 : 0
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
            let path = CGPath(roundedRect: pill, cornerWidth: size * 0.35, cornerHeight: size * 0.35, transform: nil)
            withShadow(ctx, unit) {
                ctx.setFillColor(bgValue is String ? color(bgValue, defaultColor) : accent)
                ctx.addPath(path); ctx.fillPath()
            }
        } else {
            var outline = attrs
            outline[.strokeColor] = NSColor.white
            outline[.strokeWidth] = 14
            (text as NSString).draw(with: textRect, options: opts, attributes: outline)
        }
        attrs[.foregroundColor] = NSColor(cgColor: textColor) ?? .white
        (text as NSString).draw(with: textRect, options: opts, attributes: attrs)
    }

    static func drawCounter(_ ctx: CGContext, at c: CGPoint, label: String, radius r: CGFloat, color: CGColor) {
        let circle = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        withShadow(ctx, r * 0.4) {
            ctx.setFillColor(color); ctx.fillEllipse(in: circle)
        }
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1)); ctx.setLineWidth(r * 0.12)
        ctx.strokeEllipse(in: circle.insetBy(dx: r * 0.06, dy: r * 0.06))
        let font = NSFont.systemFont(ofSize: r * (label.count > 1 ? 0.9 : 1.1), weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = (label as NSString).size(withAttributes: attrs)
        (label as NSString).draw(at: CGPoint(x: c.x - size.width / 2, y: c.y - size.height / 2), withAttributes: attrs)
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
