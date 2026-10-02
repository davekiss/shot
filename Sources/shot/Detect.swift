import AppKit
import Vision

/// Vision text observations for one image, kept so a range inside a line can
/// be boxed exactly (Vision measures sub-ranges itself; splitting the line's
/// box by character count would drift on proportional fonts).
struct Hit { let text: String; let rect: CGRect; let line: CGRect }

struct OCRText {
    let observations: [VNRecognizedTextObservation]
    let size: CGSize

    /// `correct` runs Vision's language correction: right for UI labels, wrong
    /// for keys and tokens, which it "fixes" into words.
    init(_ img: CGImage, correct: Bool = true) {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = correct
        try? VNImageRequestHandler(cgImage: img).perform([req])
        observations = (req.results ?? []).sorted { a, b in
            (Int((1 - a.boundingBox.maxY) * 100), a.boundingBox.minX) < (Int((1 - b.boundingBox.maxY) * 100), b.boundingBox.minX)
        }
        size = CGSize(width: img.width, height: img.height)
    }

    var lines: [String] { observations.compactMap(text) }

    /// Median height of a line of text, in pixels: the scale marks should
    /// be drawn at, so they match what they point at.
    var textHeight: CGFloat? {
        let hs = observations.map { $0.boundingBox.height * size.height }.sorted()
        return hs.isEmpty ? nil : hs[hs.count / 2]
    }

    /// Vision sometimes returns a Cyrillic or Greek letter that looks exactly
    /// like a Latin one ("GITHUB_ТOKEN" with a Cyrillic Т), which would stop
    /// "sk-" or a target from matching. Folding is one character for one, so
    /// offsets in the folded text are offsets in Vision's.
    static let homoglyphs: [Character: Character] = {
        let pairs = ["АA", "ВB", "ЕE", "КK", "МM", "НH", "ОO", "РP", "СC", "ТT", "ХX", "УY", "ІI", "ЈJ", "ЅS",
                     "аa", "еe", "оo", "рp", "сc", "уy", "хx", "іi", "јj", "ѕs", "кk", "һh", "ԁd", "ԛq", "ԝw",
                     "ΑA", "ΒB", "ΕE", "ΖZ", "ΗH", "ΙI", "ΚK", "ΜM", "ΝN", "ΟO", "ΡP", "ΤT", "ΥY", "ΧX",
                     "οo", "ιi", "κk", "νv", "ρp", "τt", "υu", "χx"]
        return Dictionary(uniqueKeysWithValues: pairs.map { ($0.first!, $0.last!) })
    }()

    func text(_ obs: VNRecognizedTextObservation) -> String? {
        obs.topCandidates(1).first.map { String($0.string.map { OCRText.homoglyphs[$0] ?? $0 }) }
    }

    /// Box of `range` (in `text(obs)`) within observation `obs`, in image pixels, top-left origin.
    /// Vision only measures whole words, so "KEY=value" comes back as one box;
    /// a range inside a word is cut out of the word's box by character position.
    func rect(_ obs: VNRecognizedTextObservation, _ folded: Range<String.Index>? = nil) -> CGRect {
        var b = obs.boundingBox
        if let folded, let cand = obs.topCandidates(1).first, let f = text(obs) {
            let s = cand.string
            let range = s.index(s.startIndex, offsetBy: f.distance(from: f.startIndex, to: folded.lowerBound))
                ..< s.index(s.startIndex, offsetBy: f.distance(from: f.startIndex, to: folded.upperBound))
            var lo = range.lowerBound, hi = range.upperBound
            while lo > s.startIndex, !s[s.index(before: lo)].isWhitespace { lo = s.index(before: lo) }
            while hi < s.endIndex, !s[hi].isWhitespace { hi = s.index(after: hi) }
            if let word = try? cand.boundingBox(for: lo..<hi)?.boundingBox {
                let n = CGFloat(s.distance(from: lo, to: hi))
                let a = CGFloat(s.distance(from: lo, to: range.lowerBound)), z = CGFloat(s.distance(from: lo, to: range.upperBound))
                b = CGRect(x: word.minX + word.width * a / n, y: word.minY, width: word.width * (z - a) / n, height: word.height)
            }
        }
        return CGRect(x: b.minX * size.width, y: (1 - b.maxY) * size.height, width: b.width * size.width, height: b.height * size.height)
    }

