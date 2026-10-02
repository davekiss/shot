import Foundation

/// Describes screenshots nobody has described, by having a small vision model
/// look at each one, so find_shots can match photos and other text-light images.
///
/// Runs inside the MCP server. Every Claude session starts its own shot server,
/// so only the one holding the describer lock works; when it exits another
/// takes over. SHOT_DESCRIBE picks the scope: off, new (screenshots taken after
/// the describer first ran; the default) or all.
enum Describer {
    static let grace: TimeInterval = 60     // let the capturing agent annotate first
    static let interval: TimeInterval = 60
    static let maxAttempts = 2

    static var mode: String {
        let m = ProcessInfo.processInfo.environment["SHOT_DESCRIBE"]?.lowercased() ?? "off"
        return ["off", "new", "all"].contains(m) ? m : "off"
    }

    static var sincePath: String { "\(Library.root)/.shot-describe-since" }
    static var attempts: [String: Int] = [:]

    static func start() {
        guard mode != "off" else { return }
        Thread.detachNewThread {
            let fd = open("\(Library.indexPath).describer.lock", O_CREAT | O_RDWR, 0o644)
            guard fd >= 0 else { return }
            // Wait our turn behind any other server's describer; hold the lock for life.
            while flock(fd, LOCK_EX | LOCK_NB) != 0 { Thread.sleep(forTimeInterval: interval) }
            while true {
                autoreleasepool { _ = try? runOnce() }
                Thread.sleep(forTimeInterval: interval)
            }
        }
    }

    /// The cut-off for `new`: written the first time a describer runs.
    static func since() -> Date {
        if let s = try? String(contentsOfFile: sincePath, encoding: .utf8), let t = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return Date(timeIntervalSince1970: t)
        }
        let now = Date()
        try? String(now.timeIntervalSince1970).write(toFile: sincePath, atomically: true, encoding: .utf8)
        return now
    }

    /// Screenshots still waiting for a description, newest first.
    static func pending() throws -> [Args] {
        let cutoff = mode == "all" ? Date.distantPast : since()
        let ripe = Date().addingTimeInterval(-grace).timeIntervalSince1970
        return try Library.withIndex { Array($0.values) }
            .filter { r in
                guard r["description"] == nil, let p = r["path"] as? String, (attempts[p] ?? 0) < maxAttempts,
                      let mtime = r["mtime"] as? Double, mtime < ripe else { return false }
                let taken = (r["taken_at"] as? String).flatMap(Library.parseDate) ?? .distantPast
                return taken >= cutoff
            }
            .sorted { ($0["mtime"] as? Double ?? 0) > ($1["mtime"] as? Double ?? 0) }
    }

    @discardableResult
    static func runOnce(limit: Int = 5) throws -> Int {
        try Library.sync(budget: 10)
        var done = 0
        for r in try pending().prefix(limit) {
            guard let path = r["path"] as? String else { continue }
            attempts[path, default: 0] += 1
            guard let text = describe(path, context: r) else { continue }
            _ = try? Library.describe(path: path, text, by: "haiku")
            done += 1
        }
        return done
    }

    // MARK: the model call

    static let system = """
        You describe screenshots for a search index that AI agents query instead of opening images. \
        Read the image file you are given. Reply with one or two plain sentences, at most 40 words, nothing else: \
        what app, site or kind of image it is; what is on screen (the page, document, conversation or scene); \
        and any specifics someone would search for, such as names, titles, error messages, numbers or states. \
        Lead with the most searchable thing. Do not guess at anything you cannot see, and do not start with "This is".
        """

    /// Runs `claude -p` on a small model with only the Read tool, isolated from the
    /// person's settings, hooks, plugins and MCP servers (this one included).
    static func describe(_ path: String, context r: Args) -> String? {
        guard let claude = claudePath() else { return nil }
        var hint = ""
        if let app = r["app"] as? String { hint += " It was captured from the app \(app)" }
        if let w = r["window"] as? String { hint += ", window titled \"\(w)\"" }
        if !hint.isEmpty { hint += "." }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.arguments = [
            "-p", "--model", "haiku",
            "--setting-sources", "", "--strict-mcp-config",
            "--tools", "Read", "--allowedTools", "Read",
            "--no-session-persistence", "--output-format", "json",
            "--system-prompt", system,
            "Describe the screenshot at \(path).\(hint)",
        ]
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDE_CODE_PLUGIN_DIRS")
        env["SHOT_DESCRIBE"] = "off"
        p.environment = env
        p.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()

        guard p.terminationStatus == 0,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? Args,
              obj["is_error"] as? Bool != true,
              let result = (obj["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !result.isEmpty, result.count < 600 else { return nil }
        return result
    }

    /// The MCP server inherits whatever PATH its host gave it, so look in the
    /// usual places too. SHOT_CLAUDE overrides.
    static func claudePath() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let p = env["SHOT_CLAUDE"], FileManager.default.isExecutableFile(atPath: p) { return p }
        let dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["\(NSHomeDirectory())/.local/bin", "\(NSHomeDirectory())/.claude/local", "/opt/homebrew/bin", "/usr/local/bin"]
        return dirs.map { "\($0)/claude" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
