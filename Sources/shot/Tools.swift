import AppKit
import Vision

struct ToolResult {
    var info: Args
    var image: CGImage?

    func mcp() -> Args {
        var info = self.info
        var content: [Args] = []
        if let image, let (data, scale) = preview(image) {
            info["preview_scale"] = NSDecimalNumber(string: String(format: "%.3f", scale))
            content.append(["type": "image", "data": data.base64EncodedString(), "mimeType": "image/jpeg"])
        }
        content.insert(["type": "text", "text": json(info)], at: 0)
        return ["content": content]
    }
}

func json(_ obj: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "\(obj)" }
    return String(data: data, encoding: .utf8) ?? ""
}

enum Tools {
    static let instructions = """
        shot captures and edits screenshots headlessly (no app UI, never takes focus). \
        Coordinates are always pixels of the input image with a top-left origin; returned previews are downscaled, \
        so divide preview coordinates by preview_scale. Typical flow: capture → compose, pointing annotations at text with target \
        instead of coordinates. compose covers sensitive text by default. \
        Every screenshot in ~/Screenshots (and every file shot writes) is indexed with its app, window and text: \
        use find_shots to locate an earlier screenshot instead of opening images one by one.
        """

    static func call(_ name: String, _ a: Args) throws -> ToolResult {
        Scratch.sweep()
        var result = try dispatch(name, a)
        // Anything written into the ephemeral folder says so, and when it goes.
        if let p = result.info["path"] as? String ?? result.info["storyboard"] as? String, Scratch.contains(p) {
            result.info["ephemeral"] = true
            result.info["deleted_after_seconds"] = Int(Scratch.ttl)
        }
        return result
    }

    static func dispatch(_ name: String, _ a: Args) throws -> ToolResult {
        switch name {
        case "capture": return try capture(a)
        case "compose": return try compose(a)
        case "ocr": return try ocr(a)
        case "diff": return try diff(a)
        case "point": return try Overlay.point(a)
        case "record": return try Record.run(a)
        // Internal: the helper process that shows a point overlay, then exits.
        case "_overlay": Overlay.show(a)
        case "find_sensitive":
            guard let input = a["input"] as? String else { throw ShotError("find_sensitive needs input (an image path)") }
            let findings = Sensitive.scan(try loadImage(input), kinds: Sensitive.kinds(text: true, faces: flag(a, "faces")))
            return ToolResult(info: ["findings": findings.map(Sensitive.info), "count": findings.count])
        case "list_windows": return ToolResult(info: ["windows": Windows.list(all: flag(a, "all")).map { $0.info }])
        case "find_shots": return ToolResult(info: try Library.find(a))
        case "annotate": return ToolResult(info: try Library.annotate(a))
        // CLI only: describe waiting screenshots now, e.g. shot describe '{"limit":3}'.
        case "describe": return ToolResult(info: ["described": try Describer.runOnce(limit: Int(num(a, "limit") ?? 5)), "mode": Describer.mode])
        default: throw ShotError("Unknown tool \(name)")
        }
    }

    // MARK: capture

