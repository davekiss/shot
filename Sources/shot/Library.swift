import AppKit
import ImageIO
import UniformTypeIdentifiers
import Vision

/// A searchable record of every screenshot, so an agent can find the right one
/// without opening images. One JSON file beside the screenshots, shared by every
/// shot process (each Claude session runs its own server), so writes are locked.
enum Library {
    /// SHOT_LIBRARY moves the library (and its index) somewhere other than ~/Screenshots.
    static var root: String {
        ProcessInfo.processInfo.environment["SHOT_LIBRARY"].map(expand) ?? "\(NSHomeDirectory())/Screenshots"
    }
    static var indexPath: String { "\(root)/.shot-index.json" }
    static let maxText = 4000

    // MARK: records

    /// Builds a record for one image: file facts, where it came from, and its text.
    static func record(path: String, img: CGImage? = nil, window: Windows.Win? = nil, from parent: Args? = nil) throws -> Args {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let image = try img ?? loadImage(path)
        let text = recognize(image).map { $0.text }.joined(separator: "\n")
        var r: Args = [
            "path": path,
            "taken_at": iso((attrs[.creationDate] as? Date) ?? Date()),
            "mtime": ((attrs[.modificationDate] as? Date) ?? Date()).timeIntervalSince1970,
            "bytes": (attrs[.size] as? NSNumber)?.intValue ?? 0,
            "width": image.width,
            "height": image.height,
            "source": source(of: path),
            "text": String(text.prefix(maxText)),
        ]
        if let window {
            r["app"] = window.app
            r["window"] = window.label
        } else if let parent {
            r["app"] = parent["app"]
            r["window"] = parent["window"]
            r["description"] = parent["description"]
            r["described_by"] = parent["described_by"]
            r["edited_from"] = parent["path"]
        } else if let meta = pngMetadata(path) {
            r["app"] = meta.app
            r["window"] = meta.window
            r["description"] = meta.description
        }
        return r.filter { ($0.value as? String)?.isEmpty != true }
    }

    static func source(of path: String) -> String {
        let name = (path as NSString).lastPathComponent
        if name.hasPrefix("CleanShot ") { return "cleanshot" }
        if name.hasPrefix("Shot ") { return "shot" }
        if name.hasPrefix("Screenshot ") { return "macos" }
        return "other"
    }

    // MARK: index file