    /// Every place `query` appears, in reading order. When some lines are
    /// exactly the query, only those count, so "Bot" finds the "Bot" button
    /// rather than the first sentence that mentions bots.
    /// `rect` is the matched text; `line` is the whole line it sits on.
    func find(_ query: String) -> [Hit] {
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        // Whole lines beat whole words beat fragments, so "PORT" finds
        // "PORT=3000" before the middle of "SUPPORT_EMAIL".
        var exact: [Hit] = [], word: [Hit] = [], partial: [Hit] = []
        func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }
        for obs in observations {
            guard let s = text(obs) else { continue }
            if s.trimmingCharacters(in: .whitespaces).compare(query, options: opts) == .orderedSame {
                exact.append(Hit(text: s, rect: rect(obs), line: rect(obs)))
                continue
            }
            var from = s.startIndex, best: (Range<String.Index>, Bool)?
            while let r = s.range(of: query, options: opts, range: from..<s.endIndex) {
                let whole = (r.lowerBound == s.startIndex || !isWordChar(s[s.index(before: r.lowerBound)]))
                    && (r.upperBound == s.endIndex || !isWordChar(s[r.upperBound]))
                if best == nil || (whole && !best!.1) { best = (r, whole) }
                if whole { break }
                from = s.index(after: r.lowerBound)
            }
            guard let (r, whole) = best else { continue }
            (whole ? { word.append($0) } : { partial.append($0) })(Hit(text: s, rect: rect(obs, r), line: rect(obs)))
        }
        return !exact.isEmpty ? exact : !word.isEmpty ? word : partial
    }
}

// MARK: targets

/// Lets annotations and crop name what they point at (`target: "Save"`)
/// instead of giving pixel coordinates; each type places itself around the
/// text the way a person would mark it up.
enum Targets {
    static func needed(_ a: Args) -> Bool {
        (a["crop"] as? Args)?["target"] != nil || (a["annotations"] as? [Args])?.contains { $0["target"] != nil } == true
    }

    static func locate(_ spec: Args, in ocr: OCRText, label: String) throws -> Hit {
        guard let query = spec["target"] as? String, !query.isEmpty else { throw ShotError("\(label): target must be text to look for") }
        let hits = ocr.find(query)
        let nth = Int(num(spec, "nth") ?? 1)
        guard nth >= 1, nth <= hits.count else {
            let seen = ocr.lines.prefix(40).map { "\"\($0)\"" }.joined(separator: ", ")
            if hits.isEmpty { throw ShotError("\(label): no text matching \"\(query)\". Text in the image: \(seen)") }
            throw ShotError("\(label): \"\(query)\" appears \(hits.count) time(s), so nth \(nth) doesn't exist")
        }
        return hits[nth - 1]
    }