    static func capture(_ a: Args) throws -> ToolResult {
        try requireScreenRecording()
        let mode = a["mode"] as? String ?? "screen"
        let out = (a["output"] as? String).map(expand) ?? (flag(a, "ephemeral") ? Scratch.path("Shot") : timestampedPath("Shot"))
        try FileManager.default.createDirectory(atPath: (out as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var args = ["-x", "-t", "png"]
        var info: Args = [:]
        var window: Windows.Win?
        switch mode {
        case "screen":
            if let d = num(a, "display") { args += ["-D", "\(Int(d))"] } else { args.append("-m") }
        case "window":
            let w = try Windows.find(id: num(a, "window_id").map { Int($0) }, app: a["app"] as? String, title: a["title"] as? String)
            args += ["-l", "\(w.id)"]
            window = w
            if !flag(a, "shadow") { args.append("-o") }
            info["window"] = w.info
        case "region":
            guard let r = box(a["region"] ?? a) else { throw ShotError("region mode needs x, y, width, height in screen points") }
            args += ["-R", "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))"]
        default:
            throw ShotError("mode must be screen, window or region")
        }
        if flag(a, "cursor") { args.append("-C") }
        func snap(_ path: String) throws {
            let (status, output) = try run("/usr/sbin/screencapture", args + [path])
            guard status == 0, FileManager.default.fileExists(atPath: path) else {
                throw ShotError("screencapture failed (\(status)): \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        if let cond = try Wait.condition(a["wait_for"]) {
            // Re-capture until the condition holds or time runs out, and keep
            // the last frame either way: a timeout still shows what was there.
            let spec = a["wait_for"] as? Args ?? [:]
            let timeout = min(num(spec, "timeout") ?? 20, 120)
            let start = Date(), tmp = out + ".waiting.png"
            var last: CGImage?, steadySince: Date?, met = false
            repeat {
                try snap(tmp)
                let img = try loadImage(tmp)
                if case .stable(let seconds) = cond {
                    let same = last.map { (try? Diff.regions($0, img))?.isEmpty ?? false } ?? false
                    steadySince = same ? (steadySince ?? Date()) : nil
                    met = steadySince.map { Date().timeIntervalSince($0) >= seconds } ?? false
                    last = img
                } else {
                    met = Wait.met(cond, img)
                }
                if met { break }
                Thread.sleep(forTimeInterval: 0.4)
            } while Date().timeIntervalSince(start) < timeout
            try? FileManager.default.removeItem(atPath: out)
            try FileManager.default.moveItem(atPath: tmp, toPath: out)
            info["waited_seconds"] = (Date().timeIntervalSince(start) * 10).rounded() / 10
            info["wait_met"] = met
            if !met { info["wait_note"] = "Timed out after \(Int(timeout))s; this is the last frame." }
        } else {
            try snap(out)
        }
        let img = try loadImage(out)
        // Scratch captures (point's look at the screen) stay out of the library.
        if !flag(a, "_scratch") {
            if let window, !Scratch.contains(out) { Library.writePNGMetadata(out, app: window.app, window: window.label, description: nil) }
            Library.add(try Library.record(path: out, img: img, window: window))
        }
        info["path"] = out
        info["width"] = img.width
        info["height"] = img.height
        return ToolResult(info: info, image: flag(a, "preview", true) ? img : nil)
    }

    // MARK: compose

    static func compose(_ a: Args) throws -> ToolResult {
        guard let input = a["input"] as? String else { throw ShotError("compose needs input (an image path)") }
        var img = try loadImage(input)
        let original = img
        // Backgrounds scale with the image; marks scale with its text (below).
        let unit = CGFloat(max(2, Double(min(img.width, img.height)) / 160))
        var markUnit = CGFloat(max(2, sqrt(Double(img.width * img.height)) / 200))
        var origin = CGPoint.zero
        var info: Args = ["input_size": [img.width, img.height]]
        var anns = a["annotations"] as? [Args] ?? []
        // A font for the whole call applies to every mark that doesn't name its own.
        // A font or mark style for the whole call applies to every mark that doesn't name its own.
        for key in ["font", "style"] {
            if let v = a[key] as? String { anns = anns.map { var m = $0; if m[key] == nil { m[key] = v }; return m } }
        }

        // Targets and sensitive data are found on the original input, so their
        // boxes are in the same pixels as every other annotation coordinate.
        if Targets.needed(a) {
            let ocr = OCRText(img)
            // Text sets the scale: an arrow should be as bold as the words it points at.
            markUnit = Annotator.markUnit(img, textHeight: ocr.textHeight)
            let unit = markUnit
            var found: [Args] = []
            // The crop is worked out first so marks are placed inside what will be kept.
            var visible = box(a["crop"])
            if let spec = a["crop"] as? Args, spec["target"] != nil { visible = try Targets.crop(spec, ocr: ocr, unit: unit) }
            anns = try Targets.resolve(anns, ocr: ocr, unit: unit, visible: visible, found: &found)
            if !found.isEmpty { info["targets"] = found }
            if let spec = a["crop"] as? Args, spec["target"] != nil, let r = visible {
                info["crop"] = [Int(r.minX), Int(r.minY), Int(r.width), Int(r.height)]
                guard let cropped = img.cropping(to: r.integral) else { throw ShotError("crop is outside the image") }
                img = cropped
                origin = r.integral.origin
            }
        }
        // On unless turned off: a forgotten flag shouldn't be how a key gets shared.
        let kinds = Sensitive.kinds(text: flag(a, "redact_sensitive", true), faces: flag(a, "redact_faces"))
        if !kinds.isEmpty {
            let style = a["redact_style"] as? String ?? "box"
            guard ["box", "pixelate", "blur"].contains(style) else { throw ShotError("redact_style must be box, pixelate or blur") }
            let findings = Sensitive.scan(original, kinds: kinds)
            // Drawn first, so the caller's own labels and arrows stay on top.
            anns = findings.map { f in
                let r = f.rect.insetBy(dx: -max(unit * 0.25, f.rect.height * 0.08), dy: -max(unit * 0.4, f.rect.height * 0.25))
                let type = f.kind == "face" && style == "box" ? "pixelate" : (style == "box" ? "redact" : style)
                return ["type": type, "x": r.minX, "y": r.minY, "width": r.width, "height": r.height]
            } + anns
            info["redacted"] = findings.map(Sensitive.info)
            if !findings.isEmpty, a["redact_sensitive"] == nil {
                info["redacted_note"] = "Sensitive text is covered by default. Pass redact_sensitive: false to keep it visible."
            }
        }

        if a["crop"].flatMap({ ($0 as? Args)?["target"] }) == nil, let c = box(a["crop"]) {
            guard let cropped = img.cropping(to: c.integral) else { throw ShotError("crop is outside the image") }
            img = cropped
            origin = c.integral.origin
        }
        if flag(a, "auto_balance") {
            if let b = Balance.compute(img), let trimmed = img.cropping(to: b.rect) {
                img = trimmed
                origin = CGPoint(x: origin.x + b.rect.minX, y: origin.y + b.rect.minY)
                info["auto_balance"] = b.margins
            } else {
                info["auto_balance"] = "skipped: edges aren't a uniform color"
            }
        }
        if !anns.isEmpty {
            img = try Annotator.apply(anns, to: img, offset: origin, unit: markUnit)
        }
        if let bg = a["background"] as? Args {
            img = try Background.apply(bg, to: img, unit: unit)
        }

        let out = (a["output"] as? String).map(expand) ?? editedPath(for: input)
        try writePNG(img, to: out)
        var parent = Library.lookup(expand(input)) ?? ["path": expand(input)]
        if let d = a["description"] as? String, !d.isEmpty { parent["description"] = d; parent["described_by"] = "agent" }
        Library.writePNGMetadata(out, app: parent["app"] as? String, window: parent["window"] as? String, description: parent["description"] as? String)
        Library.add(try Library.record(path: out, img: img, from: parent))
        if flag(a, "copy") { copyToClipboard(img) }
        info["path"] = out
        info["width"] = img.width
        info["height"] = img.height
        if origin != .zero { info["content_origin"] = [origin.x, origin.y] }
        return ToolResult(info: info, image: flag(a, "preview", true) ? img : nil)
    }

    // MARK: diff

    static func diff(_ a: Args) throws -> ToolResult {
        guard let beforePath = a["before"] as? String, let afterPath = a["after"] as? String else {
            throw ShotError("diff needs before and after (image paths)")
        }
        let before = try loadImage(beforePath), after = try loadImage(afterPath)
        let rects = try Diff.regions(before, after, minArea: num(a, "min_area").map { CGFloat($0) })
        guard !rects.isEmpty else { return ToolResult(info: ["changed": 0, "note": "No visible changes."]) }
        let regions = Diff.describe(rects, before, after)
        let unit = Annotator.markUnit(after, textHeight: OCRText(after).textHeight)
        // Each change gets a box and a number matching the list returned.
        let anns: [Args] = rects.enumerated().flatMap { i, r -> [Args] in
            let box = r.insetBy(dx: -unit, dy: -unit)
            // The badge sits off the box's corner, so it never covers the change it labels.
            let off = Annotator.counterRadius(unit) * 0.75
            return [["type": "rect", "x": box.minX, "y": box.minY, "width": box.width, "height": box.height],
                    ["type": "counter", "at": [max(off, box.minX - off), max(off, box.minY - off)], "number": i + 1]]
        }
        let marked = try Annotator.apply(anns, to: after, offset: .zero, unit: unit)
        let out = (a["output"] as? String).map(expand) ?? editedPath(for: afterPath).replacingOccurrences(of: " edited.png", with: " diff.png")
        try writePNG(marked, to: out)
        let parent = Library.lookup(expand(afterPath)) ?? ["path": expand(afterPath)]
        Library.add(try Library.record(path: out, img: marked, from: parent))
        let area = rects.reduce(0) { $0 + $1.width * $1.height } / CGFloat(after.width * after.height)
        let list: [Args] = regions.enumerated().map { i, g in
            var r: Args = ["n": i + 1, "box": [Int(g.rect.minX), Int(g.rect.minY), Int(g.rect.width), Int(g.rect.height)]]
            if g.before != g.after { r["text_before"] = g.before; r["text_after"] = g.after }
            return r
        }
        return ToolResult(info: ["changed": regions.count, "regions": list, "changed_area": NSDecimalNumber(string: String(format: "%.3f", area)),
                                 "path": out, "width": marked.width, "height": marked.height],
                          image: flag(a, "preview", true) ? marked : nil)
    }

    // MARK: ocr

    static func ocr(_ a: Args) throws -> ToolResult {
        guard let input = a["input"] as? String else { throw ShotError("ocr needs input (an image path)") }
        var img = try loadImage(input)
        var origin = CGPoint.zero
        if let r = box(a["region"]), let c = img.cropping(to: r.integral) { img = c; origin = r.integral.origin }
        let find = (a["find"] as? String)?.lowercased()
        let lines: [Args] = recognize(img, offset: origin)
            .filter { find == nil || $0.text.lowercased().contains(find!) }
            .map { l in [
                "text": l.text,
                "x": Int(l.rect.minX), "y": Int(l.rect.minY), "width": Int(l.rect.width), "height": Int(l.rect.height),
                "confidence": NSDecimalNumber(string: String(format: "%.2f", l.confidence)),
            ] }
        var info: Args = ["lines": lines, "text": lines.map { $0["text"] as! String }.joined(separator: "\n")]
        if find != nil { info.removeValue(forKey: "text") }
        return ToolResult(info: info)
    }

    // MARK: schemas

    static let point: Args = ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2, "description": "[x, y] in input pixels"]
    static let rect: Args = ["type": "object", "properties": ["x": ["type": "number"], "y": ["type": "number"], "width": ["type": "number"], "height": ["type": "number"]], "required": ["x", "y", "width", "height"]]

    static let definitions: [Args] = [
        [
            "name": "capture",
            "description": "Take a screenshot silently without changing focus. Windows are captured even when covered by other windows. Saves a PNG (default ~/Screenshots/Shot <timestamp>.png) and returns its path, pixel size and a preview. Once you have looked at the preview, call annotate with a one-sentence description of what it shows, so later agents can find it with find_shots without opening it.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "mode": ["type": "string", "enum": ["screen", "window", "region"], "description": "Default screen (main display)."],
                    "app": ["type": "string", "description": "window mode: app name substring, e.g. 'Chrome'. Omit app/title/window_id for the frontmost window."],
                    "title": ["type": "string", "description": "window mode: window title substring."],
                    "window_id": ["type": "number", "description": "window mode: exact id from list_windows."],
                    "shadow": ["type": "boolean", "description": "window mode: include the macOS window shadow. Default false."],
                    "region": ["type": "object", "description": "region mode: rectangle in screen points (not pixels).", "properties": rect["properties"]!],
                    "display": ["type": "number", "description": "screen mode: display number (1 = main)."],
                    "cursor": ["type": "boolean"],
                    "output": ["type": "string", "description": "Output PNG path."],
                    "preview": ["type": "boolean", "description": "Return a preview image. Default true."],
                    "ephemeral": ["type": "boolean", "description": "For a quick look you won't need later: the file goes to a temp folder instead of ~/Screenshots, stays out of the library, and is deleted after 10 minutes. Follow-up ocr/compose/diff on it still work in that window, and their outputs are ephemeral too unless given an output path."],
                    "wait_for": ["type": "object", "description": "Re-capture until a condition holds, then keep that frame: {text: 'Deployed'} waits for text to appear, {gone: 'Loading'} for it to disappear, {stable: 1} for 1s of no visible change (pages that finished loading). timeout: seconds, default 20, max 120. The result says whether it was met; on timeout you get the last frame.",
                                 "properties": ["text": ["type": "string"], "gone": ["type": "string"], "stable": ["type": "number"], "timeout": ["type": "number"]]],
                ],
            ],
        ],
        [
            "name": "record",
            "description": "Record a window, a screen region or the main screen for a few seconds without taking focus, and get back a storyboard: the moments where something visibly changed, each with its timestamp, frame and the text that appeared or changed, plus one image laying those moments out in a grid. Use it to see what happens over time (a flicker after clicking Save, a slow load, an animation, a deploy) instead of guessing from single screenshots. Saves an MP4 (and a GIF with gif: true). Blocks for up to `seconds`.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "app": ["type": "string", "description": "Window to record: app name substring. Omit app/title/window_id/region for the main screen."],
                    "title": ["type": "string", "description": "Window title substring."],
                    "window_id": ["type": "number", "description": "Exact id from list_windows."],
                    "region": ["type": "object", "description": "A screen rectangle in points instead of a window. Unlike window recording, this includes anything drawn over it, such as point's marks.", "properties": rect["properties"]!],
                    "seconds": ["type": "number", "description": "How long to record. Default 10, max 60."],
                    "until": ["type": "object", "description": "Stop early when a condition holds, like capture's wait_for: {text: 'Deployed'}, {gone: 'Loading'} or {stable: 1}. seconds is the limit.",
                              "properties": ["text": ["type": "string"], "gone": ["type": "string"], "stable": ["type": "number"]]],
                    "gif": ["type": "boolean", "description": "Also save an animated GIF (8 fps, up to 960px wide) for sharing."],
                    "ephemeral": ["type": "boolean", "description": "Keep nothing: the video, frames and storyboard go to a temp folder and are deleted after 10 minutes. Use when you only need to read the storyboard."],
                    "fps": ["type": "number", "description": "Video frame rate. Default 30."],
                    "hide_cursor": ["type": "boolean"],
                    "output": ["type": "string", "description": "Base path for the files (.mp4, .gif, ' storyboard.png', ' frames/'). Default ~/Screenshots/Recording <time>."],
                    "preview": ["type": "boolean", "description": "Return the storyboard image. Default true."],
                ],
            ],
        ],
        [
            "name": "point",
            "description": "Show marks on the user's live screen for a few seconds: an arrow, box, numbered steps, a label or a spotlight drawn right over a window, then faded away. Nothing is saved, focus never moves, and clicks pass through. Use it to show the user where something is ('where's the export button?') instead of describing it. Annotations take target text like compose. Returns at once; the marks stay up for `seconds`.",
            "inputSchema": [
                "type": "object",
                "required": ["annotations"],
                "properties": [
                    "app": ["type": "string", "description": "Window to point at: app name substring. Omit app/title/window_id to point at the main screen."],
                    "title": ["type": "string", "description": "Window title substring."],
                    "window_id": ["type": "number", "description": "Exact id from list_windows."],
                    "annotations": ["type": "array", "description": "Same as compose: arrow, rect, ellipse, line, text, counter, highlight, spotlight, each usually with target: 'text on screen'.", "items": ["type": "object"]],
                    "seconds": ["type": "number", "description": "How long the marks stay up. Default 4, max 15."],
                    "font": ["type": "string", "description": "Type style for labels and counters, as in compose."],
                    "style": ["type": "string", "enum": ["crisp", "sketch"], "description": "Mark style, as in compose."],
                ],
            ],
        ],
        [
            "name": "diff",
            "description": "Compare two screenshots of the same size (e.g. before and after a change) and find what changed. Returns each changed region's box plus the text inside it before and after, and saves the after image with each change boxed and numbered. Use it to check that an edit did something, or to show what changed.",
            "inputSchema": [
                "type": "object",
                "required": ["before", "after"],
                "properties": [
                    "before": ["type": "string", "description": "Path to the earlier screenshot."],
                    "after": ["type": "string", "description": "Path to the later screenshot."],
                    "output": ["type": "string", "description": "Output PNG path. Default: '<after> diff.png'."],
                    "min_area": ["type": "number", "description": "Ignore changes smaller than this many square pixels (blinking carets, clocks). Default scales with the image."],
                    "preview": ["type": "boolean", "description": "Return a preview image. Default true."],
                ],
            ],
        ],
        [
            "name": "compose",
            "description": "Edit a screenshot like CleanShot's editor and save a new PNG: crop, auto-balance uneven margins, annotate, then place it on a background with padding/inset/shadow/rounded corners/aspect ratio. Processing order: crop → auto_balance → annotations → background. All annotation coordinates are pixels of the ORIGINAL input image (top-left origin), even when cropping or balancing. Default stroke widths and text sizes scale with the image.",
            "inputSchema": [
                "type": "object",
                "required": ["input"],
                "properties": [
                    "input": ["type": "string", "description": "Path to the source image."],
                    "output": ["type": "string", "description": "Output PNG path. Default: '<input> edited.png' next to the input."],
                    "copy": ["type": "boolean", "description": "Also copy the result to the clipboard."],
                    "description": ["type": "string", "description": "One sentence on what the result shows, saved with it for find_shots. Defaults to the input's description."],
                    "preview": ["type": "boolean", "description": "Return a preview image. Default true."],
                    "crop": ["type": "object", "description": "x, y, width, height in input pixels, or {target: 'text' or ['text', 'more text'], pad?} to crop around the lines that text is on.",
                             "properties": ["x": ["type": "number"], "y": ["type": "number"], "width": ["type": "number"], "height": ["type": "number"],
                                            "target": ["description": "Text, or a list of texts, to crop around."], "nth": ["type": "number"], "pad": ["type": "number"]]],
                    "style": ["type": "string", "enum": ["crisp", "sketch"], "description": "Mark style for every shape: crisp (default, clean geometric lines) or sketch (hand-drawn: wobbly boxes, overshooting circles, bowed arrows, highlighter swipes). Any annotation can set its own. SHOT_STYLE sets the default."],
                    "font": ["type": "string", "description": "Type style for every label and counter: pixel (default, shot's own), clean, rounded, serif, mono, or an installed font name. Any annotation can set its own font too. SHOT_FONT sets the default."],
                    "redact_sensitive": ["type": "boolean", "description": "On by default: finds and covers sensitive text before anything else is drawn (API keys, tokens, passwords, JWTs, private keys, emails, card numbers, phone numbers). The result lists what was covered with masked previews, never the values. Pass false only when the user wants that text visible."],
                    "redact_faces": ["type": "boolean", "description": "Also pixelate faces (off by default: avatars are often what a screenshot is showing)."],
                    "redact_style": ["type": "string", "enum": ["box", "pixelate", "blur"], "description": "How sensitive text is covered. Default box (solid; the only one that can't be read back). Faces are always pixelated."],
                    "auto_balance": ["type": "boolean", "description": "Trim uniform-colored margins so all four sides match the smallest one."],
                    "annotations": [
                        "type": "array",
                        "description": """
                            Drawn in order (pixelate/blur first, then spotlight, then the rest). Types and fields:
                            arrow {from, to}; line {from, to}; rect {x,y,width,height, fill?}; ellipse {x,y,width,height, fill?};
                            text {at:[x,y] top-left, text, size?, background?: true|color (pill label), text_color?, bold? (default true), max_width?};
                            counter {at:[x,y] center, number? (auto-increments), label?, size? (radius)};
                            highlight {x,y,width,height} marker-style; redact {x,y,width,height} solid box;
                            pixelate|blur {x,y,width,height, amount?}; spotlight {x,y,width,height, shape?: rect|ellipse, opacity? 0-1}.
                            Instead of coordinates, any annotation can take target: 'text in the image' (nth? when it appears more than once, pad? in px):
                            boxes surround the text, counter sits on its top-left corner, arrow points at it from open space (length?), text goes below it, line underlines it.
                            The result's targets list where each was found. If the text isn't found, the error lists the text that is there.
                            Common: color (hex or red/orange/yellow/green/blue/purple/pink/white/black/gray; by default marks draw in ink that adapts to what's underneath: near-black on light areas, near-white on dark, each with a halo), stroke (line thickness px). Sizes scale with the text in the image.
                            """,
                        "items": [
                            "type": "object",
                            "required": ["type"],
                            "properties": [
                                "target": ["type": "string", "description": "Text in the image to place this annotation at, instead of coordinates."],
                                "nth": ["type": "number"], "pad": ["type": "number"], "length": ["type": "number"],
                                "type": ["type": "string", "enum": ["arrow", "line", "rect", "ellipse", "text", "counter", "highlight", "redact", "pixelate", "blur", "spotlight"]],
                                "from": point, "to": point, "at": point,
                                "x": ["type": "number"], "y": ["type": "number"], "width": ["type": "number"], "height": ["type": "number"],
                                "text": ["type": "string"], "size": ["type": "number"], "color": ["type": "string"],
                                "background": ["description": "text: true for a tag in the mark's ink, or a color string"],
                                "text_color": ["type": "string"], "font": ["type": "string"], "style": ["type": "string"], "bold": ["type": "boolean"], "max_width": ["type": "number"],
                                "number": ["type": "number"], "label": ["type": "string"], "fill": ["description": "true or a color"],
                                "amount": ["type": "number"], "shape": ["type": "string"], "opacity": ["type": "number"], "stroke": ["type": "number"],
                            ],
                        ],
                    ],
                    "background": [
                        "type": "object",
                        "description": "Omit for no background.",
                        "properties": [
                            "type": ["type": "string", "enum": ["gradient", "color", "blurred", "wallpaper", "image", "none"], "description": "Default gradient. blurred = the screenshot itself blurred behind it; wallpaper = current desktop picture."],
                            "preset": ["type": "string", "enum": ["violet", "sunset", "ocean", "mint", "dusk", "peach", "candy", "slate"], "description": "gradient preset, default violet."],
                            "colors": ["type": "array", "items": ["type": "string"], "description": "Custom gradient colors."],
                            "angle": ["type": "number", "description": "Gradient angle in degrees, 0 = left→right, 90 = top→bottom. Default 135."],
                            "color": ["type": "string", "description": "For type color."],
                            "image": ["type": "string", "description": "For type image: path."],
                            "blur": ["type": "boolean", "description": "Blur wallpaper/image backgrounds."],
                            "padding": ["type": "number", "description": "Pixels around the screenshot. Default 8% of its short side."],
                            "inset": ["type": "number", "description": "Extra border inside the frame, filled with the screenshot's edge color (or inset_color)."],
                            "inset_color": ["type": "string"],
                            "shadow": ["type": "number", "description": "0-100, default 40."],
                            "corner_radius": ["type": "number", "description": "Pixels. Default scales with the image (~15px on a retina screenshot)."],
                            "ratio": ["type": "string", "description": "Canvas aspect ratio like '16:9', '4:3', '1:1'."],
                            "alignment": ["type": "string", "description": "center (default), top, bottom, left, right, top-left, top-right, bottom-left, bottom-right."],
                        ],
                    ],
                ],
            ],
        ],
        [
            "name": "ocr",
            "description": "Recognize text in an image. Returns each line with its bounding box in input pixels, so you can point annotations at it.",
            "inputSchema": [
                "type": "object",
                "required": ["input"],
                "properties": [
                    "input": ["type": "string"],
                    "region": rect,
                    "find": ["type": "string", "description": "Only return lines containing this text (case-insensitive)."],
                ],
            ],
        ],
        [
            "name": "find_sensitive",
            "description": "Check an image for sensitive text before sharing it: API keys and tokens, passwords, JWTs, private keys, emails, card numbers and phone numbers (and faces with faces: true). Returns each finding's kind, a masked preview and its box in input pixels; full values are never returned. compose covers them by default.",
            "inputSchema": [
                "type": "object",
                "required": ["input"],
                "properties": [
                    "input": ["type": "string"],
                    "faces": ["type": "boolean", "description": "Also report faces."],
                ],
            ],
        ],
        [
            "name": "find_shots",
            "description": "Search the screenshot library (~/Screenshots plus every file shot has written) without opening images. Each result has path, taken_at, app, window, description (when an agent or describer gave one), size and a text_excerpt of the screenshot's OCR text around the match. Ranked by how many query words match description, window, app, filename and text, then newest first. With no query, lists the newest. Screenshots not yet indexed are read on the way (newest first, within a time budget).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Words to look for, e.g. 'mux dashboard error'."],
                    "since": ["type": "string", "description": "Only screenshots taken after this: ISO date/time, or relative like '2h', '3d', '1w'."],
                    "until": ["type": "string", "description": "Only screenshots taken before this, same formats."],
                    "app": ["type": "string", "description": "Only screenshots of this app (substring, e.g. 'Chrome')."],
                    "limit": ["type": "number", "description": "Default 10."],
                ],
            ],
        ],
        [
            "name": "annotate",
            "description": "Save a description of a screenshot you have looked at, so find_shots can match it later without anyone opening the image. Write what a person would search for: the app or page, what state it is in, and anything notable (an error, a chart, a specific record). One or two sentences. Stored in the library index and in the PNG's own metadata.",
            "inputSchema": [
                "type": "object",
                "required": ["path", "description"],
                "properties": [
                    "path": ["type": "string", "description": "The screenshot's path."],
                    "description": ["type": "string"],
                ],
            ],
        ],
        [
            "name": "list_windows",
            "description": "List on-screen windows (front to back) with id, app, title and bounds in screen points. Pass all: true to include minimized windows, which capture can still grab.",
            "inputSchema": ["type": "object", "properties": ["all": ["type": "boolean", "description": "Include off-screen windows, such as minimized ones."]]],
        ],
    ]
}