    static func withIndex<T>(_ body: (inout [String: Args]) throws -> T) throws -> T {
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let fd = open("\(indexPath).lock", O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw ShotError("Can't open the index lock") }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN); close(fd) }

        var index: [String: Args] = [:]
        if let data = FileManager.default.contents(atPath: indexPath),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? Args,
           let shots = obj["shots"] as? [Args] {
            for s in shots { if let p = s["path"] as? String { index[p] = s } }
        }
        let before = index.count, snapshot = json(index.values.map { $0 })
        let result = try body(&index)
        if index.count != before || json(index.values.map { $0 }) != snapshot {
            let shots = index.values.sorted { ($0["mtime"] as? Double ?? 0) > ($1["mtime"] as? Double ?? 0) }
            let data = try JSONSerialization.data(withJSONObject: ["version": 1, "shots": shots], options: [.sortedKeys, .withoutEscapingSlashes])
            try data.write(to: URL(fileURLWithPath: indexPath), options: .atomic)
        }
        return result
    }

    /// Indexes one file now (capture and compose call this for what they write).
    static func add(_ r: Args) {
        _ = try? withIndex { $0[r["path"] as! String] = r }
    }

    static func lookup(_ path: String) -> Args? {
        try? withIndex { $0[path] }
    }

    /// Brings the index up to date with ~/Screenshots: drops files that are gone,
    /// and reads new or changed PNGs until the time budget runs out.
    @discardableResult
    static func sync(budget: TimeInterval = 20) throws -> (indexed: Int, pending: Int) {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: root)) ?? []
        let onDisk = names.filter { $0.lowercased().hasSuffix(".png") && !$0.hasPrefix(".") }.map { "\(root)/\($0)" }
        let stale = try withIndex { index -> [String] in
            for p in index.keys where !fm.fileExists(atPath: p) { index.removeValue(forKey: p) }
            return onDisk.filter { p in
                let m = ((try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                return (index[p]?["mtime"] as? Double).map { abs($0 - m) > 0.5 } ?? true
            }
        }
        // Newest first, so a cut-off budget still covers what agents ask about most.
        let ordered = stale.sorted {
            let m = { (p: String) in ((try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date) ?? .distantPast }
            return m($0) > m($1)
        }
        let deadline = Date().addingTimeInterval(budget)
        var done = 0
        for p in ordered {
            if Date() > deadline { break }
            guard var r = try? record(path: p) else { continue }
            // Keep what an agent or describer already said about this file.
            if let old = lookup(p) {
                for k in ["description", "described_by", "app", "window"] where r[k] == nil { r[k] = old[k] }
            }
            add(r)
            done += 1
        }
        return (done, ordered.count - done)
    }

    // MARK: descriptions

    /// Saves a description for one file, in the index and in the PNG itself.
    static func annotate(_ a: Args) throws -> Args {
        guard let raw = a["path"] as? String, let description = a["description"] as? String,
              !description.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ShotError("annotate needs path and description")
        }
        return try describe(path: expand(raw), description, by: a["described_by"] as? String ?? "agent")
    }

    static func describe(path: String, _ description: String, by: String) throws -> Args {
        guard FileManager.default.fileExists(atPath: path) else { throw ShotError("No file at \(path)") }
        var r = try lookup(path) ?? record(path: path)
        // Only files shot wrote carry its metadata; other apps' files stay byte-for-byte as they were.
        if path.lowercased().hasSuffix(".png"), pngMetadata(path) != nil || r["source"] as? String == "shot" {
            writePNGMetadata(path, app: r["app"] as? String, window: r["window"] as? String, description: description)
        }
        r["description"] = description
        r["described_by"] = by
        // Writing the metadata touched the file; keep the record current so sync doesn't re-read it.
        if let m = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date {
            r["mtime"] = m.timeIntervalSince1970
        }
        add(r)
        return ["path": path, "description": description, "described_by": by]
    }

    // MARK: search

    static func find(_ a: Args) throws -> Args {
        let (indexed, pending) = try sync(budget: num(a, "index_budget") ?? 20)
        let query = (a["query"] as? String ?? "").lowercased()
        let terms = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 }
        let since = (a["since"] as? String).flatMap(parseDate)
        let until = (a["until"] as? String).flatMap(parseDate)
        let app = (a["app"] as? String)?.lowercased()
        let limit = Int(num(a, "limit") ?? 10)

        let all = try withIndex { Array($0.values) }
        var hits: [(score: Double, r: Args)] = []
        for r in all {
            let taken = (r["taken_at"] as? String).flatMap(parseDate) ?? .distantPast
            if let since, taken < since { continue }
            if let until, taken > until { continue }
            if let app, !((r["app"] as? String)?.lowercased().contains(app) ?? false) { continue }
            var score = 0.0
            if !terms.isEmpty {
                let fields: [(String, Double)] = [
                    ((r["description"] as? String ?? "").lowercased(), 3),
                    (Windows.label(r["window"] as? String ?? "").lowercased(), 2),
                    ((r["app"] as? String ?? "").lowercased(), 2),
                    (searchableName(r["path"] as? String ?? "").lowercased(), 1),
                    ((r["text"] as? String ?? "").lowercased(), 1),
                ]
                var matched = 0
                for t in terms {
                    let best = fields.filter { $0.0.contains(t) }.map { $0.1 }.max()
                    if let best { score += best; matched += 1 }
                }
                if matched == 0 { continue }
                score += Double(matched) * 10  // more distinct terms beats one heavy field
            }
            hits.append((score, r))
        }
        hits.sort { $0.score != $1.score ? $0.score > $1.score : ($0.r["mtime"] as? Double ?? 0) > ($1.r["mtime"] as? Double ?? 0) }

        let shots: [Args] = hits.prefix(limit).map { h in
            var out = h.r
            let text = out.removeValue(forKey: "text") as? String ?? ""
            out.removeValue(forKey: "mtime")
            if let w = out["window"] as? String { out["window"] = Windows.label(w) }
            if !text.isEmpty { out["text_excerpt"] = excerpt(text, terms) }
            return out
        }
        var info: Args = ["shots": shots, "matches": hits.count, "indexed_now": indexed]
        if pending > 0 { info["still_indexing"] = "\(pending) screenshots not read yet; call again to include them" }
        return info
    }

    /// The part of a filename worth matching: "Shot 2026-10-01 at 3.29.09 PM edited.png"
    /// is "edited". Every stamped name starts the same way, so the stamp would
    /// match "shot" or "screenshot" in every query; dates have since/until.
    static func searchableName(_ path: String) -> String {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return name.replacingOccurrences(
            of: #"^(Shot|CleanShot|Screenshot) \d{4}-\d{2}-\d{2} at [\d.]+(\s?[AP]M)?(@\dx)?\s*"#,
            with: "", options: [.regularExpression, .caseInsensitive])
    }

    static func excerpt(_ text: String, _ terms: [String], width: Int = 240) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " · ")
        let lower = flat.lowercased()
        guard let hit = terms.compactMap({ lower.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else {
            return String(flat.prefix(width)) + (flat.count > width ? "…" : "")
        }
        let at = lower.distance(from: lower.startIndex, to: hit.lowerBound)
        let start = max(0, at - width / 3)
        let s = flat.index(flat.startIndex, offsetBy: start)
        let e = flat.index(s, offsetBy: min(width, flat.distance(from: s, to: flat.endIndex)))
        return (start > 0 ? "…" : "") + flat[s..<e] + (e < flat.endIndex ? "…" : "")
    }

    // MARK: dates

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: d)
    }

    /// ISO dates or times, or relative spans like "2h", "3d", "1w".
    static func parseDate(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if let n = Double(t.dropLast()), let unit = t.last, let secs = ["m": 60.0, "h": 3600, "d": 86400, "w": 604800][String(unit)] {
            return Date().addingTimeInterval(-n * secs)
        }
        let full = ISO8601DateFormatter()
        if let d = full.date(from: s) { return d }
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.timeZone = .current
        return day.date(from: s)
    }

    // MARK: PNG metadata

    /// Writes app, window and description into the PNG's own text chunks, so
    /// they travel with the file wherever it is copied.
    static func writePNGMetadata(_ path: String, app: String?, window: String?, description: String?) {
        let url = URL(fileURLWithPath: path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
        let data = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return }
        var png: [CFString: Any] = [kCGImagePropertyPNGSoftware: "shot"]
        let title = [app, window].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
        if !title.isEmpty { png[kCGImagePropertyPNGTitle] = title }
        if let description, !description.isEmpty { png[kCGImagePropertyPNGDescription] = description }
        CGImageDestinationAddImageFromSource(dst, src, 0, [kCGImagePropertyPNGDictionary: png] as CFDictionary)
        if CGImageDestinationFinalize(dst) { try? (data as Data).write(to: url, options: .atomic) }
    }

    static func pngMetadata(_ path: String) -> (app: String?, window: String?, description: String?)? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any],
              (png[kCGImagePropertyPNGSoftware] as? String) == "shot" else { return nil }
        let title = (png[kCGImagePropertyPNGTitle] as? String ?? "").components(separatedBy: " — ")
        return (title.first, title.count > 1 ? title.dropFirst().joined(separator: " — ") : nil, png[kCGImagePropertyPNGDescription] as? String)
    }
}

// MARK: - OCR

struct TextLine { let text: String; let rect: CGRect; let confidence: Float }

/// Vision text recognition, lines in reading order, rects in image pixels.
func recognize(_ img: CGImage, offset: CGPoint = .zero) -> [TextLine] {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = true
    try? VNImageRequestHandler(cgImage: img).perform([req])
    let W = CGFloat(img.width), H = CGFloat(img.height)
    let lines: [TextLine] = (req.results ?? []).compactMap { obs in
        guard let cand = obs.topCandidates(1).first else { return nil }
        let b = obs.boundingBox
        return TextLine(text: cand.string,
                        rect: CGRect(x: b.minX * W + offset.x, y: (1 - b.maxY) * H + offset.y, width: b.width * W, height: b.height * H),
                        confidence: cand.confidence)
    }
    return lines.sorted { (Int($0.rect.minY) / 8, Int($0.rect.minX)) < (Int($1.rect.minY) / 8, Int($1.rect.minX)) }
}