    /// Fills in coordinates for every annotation with a `target`, in input
    /// pixels. Coordinates the caller gave explicitly win.
    /// `visible` is the part of the image that will survive a crop: marks are
    /// placed inside it, so a label never lands where it will be cut off.
    static func resolve(_ anns: [Args], ocr: OCRText, unit: CGFloat, visible: CGRect? = nil, found: inout [Args]) throws -> [Args] {
        let bounds = visible ?? CGRect(origin: .zero, size: ocr.size)
        // Marks already on the image count as obstacles for the ones placed
        // after them, so nothing lands on anything else.
        var placed = anns.filter { $0["target"] == nil }.compactMap { extent($0, unit) }
        var labels: [Int] = []
        var out = anns
        func free(_ r: CGRect, _ obstacles: [CGRect]) -> Bool { bounds.contains(r) && !obstacles.contains { $0.intersects(r) } }
        for (i, a0) in anns.enumerated() {
            guard a0["target"] != nil else { continue }
            var a = a0
            let type = a["type"] as? String ?? ""
            let hit = try locate(a, in: ocr, label: "annotation \(i) (\(type))")
            let blocked = obstacles(ocr, around: hit.rect, line: hit.line, gap: unit * 0.5) + placed
            // Padding never reaches halfway to the next line or mark, so boxes
            // on tightly set text don't swallow their neighbors.
            let room = clearance(hit.rect, blocked, in: bounds)
            let tight = ["highlight", "redact", "pixelate", "blur", "line"].contains(type)
            let want = CGFloat(num(a, "pad") ?? Double(unit * (tight ? 0.4 : 1.2)))
            let padX = a["pad"] != nil ? want : min(want, max(unit * 0.3, min(room.left, room.right) * 0.45))
            let padY = a["pad"] != nil ? want : min(want, max(unit * 0.3, min(room.above, room.below) * 0.45))
            let r = hit.rect.insetBy(dx: -padX, dy: -padY)
            switch type {
            case "ellipse", "circle":
                if a["x"] == nil {
                    // Between tight lines a full-weight pen can't fit; a finer one
                    // keeps the loop off both the word and its neighbors.
                    let pen = CGFloat(num(a, "stroke") ?? Double(Shapes.pen(for: min(room.above, room.below) * 0.5, unit: unit)))
                    if a["stroke"] == nil, pen < unit * 0.84 { a["stroke"] = pen }
                    let fit = Shapes.enclose(hit.rect, stroke: pen, room: room, unit: unit)
                    a["x"] = fit.box.minX; a["y"] = fit.box.minY; a["width"] = fit.box.width; a["height"] = fit.box.height
                    if fit.exponent != 2 { a["_exponent"] = fit.exponent }
                }
            case "rect", "rectangle":
                // Like loops: a finer pen when space is tight, and padding never
                // less than the stroke's inward reach, so the box never touches the text.
                if a["x"] == nil {
                    let pen = CGFloat(num(a, "stroke") ?? Double(Shapes.pen(for: min(room.above, room.below) * 0.5, unit: unit)))
                    if a["stroke"] == nil, pen < unit * 0.84 { a["stroke"] = pen }
                    let clear = Shapes.clearance(pen, unit)
                    let b = hit.rect.insetBy(dx: -max(padX, clear), dy: -max(padY, clear))
                    a["x"] = b.minX; a["y"] = b.minY; a["width"] = b.width; a["height"] = b.height
                }
            case "highlight", "redact", "pixelate", "blur", "spotlight":
                if a["x"] == nil { a["x"] = r.minX; a["y"] = r.minY; a["width"] = r.width; a["height"] = r.height }
            case "counter":
                // Beside the text like a step marker; else above, right, below,
                // or further left. With no clean spot, the least-covering one.
                var radius = CGFloat(num(a, "size") ?? Double(Annotator.counterRadius(unit)))
                // In a narrow margin, a slightly smaller step marker beside
                // the text beats a full-size one on top of it.
                let fit = (room.left - unit * 0.6) / 2
                if a["size"] == nil, fit < radius, fit >= radius * 0.62,
                   !blocked.contains(where: { $0.intersects(CGRect(x: hit.rect.minX - unit * 0.6 - fit * 2, y: hit.rect.midY - fit, width: fit * 2, height: fit * 2)) }) {
                    radius = fit
                    a["size"] = radius
                }
                let g = unit * 0.6 + radius, T = hit.rect
                let spots = [CGPoint(x: T.minX - g, y: T.midY), CGPoint(x: T.minX + radius, y: T.minY - g),
                             CGPoint(x: T.maxX + g, y: T.midY), CGPoint(x: T.minX + radius, y: T.maxY + g),
                             CGPoint(x: T.minX - g - radius * 1.5, y: T.midY), CGPoint(x: T.minX - radius * 0.2, y: T.minY - radius * 0.2)]
                func circle(_ c: CGPoint) -> CGRect { CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2) }
                let pick = spots.first { free(circle($0), blocked) } ?? spots.min { overlap(circle($0), blocked, bounds) < overlap(circle($1), blocked, bounds) }!
                if a["at"] == nil { a["at"] = [pick.x, pick.y] }
            case "line":
                let y = hit.rect.maxY + min(unit * 0.6, room.below * 0.4)
                if a["from"] == nil { a["from"] = [hit.rect.minX, y]; a["to"] = [hit.rect.maxX, y] }
            case "text":
                if a["at"] == nil {
                    // Below the target, else above, else to its right.
                    let (w, h) = labelSize(a, unit)
                    let spots = [CGPoint(x: r.minX, y: r.maxY + unit), CGPoint(x: r.minX, y: r.minY - unit - h),
                                 CGPoint(x: r.maxX + unit, y: r.midY - h / 2)]
                    func label(_ p: CGPoint) -> CGRect { CGRect(origin: p, size: CGSize(width: w, height: h)) }
                    let pick = spots.first { free(label($0), blocked) } ?? spots.min { overlap(label($0), blocked, bounds) < overlap(label($1), blocked, bounds) }!
                    a["at"] = [pick.x, pick.y]
                    labels.append(i)
                }
            case "arrow":
                let len = CGFloat(num(a, "length") ?? Double(unit * 14))
                // When a label rides this arrow, its box counts as part of the
                // arrow, so the pair lands in open space together.
                let label = anns.first { $0["type"] as? String == "text" && $0["at"] == nil
                    && $0["target"] as? String == a["target"] as? String && num($0, "nth") == num(a, "nth") }
                let (from, to) = arrow(at: r, length: len, avoiding: obstacles(ocr, around: hit.rect, line: hit.line, gap: unit) + placed,
                                       bounds: bounds, label: label, unit: unit)
                if a["to"] == nil { a["to"] = [to.x, to.y] }
                if a["from"] == nil { a["from"] = [from.x, from.y] }
            default:
                break
            }
            if let e = extent(a, unit) { placed.append(e) }
            found.append(["annotation": i, "target": a["target"] ?? "", "matched": hit.text,
                          "box": [Int(hit.rect.minX), Int(hit.rect.minY), Int(hit.rect.width), Int(hit.rect.height)]])
            out[i] = a
        }
        // A label and an arrow aimed at the same text make a callout: the
        // label moves to the arrow's tail instead of sitting under the target.
        for i in labels {
            let same = { (b: Args) in b["target"] as? String == out[i]["target"] as? String && num(b, "nth") == num(out[i], "nth") }
            guard let arrow = out.first(where: { $0["type"] as? String == "arrow" && same($0) }),
                  let from = point(arrow["from"]), let to = point(arrow["to"]) else { continue }
            out[i]["at"] = callout(out[i], tail: from, head: to, unit: unit, within: bounds)
        }
        return out
    }

    /// The area a resolved mark covers, for keeping later marks off it.
    /// Arrows are thin and cross things by design, so they don't count.
    static func extent(_ a: Args, _ unit: CGFloat) -> CGRect? {
        switch a["type"] as? String ?? "" {
        case "rect", "rectangle", "ellipse", "circle", "highlight", "redact":
            return box(a)
        case "counter":
            guard let c = point(a["at"]) else { return nil }
            let r = CGFloat(num(a, "size") ?? Double(Annotator.counterRadius(unit))) * 1.15
            return CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        case "text":
            guard let p = point(a["at"]) else { return nil }
            let (w, h) = labelSize(a, unit)
            return CGRect(x: p.x, y: p.y, width: w, height: h)
        case "line":
            guard let p0 = point(a["from"]), let p1 = point(a["to"]) else { return nil }
            return CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y) - unit, width: abs(p1.x - p0.x), height: abs(p1.y - p0.y) + unit * 2)
        default:
            return nil
        }
    }

    /// Free space around `t` in each direction before the nearest obstacle or edge.
    static func clearance(_ t: CGRect, _ obstacles: [CGRect], in bounds: CGRect) -> (left: CGFloat, right: CGFloat, above: CGFloat, below: CGFloat) {
        var l = t.minX - bounds.minX, r = bounds.maxX - t.maxX, a = t.minY - bounds.minY, b = bounds.maxY - t.maxY
        for o in obstacles where !o.intersects(t) {
            if o.maxX > t.minX && o.minX < t.maxX {
                if o.maxY <= t.minY { a = min(a, t.minY - o.maxY) }
                if o.minY >= t.maxY { b = min(b, o.minY - t.maxY) }
            }
            if o.maxY > t.minY && o.minY < t.maxY {
                if o.maxX <= t.minX { l = min(l, t.minX - o.maxX) }
                if o.minX >= t.maxX { r = min(r, o.minX - t.maxX) }
            }
        }
        return (max(0, l), max(0, r), max(0, a), max(0, b))
    }

    /// How much of `r` is covered by obstacles or falls off the image.
    static func overlap(_ r: CGRect, _ obstacles: [CGRect], _ bounds: CGRect) -> CGFloat {
        let off = r.width * r.height - { let i = r.intersection(bounds); return i.isNull ? 0 : i.width * i.height }()
        return obstacles.reduce(off * 2) { acc, o in let i = r.intersection(o); return acc + (i.isNull ? 0 : i.width * i.height) }
    }

    /// Outer size of a text label as Annotator draws it, tag padding included.
    static func labelSize(_ a: Args, _ unit: CGFloat) -> (CGFloat, CGFloat) {
        let size = Annotator.textSize(a, unit)
        let bg = a["background"] is String || (a["background"] as? NSNumber)?.boolValue == true
        let font = Fonts.font(a["font"] as? String, size: size, bold: flag(a, "bold", true))
        let t = ((a["text"] as? String ?? "") as NSString).size(withAttributes: [.font: font, .kern: Fonts.kern(font)])
        return (t.width + (bg ? size * 1.2 : 0), t.height + (bg ? size * 0.6 : 0))
    }

    /// Top-left for a text label so its edge meets an arrow's tail on the far side from the head.
    static func callout(_ a: Args, tail: CGPoint, head: CGPoint, unit: CGFloat, within bounds: CGRect? = nil) -> [CGFloat] {
        let (w, h) = labelSize(a, unit)
        let dx = tail.x - head.x, dy = tail.y - head.y, gap = unit * 0.4
        var p = abs(dx) >= abs(dy) * 0.5
            ? CGPoint(x: dx < 0 ? tail.x - gap - w : tail.x + gap, y: tail.y - h / 2)
            : CGPoint(x: tail.x - w / 2, y: dy > 0 ? tail.y + gap : tail.y - gap - h)
        if let b = bounds {
            p.x = min(max(p.x, b.minX), max(b.minX, b.maxX - w))
            p.y = min(max(p.y, b.minY), max(b.minY, b.maxY - h))
        }
        return [p.x, p.y]
    }

    /// Every other line of text, plus the rest of the target's own line on
    /// either side of it: the places a mark shouldn't land.
    static func obstacles(_ ocr: OCRText, around hit: CGRect, line: CGRect, gap: CGFloat) -> [CGRect] {
        ocr.observations.map { ocr.rect($0) }.filter { !$0.intersects(line) } + [
            CGRect(x: line.minX, y: line.minY, width: max(0, hit.minX - gap - line.minX), height: line.height),
            CGRect(x: hit.maxX + gap, y: line.minY, width: max(0, line.maxX - hit.maxX - gap), height: line.height),
        ].filter { $0.width > 0 }
    }

    /// An arrow ending at the edge of `r`, coming from whichever of eight
    /// directions crosses the least other text and stays inside the image.
    /// Diagonals come first, so they win ties: they read as pointing.
    static func arrow(at r: CGRect, length: CGFloat, avoiding others: [CGRect], bounds: CGRect,
                      label: Args? = nil, unit: CGFloat = 1) -> (CGPoint, CGPoint) {
        let c = CGPoint(x: r.midX, y: r.midY)
        let s = CGFloat(0.7071)
        let dirs = [(-s, s), (s, s), (-s, -s), (s, -s), (-1, 0), (1, 0), (0, 1), (0, -1)].map { CGPoint(x: $0.0, y: $0.1) }
        // Longer arrows reach open space on crowded screens; a crossing costs
        // far more than extra length, so short wins whenever it's clean.
        var best: (score: Double, from: CGPoint, to: CGPoint)?
        for d in dirs { for stretch in [0.6, 1.0, 1.6, 2.4, 3.4] as [CGFloat] {
            let t = min(r.width / 2 / max(abs(d.x), 0.001), r.height / 2 / max(abs(d.y), 0.001))
            let to = CGPoint(x: c.x + d.x * t, y: c.y + d.y * t)
            let from = CGPoint(x: to.x + d.x * length * stretch, y: to.y + d.y * length * stretch)
            var score: Double = (bounds.insetBy(dx: 4, dy: 4).contains(from) ? 0 : 100) + Double(abs(stretch - 1)) * 0.8
            // Sample along the shaft; each text line it passes over costs one.
            var crossed = Set<Int>()
            for k in 1...12 {
                let f = CGFloat(k) / 12
                let p = CGPoint(x: to.x + (from.x - to.x) * f, y: to.y + (from.y - to.y) * f)
                for (i, o) in others.enumerated() where o.insetBy(dx: -4, dy: -4).contains(p) { crossed.insert(i) }
            }
            score += Double(crossed.count) * 3
            if let label {
                // Judge the label where it will be drawn: slid back inside the image if it pokes out.
                let at = callout(label, tail: from, head: to, unit: unit, within: bounds), (w, h) = labelSize(label, unit)
                let box = CGRect(x: at[0], y: at[1], width: w, height: h)
                score += (w > bounds.width || h > bounds.height ? 50 : 0) + Double(others.filter { $0.intersects(box) }.count) * 4
            }
            if best == nil || score < best!.score { best = (score, from, to) }
        } }
        return (best!.from, best!.to)
    }

    /// `crop: {target, pad?}`: the target's box plus generous room, clamped to the image.
    /// `target` may be a list, to frame several lines at once.
    static func crop(_ spec: Args, ocr: OCRText, unit: CGFloat) throws -> CGRect {
        let targets = spec["target"] as? [String] ?? [spec["target"] as? String ?? ""]
        let lines = try targets.map { t -> CGRect in
            var one = spec; one["target"] = t
            return try locate(one, in: ocr, label: "crop").line
        }
        let pad = CGFloat(num(spec, "pad") ?? Double(unit * 12))
        return lines.dropFirst().reduce(lines[0]) { $0.union($1) }
            .insetBy(dx: -pad, dy: -pad).intersection(CGRect(origin: .zero, size: ocr.size))
    }
}

