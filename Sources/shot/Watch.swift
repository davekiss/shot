import AppKit
import Vision

/// Finds what changed between two screenshots: the regions, and the text in
/// them before and after, so an agent can tell "the button now says Saved"
/// without comparing two images by eye.
enum Diff {
    struct Region { let rect: CGRect; let before: String; let after: String }

    /// RGBA bytes of `img` drawn at `size`.
    static func pixels(_ img: CGImage, _ w: Int, _ h: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return buf
    }

    /// Changed areas, in pixels of `after` (top-left origin). The images are
    /// compared on a grid of small cells so anti-aliasing noise doesn't count;
    /// neighboring changed cells merge into one region, and specks smaller
    /// than `minArea` (a blinking caret, a clock tick) are dropped.
    static func regions(_ a: CGImage, _ b: CGImage, minArea: CGFloat? = nil) throws -> [CGRect] {
        guard a.width == b.width, a.height == b.height else {
            throw ShotError("before is \(a.width)x\(a.height) but after is \(b.width)x\(b.height); diff needs captures of the same size")
        }
        let W = b.width, H = b.height
        let pa = pixels(a, W, H), pb = pixels(b, W, H)
        let cell = max(4, min(W, H) / 180)
        let cols = (W + cell - 1) / cell, rows = (H + cell - 1) / cell
        var hot = [Bool](repeating: false, count: cols * rows)
        for row in 0..<rows {
            for col in 0..<cols {
                var changed = 0, total = 0
                for y in (row * cell)..<min(H, (row + 1) * cell) {
                    var o = (y * W + col * cell) * 4
                    for _ in (col * cell)..<min(W, (col + 1) * cell) {
                        let d = abs(Int(pa[o]) - Int(pb[o])) + abs(Int(pa[o + 1]) - Int(pb[o + 1])) + abs(Int(pa[o + 2]) - Int(pb[o + 2]))
                        if d > 60 { changed += 1 }
                        total += 1
                        o += 4
                    }
                }
                hot[row * cols + col] = changed * 50 > total   // more than 2% of the cell
            }
        }
        // Connected components, joining cells up to two apart so one edited
        // word or widget comes back as one region rather than a scatter.
        var seen = [Bool](repeating: false, count: cols * rows)
        var rects: [CGRect] = []
        for start in 0..<(cols * rows) where hot[start] && !seen[start] {
            var stack = [start], minC = cols, maxC = 0, minR = rows, maxR = 0
            seen[start] = true
            while let i = stack.popLast() {
                let c = i % cols, r = i / cols
                minC = min(minC, c); maxC = max(maxC, c); minR = min(minR, r); maxR = max(maxR, r)
                for dr in -2...2 {
                    for dc in -2...2 {
                        let nc = c + dc, nr = r + dr
                        guard nc >= 0, nc < cols, nr >= 0, nr < rows else { continue }
                        let j = nr * cols + nc
                        if hot[j] && !seen[j] { seen[j] = true; stack.append(j) }
                    }
                }
            }
            rects.append(CGRect(x: minC * cell, y: minR * cell, width: (maxC - minC + 1) * cell, height: (maxR - minR + 1) * cell)
                .intersection(CGRect(x: 0, y: 0, width: W, height: H)))
        }
        let floor = minArea ?? CGFloat(cell * cell * 6)
        return rects.filter { $0.width * $0.height >= floor }.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
    }

    /// The whole lines of text each change touches, before and after, so the
    /// agent reads "Deploying…" → "Deployed ✓" rather than the changed letters.
    static func describe(_ rects: [CGRect], _ a: CGImage, _ b: CGImage) -> [Region] {
        let ocrA = OCRText(a), ocrB = OCRText(b)
        func text(_ ocr: OCRText, _ r: CGRect) -> String {
            let near = r.insetBy(dx: -4, dy: -4)
            return ocr.observations.filter { ocr.rect($0).intersects(near) }.compactMap(ocr.text).joined(separator: "\n")
        }
        return rects.map { Region(rect: $0, before: text(ocrA, $0), after: text(ocrB, $0)) }
    }
}

/// Conditions `capture` can wait for before it keeps a shot.
enum Wait {
    enum Condition { case text(String), gone(String), stable(TimeInterval) }

    static func condition(_ v: Any?) throws -> Condition? {
        guard let spec = v as? Args else { return nil }
        if let t = spec["text"] as? String { return .text(t) }
        if let t = spec["gone"] as? String { return .gone(t) }
        if spec["stable"] != nil { return .stable(num(spec, "stable") ?? 1) }
        throw ShotError("wait_for needs text (wait until it appears), gone (until it disappears) or stable (seconds of no change)")
    }

    /// Whether `img` meets a text condition. Stable is judged by the caller
    /// across frames.
    static func met(_ c: Condition, _ img: CGImage) -> Bool {
        switch c {
        case .text(let t): return !OCRText(img).find(t).isEmpty
        case .gone(let t): return OCRText(img).find(t).isEmpty
        case .stable: return false
        }
    }
}
