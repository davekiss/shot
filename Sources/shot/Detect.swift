import AppKit
import Vision

/// Vision text observations for one image, kept so a range inside a line can
/// be boxed exactly (Vision measures sub-ranges itself; splitting the line's
/// box by character count would drift on proportional fonts).
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
    func find(_ query: String) -> [(text: String, rect: CGRect)] {
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var exact: [(String, CGRect)] = [], partial: [(String, CGRect)] = []
        for obs in observations {
            guard let s = text(obs), let r = s.range(of: query, options: opts) else { continue }
            if s.trimmingCharacters(in: .whitespaces).compare(query, options: opts) == .orderedSame {
                exact.append((s, rect(obs)))
            } else {
                partial.append((s, rect(obs, r)))
            }
        }
        return exact.isEmpty ? partial : exact
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

    static func locate(_ spec: Args, in ocr: OCRText, label: String) throws -> (text: String, rect: CGRect) {
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
    static func resolve(_ anns: [Args], ocr: OCRText, unit: CGFloat, found: inout [Args]) throws -> [Args] {
        let W = ocr.size.width, H = ocr.size.height
        return try anns.enumerated().map { i, a0 in
            guard a0["target"] != nil else { return a0 }
            var a = a0
            let type = a["type"] as? String ?? ""
            let hit = try locate(a, in: ocr, label: "annotation \(i) (\(type))")
            let tight = ["highlight", "redact", "pixelate", "blur", "line"].contains(type)
            let pad = CGFloat(num(a, "pad") ?? Double(unit * (tight ? 0.4 : 1.2)))
            let r = hit.rect.insetBy(dx: -pad, dy: -pad)
            func setBox() {
                if a["x"] == nil { a["x"] = r.minX; a["y"] = r.minY; a["width"] = r.width; a["height"] = r.height }
            }
            switch type {
            case "rect", "rectangle", "ellipse", "circle", "highlight", "redact", "pixelate", "blur", "spotlight":
                setBox()
            case "counter":
                if a["at"] == nil { a["at"] = [r.minX, r.minY] }
            case "line":
                let y = hit.rect.maxY + unit * 0.6
                if a["from"] == nil { a["from"] = [hit.rect.minX, y]; a["to"] = [hit.rect.maxX, y] }
            case "text":
                // Below the target, or above it when there's no room underneath.
                let size = CGFloat(num(a, "size") ?? Double(unit * 2.4))
                let below = r.maxY + unit, above = r.minY - unit - size * 1.8
                if a["at"] == nil { a["at"] = [r.minX, below + size * 1.8 > H && above > 0 ? above : below] }
            case "arrow":
                let len = CGFloat(num(a, "length") ?? Double(unit * 12))
                let (from, to) = arrow(at: r, length: len, avoiding: ocr, except: hit.rect)
                if a["to"] == nil { a["to"] = [to.x, to.y] }
                if a["from"] == nil { a["from"] = [from.x, from.y] }
            default:
                break
            }
            found.append(["annotation": i, "target": a["target"] ?? "", "matched": hit.text,
                          "box": [Int(hit.rect.minX), Int(hit.rect.minY), Int(hit.rect.width), Int(hit.rect.height)]])
            return a
        }
    }

    /// An arrow ending at the edge of `r`, coming from whichever of eight
    /// directions crosses the least other text and stays inside the image.
    /// Diagonals come first, so they win ties: they read as pointing.
    static func arrow(at r: CGRect, length: CGFloat, avoiding ocr: OCRText, except: CGRect) -> (CGPoint, CGPoint) {
        let bounds = CGRect(origin: .zero, size: ocr.size)
        let others = ocr.observations.map { ocr.rect($0) }.filter { !$0.intersects(except) }
        let c = CGPoint(x: r.midX, y: r.midY)
        let s = CGFloat(0.7071)
        let dirs = [(-s, s), (s, s), (-s, -s), (s, -s), (-1, 0), (1, 0), (0, 1), (0, -1)].map { CGPoint(x: $0.0, y: $0.1) }
        var best: (score: Int, from: CGPoint, to: CGPoint)?
        for d in dirs {
            let t = min(r.width / 2 / max(abs(d.x), 0.001), r.height / 2 / max(abs(d.y), 0.001))
            let to = CGPoint(x: c.x + d.x * t, y: c.y + d.y * t)
            let from = CGPoint(x: to.x + d.x * length, y: to.y + d.y * length)
            var score = bounds.insetBy(dx: 4, dy: 4).contains(from) ? 0 : 100
            // Sample along the shaft; each text line it passes over costs one.
            var crossed = Set<Int>()
            for k in 1...12 {
                let f = CGFloat(k) / 12
                let p = CGPoint(x: to.x + (from.x - to.x) * f, y: to.y + (from.y - to.y) * f)
                for (i, o) in others.enumerated() where o.insetBy(dx: -4, dy: -4).contains(p) { crossed.insert(i) }
            }
            score += crossed.count
            if best == nil || score < best!.score { best = (score, from, to) }
        }
        return (best!.from, best!.to)
    }

    /// `crop: {target, pad?}`: the target's box plus generous room, clamped to the image.
    static func crop(_ spec: Args, ocr: OCRText, unit: CGFloat) throws -> CGRect {
        let hit = try locate(spec, in: ocr, label: "crop")
        let pad = CGFloat(num(spec, "pad") ?? Double(unit * 12))
        return hit.rect.insetBy(dx: -pad, dy: -pad).intersection(CGRect(origin: .zero, size: ocr.size))
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