enum Windows {
    struct Win {
        let id: Int, app: String, title: String, bounds: CGRect
        /// The title as a person would name the window, for the library.
        var label: String { Windows.label(title) }
        var info: Args { ["id": id, "app": app, "title": title, "bounds": ["x": bounds.minX, "y": bounds.minY, "width": bounds.width, "height": bounds.height]] }
    }

    /// Drops the status glyphs apps put before a title (Claude Code's spinner
    /// "◐ Shot mod", "✳ Task", Braille spinners), which change from one
    /// capture to the next and say nothing about the window.
    static func label(_ title: String) -> String {
        String(title.unicodeScalars.drop { s in
            s.properties.isWhitespace || s.properties.generalCategory == .otherSymbol || s.properties.generalCategory == .mathSymbol
        }).trimmingCharacters(in: .whitespaces)
    }

    static func list(all: Bool = false) -> [Win] {
        let opts: CGWindowListOption = all ? [.optionAll, .excludeDesktopElements] : [.optionOnScreenOnly, .excludeDesktopElements]
        let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [Args] ?? []
        return raw.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let id = w[kCGWindowNumber as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b), rect.width > 40, rect.height > 40 else { return nil }
            return Win(id: id, app: w[kCGWindowOwnerName as String] as? String ?? "",
                       title: w[kCGWindowName as String] as? String ?? "", bounds: rect)
        }
    }

    static func find(id: Int?, app: String?, title: String?) throws -> Win {
        let wins = list(all: id != nil)
        if let id {
            guard let w = wins.first(where: { $0.id == id }) else { throw ShotError("No window with id \(id)") }
            return w
        }
        // "GrokBot" finds "Grok Bot": people (and agents) say app names without
        // the space they're written with.
        let squash = { (s: String) in s.filter { !$0.isWhitespace } }
        let has = { (field: String, want: String?) in want.map { squash(field).localizedCaseInsensitiveContains(squash($0)) } ?? true }
        let matches = { (w: Win) in has(w.app, app) && has(w.title, title) }
        // Minimized windows aren't on screen, but screencapture still renders
        // their last frame, so look there only when nothing visible matches.
        let match = wins.first(where: matches) ?? list(all: true).first(where: matches)
        guard let match else {
            throw ShotError("No window matches app=\(app ?? "*") title=\(title ?? "*"). Use list_windows to see what's open.")
        }
        return match
    }
}