// MARK: sensitive data

/// Finds secrets and personal data in an image's text so they can be covered
/// before it's shared. Results never carry the full value: an agent only
/// needs to know what and where, and its context is not a safe place for keys.
enum Sensitive {
    /// Everything readable is covered together: deciding per kind what counts
    /// as sensitive is a choice nobody gets right in advance. Faces are
    /// separate, since product screenshots are full of avatars people want kept.
    static let textKinds = ["secret", "email", "card", "phone"]

    struct Finding { let kind: String; let text: String; let rect: CGRect }

    // Group 1, when present, is the part to cover (the value after "token=").
    static let patterns: [(String, NSRegularExpression)] = [
        ("secret", #"sk-(?:ant-|proj-)?[A-Za-z0-9_\-]{16,}"#),
        ("secret", #"gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}"#),
        ("secret", #"(?:AKIA|ASIA)[0-9A-Z]{16}"#),
        ("secret", #"xox[abprs]-[A-Za-z0-9\-]{10,}"#),
        ("secret", #"AIza[0-9A-Za-z_\-]{30,}"#),
        ("secret", #"(?:sk|pk|rk)_(?:live|test)_[0-9A-Za-z]{10,}"#),
        ("secret", #"eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{4,}"#),
        ("secret", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
        // The password in scheme://user:password@host (database URLs, mostly).
        ("secret", #"[A-Za-z][A-Za-z0-9+.\-]*://[^\s:/@]+:([^\s@/]+)@"#),
        ("secret", #"(?i)bearer\s+([A-Za-z0-9._~+/\-]{16,})"#),
        ("secret", #"(?i)(?:api[_\-]?key|secret|token|passw(?:or)?d|pwd)["']?\s*[:=]\s*["']?([^\s"']{6,})"#),
        ("email", #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#),
        ("card", #"(?<!\d)(?:\d[ \-]?){12,18}\d(?!\d)"#),
        ("phone", #"(?<![\w.])(?:\+\d{1,3}[\s.\-]?)?\(?\d{3}\)?[\s.\-]?\d{3}[\s.\-]?\d{4}(?![\w.])"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    static func scan(_ img: CGImage, kinds: [String] = textKinds) -> [Finding] {
        let want = Set(kinds)
        var out: [Finding] = []
        let ocr = OCRText(img, correct: false)
        for obs in ocr.observations {
            guard let s = ocr.text(obs) else { continue }
            let ns = s as NSString
            var covered: [NSRange] = []
            func add(_ kind: String, _ r: NSRange) {
                guard !covered.contains(where: { NSIntersectionRange($0, r).length > 0 }), let range = Range(r, in: s) else { return }
                covered.append(r)
                out.append(Finding(kind: kind, text: ns.substring(with: r), rect: ocr.rect(obs, range)))
            }
            for (kind, re) in patterns where want.contains(kind) {
                for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                    var r = m.numberOfRanges > 1 && m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range
                    // OCR misreads a character now and then, which ends a
                    // match early; the rest of the word is still the secret.
                    if kind == "secret" {
                        var end = NSMaxRange(r)
                        // @ and quotes end a secret: "user:pass@host", "token": "…"
                        let stops = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "@\"'`"))
                        while end < ns.length, let u = UnicodeScalar(ns.character(at: end)), !stops.contains(u) { end += 1 }
                        r.length = end - r.location
                    }
                    if kind == "card", !luhn(ns.substring(with: r)) { continue }
                    // Bare digit runs are order numbers and ids far more often than phones.
                    if kind == "phone", !ns.substring(with: r).contains(where: { "()-. +".contains($0) }) { continue }
                    add(kind, r)
                }
            }
            // Keys with no known prefix: long, mixed-case, digit-bearing, random-looking.
            if want.contains("secret") {
                let re = try! NSRegularExpression(pattern: #"[A-Za-z0-9_\-+/]{24,}={0,2}"#)
                for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) where looksRandom(ns.substring(with: m.range)) {
                    add("secret", m.range)
                }
            }
        }
        if want.contains("face") {
            let req = VNDetectFaceRectanglesRequest()
            try? VNImageRequestHandler(cgImage: img).perform([req])
            let W = CGFloat(img.width), H = CGFloat(img.height)
            for f in req.results ?? [] {
                let b = f.boundingBox
                out.append(Finding(kind: "face", text: "", rect: CGRect(x: b.minX * W, y: (1 - b.maxY) * H, width: b.width * W, height: b.height * H)))
            }
        }
        return out
    }

    static func luhn(_ s: String) -> Bool {
        let digits = s.compactMap { $0.wholeNumberValue }
        guard (13...19).contains(digits.count) else { return false }
        let sum = digits.reversed().enumerated().reduce(0) { acc, e in
            let d = e.offset % 2 == 1 ? e.element * 2 : e.element
            return acc + (d > 9 ? d - 9 : d)
        }
        return sum % 10 == 0
    }

    /// Paths, words and URLs fail this: real keys mix upper, lower and digits
    /// with high per-character entropy.
    static func looksRandom(_ s: String) -> Bool {
        guard s.contains(where: \.isUppercase), s.contains(where: \.isLowercase), s.contains(where: \.isNumber),
              s.filter({ $0 == "/" }).count < 2 else { return false }
        var counts: [Character: Int] = [:]
        for c in s { counts[c, default: 0] += 1 }
        let n = Double(s.count)
        let entropy = counts.values.reduce(0.0) { $0 - Double($1) / n * log2(Double($1) / n) }
        return entropy >= 3.8
    }

    /// What a finding looks like in results: enough to recognize, not to use.
    static func masked(_ f: Finding) -> String {
        guard !f.text.isEmpty else { return "" }
        if f.kind == "email", let at = f.text.firstIndex(of: "@") {
            return "\(f.text.prefix(1))…\(f.text[at...])"
        }
        return f.text.count <= 8 ? String(repeating: "•", count: f.text.count) : "\(f.text.prefix(4))…(\(f.text.count) chars)"
    }

    static func info(_ f: Finding) -> Args {
        ["kind": f.kind, "preview": masked(f),
         "box": [Int(f.rect.minX), Int(f.rect.minY), Int(f.rect.width), Int(f.rect.height)]]
    }

    static func kinds(text: Bool, faces: Bool) -> [String] {
        (text ? textKinds : []) + (faces ? ["face"] : [])
    }
}

/// Loops around text that never cut into it.
enum Shapes {
    /// A pen fine enough that its stroke and halo fit in `half` the gap to
    /// the nearest neighbor, never finer than a third of the usual weight.
    static func pen(for half: CGFloat, unit: CGFloat) -> CGFloat {
        var pen = unit * 0.85
        while pen > unit * 0.35, clearance(pen, unit) > half * 0.9 { pen *= 0.85 }
        return pen
    }

    /// How far a stroke of width `w` reaches inward from its path, halo included.
    static func clearance(_ w: CGFloat, _ unit: CGFloat) -> CGFloat { w * 0.5 + Annotator.haloWidth(w) + unit * 0.35 }

    /// The loop (an ellipse, or a squarer superellipse when space is tight)
    /// whose inner edge clears every corner of `text`. It grows taller only as
    /// far as the neighboring lines allow, then wider, then squarer.
    static func enclose(_ text: CGRect, stroke w: CGFloat, room: (left: CGFloat, right: CGFloat, above: CGFloat, below: CGFloat),
                        unit: CGFloat) -> (box: CGRect, exponent: CGFloat) {
        // The stroke and its halo straddle the path; their inner half must clear the text too.
        let clear = w * 0.5 + Annotator.haloWidth(w) + unit * 0.35
        let hw = text.width / 2 + clear, hh = text.height / 2 + clear
        let bMax = hh + max(0, min(room.above, room.below) - clear) * 0.5
        let aMax = hw + max(0, min(room.left, room.right) - clear) * 0.7
        let b = min(hh * 1.4, max(hh * 1.04, bMax))
        // Smallest a, for exponent n, that puts the corner (hw, hh) inside.
        func need(_ n: CGFloat) -> CGFloat {
            let rest = 1 - pow(hh / b, n)
            return rest > 0.0001 ? hw / pow(rest, 1 / n) : .infinity
        }
        var n: CGFloat = 2
        while need(n) > max(aMax, hw * 1.04), n < 8 { n += 0.25 }
        let a = max(min(need(n), max(aMax, hw * 1.04)), hw * 1.04)
        // Past what the room allows, keep the loop off the text even if it brushes a neighbor.
        let aFit = need(n).isFinite ? max(a, need(n)) : a
        return (CGRect(x: text.midX - aFit, y: text.midY - b, width: aFit * 2, height: b * 2), n)
    }

    /// Point on a superellipse with semi-axes a, b and exponent n at angle t.
    static func point(_ c: CGPoint, a: CGFloat, b: CGFloat, n: CGFloat, t: CGFloat, scale k: CGFloat = 1) -> CGPoint {
        let ct = cos(t), st = sin(t)
        let x = (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n) * a * k
        let y = (st < 0 ? -1 : 1) * pow(abs(st), 2 / n) * b * k
        return CGPoint(x: c.x + x, y: c.y + y)
    }

    static func loop(_ r: CGRect, exponent n: CGFloat) -> CGPath {
        if n == 2 { return CGPath(ellipseIn: r, transform: nil) }
        let path = CGMutablePath()
        for i in 0...144 {
            let p = point(CGPoint(x: r.midX, y: r.midY), a: r.width / 2, b: r.height / 2, n: n, t: CGFloat(i) / 144 * .pi * 2)
            i == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        path.closeSubpath()
        return path
    }
}
