import AppKit
import QuartzCore

/// Marks drawn on the live screen: shot looks at the window, places the marks
/// with the same targeting as compose, and a short-lived helper process shows
/// them in a click-through panel above the window, then fades out and exits.
enum Overlay {
    static let allowed: Set<String> = ["arrow", "line", "rect", "rectangle", "ellipse", "circle", "text", "counter", "highlight", "spotlight"]

    static func point(_ a: Args) throws -> ToolResult {
        guard var anns = a["annotations"] as? [Args], !anns.isEmpty else { throw ShotError("point needs annotations") }
        if let bad = anns.first(where: { !allowed.contains($0["type"] as? String ?? "") }) {
            throw ShotError("point can't show '\(bad["type"] ?? "")'; use arrow, rect, ellipse, line, text, counter, highlight or spotlight")
        }
        for key in ["font", "style"] {
            if let v = a[key] as? String { anns = anns.map { var m = $0; if m[key] == nil { m[key] = v }; return m } }
        }
        let seconds = min(max(num(a, "seconds") ?? 4, 1), 15)

        // Look at what's on screen right now, without adding to the library.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shot-point", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = UUID().uuidString
        let lookPath = dir.appendingPathComponent("look-\(stamp).png").path
        let onWindow = a["app"] != nil || a["title"] != nil || a["window_id"] != nil
        var look: Args = ["output": lookPath, "preview": false, "_scratch": true, "mode": onWindow ? "window" : "screen"]
        for k in ["app", "title", "window_id"] { look[k] = a[k] }
        let seen = try Tools.capture(look)
        let img = try loadImage(lookPath)

        // Where that picture sits on screen, in points with a top-left origin.
        let frame: CGRect
        if let w = (seen.info["window"] as? Args)?["bounds"] as? Args, let r = box(w) {
            frame = r
        } else {
            frame = CGDisplayBounds(CGMainDisplayID())
        }

        let ocr = OCRText(img)
        let unit = Annotator.markUnit(img, textHeight: ocr.textHeight)
        var found: [Args] = []
        let resolved = try Targets.resolve(anns, ocr: ocr, unit: unit, found: &found)
        let marks = try Annotator.apply(resolved, to: img, offset: .zero, unit: unit, overlay: true)
        let markPath = dir.appendingPathComponent("marks-\(stamp).png").path
        try writePNG(marks, to: markPath)
        try? FileManager.default.removeItem(atPath: lookPath)

        // A separate process owns the panel, so this call returns right away.
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let job: Args = ["image": markPath, "x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height, "seconds": seconds]
        helper.arguments = ["_overlay", String(data: try JSONSerialization.data(withJSONObject: job), encoding: .utf8) ?? "{}"]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()

        var info: Args = ["shown": resolved.count, "seconds": seconds,
                          "on": onWindow ? (seen.info["window"] ?? "window") : "main screen"]
        // The panel floats above everything, so on a covered window the marks
        // would sit on whatever covers it. Say so; moving windows isn't ours to do.
        if let id = (seen.info["window"] as? Args)?["id"] as? Int {
            let front = Windows.list().prefix { $0.id != id }.filter { $0.bounds.intersects(frame) && $0.app != "Window Server" }
            if !front.isEmpty {
                info["note"] = "The window is partly covered by \(front.map { $0.app }.joined(separator: ", ")); the marks show on top of whatever is in front. Ask the user to bring it forward if that matters."
            }
        }
        if !found.isEmpty { info["targets"] = found }
        return ToolResult(info: info)
    }

    /// Runs in the helper process: shows the marks over `frame`, fades them, exits.
    static func show(_ a: Args) -> Never {
        guard let path = a["image"] as? String, let image = NSImage(contentsOfFile: path),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), let r = box(a) else { exit(1) }
        let seconds = num(a, "seconds") ?? 4
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // AppKit measures from the bottom of the primary screen; CG from its top.
        let primary = NSScreen.screens.first?.frame.height ?? r.maxY
        let frame = NSRect(x: r.minX, y: primary - r.maxY, width: r.width, height: r.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.contents = cg
        view.layer?.contentsGravity = .resize
        panel.contentView = view
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.45; panel.animator().alphaValue = 0 }) {
                try? FileManager.default.removeItem(atPath: path)
                exit(0)
            }
        }
        app.run()
        exit(0)
    }
}
