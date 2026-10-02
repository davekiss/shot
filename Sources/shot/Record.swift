import AppKit
import AVFoundation
import CoreImage
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Picks the moments worth looking at from a stream of frames: the first one,
/// any frame where something visibly changed since the last moment kept, and
/// the last. An agent reads a dozen moments instead of watching a video.
struct Storyboard {
    struct Moment { let t: Double; let image: CGImage; let changes: [Diff.Region] }
    private(set) var moments: [Moment] = []
    private var lastKept: CGImage?
    private(set) var last: (t: Double, image: CGImage)?

    /// Considers one sampled frame at time `t` seconds.
    mutating func consider(_ img: CGImage, at t: Double) {
        last = (t, img)
        guard let prev = lastKept else {
            moments.append(Moment(t: t, image: img, changes: []))
            lastKept = img
            return
        }
        guard let rects = try? Diff.regions(prev, img), !rects.isEmpty else { return }
        moments.append(Moment(t: t, image: img, changes: Diff.describe(rects, prev, img)))
        lastKept = img
    }

    /// Adds the final frame if it isn't already the last moment.
    mutating func finish() {
        guard let last, let kept = moments.last, last.t > kept.t else { return }
        if let rects = try? Diff.regions(kept.image, last.image), !rects.isEmpty {
            moments.append(Moment(t: last.t, image: last.image, changes: Diff.describe(rects, kept.image, last.image)))
        }
    }

    /// At most `limit` moments, always keeping the first and last.
    func picked(_ limit: Int = 12) -> [Moment] {
        guard moments.count > limit else { return moments }
        let step = Double(moments.count - 1) / Double(limit - 1)
        return (0..<limit).map { moments[Int((Double($0) * step).rounded())] }
    }

    /// One image of the picked moments in a grid, each stamped with its time
    /// and with what changed since the previous moment boxed.
    static func sheet(_ moments: [Moment], unit: CGFloat) throws -> CGImage {
        guard let first = moments.first else { throw ShotError("nothing to put on a storyboard") }
        let cols = moments.count <= 4 ? 2 : 3
        let rows = (moments.count + cols - 1) / cols
        let thumbW = 900, thumbH = Int(Double(thumbW) * Double(first.image.height) / Double(first.image.width))
        let gap = 36, W = cols * thumbW + (cols + 1) * gap, H = rows * thumbH + (rows + 1) * gap
        guard let ctx = makeContext(W, H) else { throw ShotError("Couldn't create a drawing context") }
        ctx.setFillColor(CGColor(srgbRed: 0.07, green: 0.07, blue: 0.07, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        for (i, m) in moments.enumerated() {
            let boxes: [Args] = m.changes.map { c in
                let r = c.rect.insetBy(dx: -unit, dy: -unit)
                return ["type": "rect", "x": r.minX, "y": r.minY, "width": r.width, "height": r.height]
            }
            let stamp: Args = ["type": "text", "at": [unit * 2, unit * 2], "text": String(format: "%.1fs", m.t),
                               "background": true, "size": Double(m.image.width) / 40]
            let marked = try Annotator.apply(boxes + [stamp], to: m.image, offset: .zero, unit: unit)
            let col = i % cols, row = i / cols
            // Grid cells run top to bottom; the context's origin is bottom-left.
            let x = gap + col * (thumbW + gap), y = H - gap - (row + 1) * thumbH - row * gap
            ctx.interpolationQuality = .high
            ctx.draw(marked, in: CGRect(x: x, y: y, width: thumbW, height: thumbH))
        }
        guard let out = ctx.makeImage() else { throw ShotError("Couldn't render the storyboard") }
        return out
    }
}

/// Records a window, region or screen with ScreenCaptureKit (no focus change),
/// writing an MP4 and building a storyboard of the moments that changed.
final class Recorder: NSObject, SCStreamOutput {
    private let queue = DispatchQueue(label: "shot.record")
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var started = false
    private var firstPTS: CMTime?
    private var nextSample = 0.0
    private let sampleEvery: Double
    private let ci = CIContext()
    private var gif: CGImageDestination?
    private var gifEvery = 0.0, nextGif = 0.0
    // ScreenCaptureKit only sends frames when something changes, so a GIF
    // frame is held until the next one arrives and then given its real duration.
    private var pendingGif: (t: Double, image: CGImage)?
    private var lastSample: CMSampleBuffer?
    var storyboard = Storyboard()
    var latest: (t: Double, image: CGImage)?
    var frames = 0

    init(sampleEvery: Double) { self.sampleEvery = sampleEvery }

    func prepare(video url: URL, size: CGSize, fps: Int, gif gifURL: URL?) throws {
        try? FileManager.default.removeItem(at: url)
        let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width) / 2 * 2, AVVideoHeightKey: Int(size.height) / 2 * 2,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Int(size.width * size.height * 4), AVVideoExpectedSourceFrameRateKey: fps],
        ]
        let inp = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        inp.expectsMediaDataInRealTime = true
        w.add(inp)
        writer = w; input = inp
        if let gifURL {
            gif = CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString, 100_000, nil)
            CGImageDestinationSetProperties(gif!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            gifEvery = 1.0 / 8
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = sb.imageBuffer else { return }
        let pts = sb.presentationTimeStamp
        if !started, let writer {
            writer.startWriting()
            writer.startSession(atSourceTime: pts)
            firstPTS = pts
            started = true
        }
        if let input, input.isReadyForMoreMediaData { input.append(sb); lastSample = sb }
        frames += 1
        let t = (pts - (firstPTS ?? pts)).seconds
        if t >= nextSample || frames == 1, let img = ci.createCGImage(CIImage(cvPixelBuffer: pixels), from: CIImage(cvPixelBuffer: pixels).extent) {
            nextSample = t + sampleEvery
            storyboard.consider(img, at: t)
            latest = (t, img)
        }
        if let gif, t >= nextGif {
            nextGif = t + gifEvery
            let src = CIImage(cvPixelBuffer: pixels)
            let scale = min(1, 960 / src.extent.width)
            if let small = ci.createCGImage(src.transformed(by: CGAffineTransform(scaleX: scale, y: scale)), from: src.extent.applying(CGAffineTransform(scaleX: scale, y: scale))) {
                if let p = pendingGif { addGifFrame(p.image, lasting: t - p.t, to: gif) }
                pendingGif = (t, small)
            }
        }
    }

    /// `elapsed` is how long recording ran. The screen may have sat still at
    /// the end, sending no frames, so the video and GIF are held to that time.
    func finish(elapsed: Double) {
        let done = DispatchSemaphore(value: 0)
        if !started { input?.markAsFinished() }
        if let writer, started, let firstPTS {
            let end = firstPTS + CMTime(seconds: elapsed, preferredTimescale: 600)
            // Repeat the last frame at the end time so a still ending keeps its length.
            if let last = lastSample, end > last.presentationTimeStamp, let input, input.isReadyForMoreMediaData {
                var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: end, decodeTimeStamp: .invalid)
                var copy: CMSampleBuffer?
                if CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: last, sampleTimingEntryCount: 1,
                                                         sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr, let copy {
                    input.append(copy)
                }
            }
            input?.markAsFinished()
            writer.endSession(atSourceTime: end)
            writer.finishWriting { done.signal() }
            done.wait()
        }
        if let gif {
            if let p = pendingGif { addGifFrame(p.image, lasting: max(gifEvery, elapsed - p.t), to: gif) }
            CGImageDestinationFinalize(gif)
        }
        storyboard.finish()
    }

    func onQueue() -> DispatchQueue { queue }


    private func addGifFrame(_ img: CGImage, lasting seconds: Double, to gif: CGImageDestination) {
        CGImageDestinationAddImage(gif, img, [kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: max(0.02, seconds), kCGImagePropertyGIFUnclampedDelayTime: max(0.02, seconds)]] as CFDictionary)
    }
}

enum Record {
    static func run(_ a: Args) throws -> ToolResult {
        let seconds = min(max(num(a, "seconds") ?? 10, 1), 60)
        let until = try Wait.condition(a["until"])
        let fps = Int(min(max(num(a, "fps") ?? 30, 5), 60))
        let stamp = timestampedPath("Recording").replacingOccurrences(of: ".png", with: "")
        let base = (a["output"] as? String).map { expand($0).replacingOccurrences(of: ".mp4", with: "") } ?? stamp
        try FileManager.default.createDirectory(atPath: (base as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let videoURL = URL(fileURLWithPath: base + ".mp4")
        let gifURL = flag(a, "gif") ? URL(fileURLWithPath: base + ".gif") : nil

        // What to record, and its size in pixels.
        let content = try wait { done in SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false, completionHandler: done) }
        let filter: SCContentFilter
        let config = SCStreamConfiguration()
        var info: Args = [:]
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let onWindow = a["app"] != nil || a["title"] != nil || a["window_id"] != nil
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw ShotError("No display to record")
        }
        if onWindow {
            let w = try Windows.find(id: num(a, "window_id").map { Int($0) }, app: a["app"] as? String, title: a["title"] as? String)
            guard let sw = content.windows.first(where: { Int($0.windowID) == w.id }) else { throw ShotError("ScreenCaptureKit can't see window \(w.id)") }
            filter = SCContentFilter(desktopIndependentWindow: sw)
            config.width = Int(sw.frame.width * scale); config.height = Int(sw.frame.height * scale)
            info["window"] = w.info
        } else if let r = box(a["region"]) {
            // A region of the screen includes everything drawn there, overlays included.
            filter = SCContentFilter(display: display, excludingWindows: [])
            config.sourceRect = r
            config.width = Int(r.width * scale); config.height = Int(r.height * scale)
        } else {
            filter = SCContentFilter(display: display, excludingWindows: [])
            config.width = Int(CGFloat(display.width) * scale); config.height = Int(CGFloat(display.height) * scale)
        }
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = !flag(a, "hide_cursor")
        config.queueDepth = 6

        let recorder = Recorder(sampleEvery: 0.25)
        try recorder.prepare(video: videoURL, size: CGSize(width: config.width, height: config.height), fps: fps, gif: gifURL)
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.onQueue())
        try wait { (done: @escaping (Error?) -> Void) in stream.startCapture(completionHandler: done) }
        let began = Date()

        // Record for `seconds`, or until the condition holds (checked twice a second).
        let start = Date()
        var met = false, steadySince: Date?, lastChecked: CGImage?
        while Date().timeIntervalSince(start) < seconds {
            Thread.sleep(forTimeInterval: 0.5)
            guard let cond = until, let frame = recorder.onQueue().sync(execute: { recorder.latest?.image }) else { continue }
            if case .stable(let s) = cond {
                let same = lastChecked.map { (try? Diff.regions($0, frame))?.isEmpty ?? false } ?? false
                steadySince = same ? (steadySince ?? Date()) : nil
                met = steadySince.map { Date().timeIntervalSince($0) >= s } ?? false
                lastChecked = frame
            } else {
                met = Wait.met(cond, frame)
            }
            if met { Thread.sleep(forTimeInterval: 0.6); break }   // a beat after, so the moment is on film
        }
        try wait { (done: @escaping (Error?) -> Void) in stream.stopCapture(completionHandler: done) }
        let elapsed = Date().timeIntervalSince(began)
        recorder.onQueue().sync { recorder.finish(elapsed: elapsed) }
        guard recorder.frames > 0 else {
            throw ShotError("No frames were recorded. Minimized windows don't draw; check Screen Recording permission for the app running your agent.")
        }

        // The storyboard: the moments that changed, as a list and as one image.
        let moments = recorder.storyboard.picked(12)
        let unit = Annotator.markUnit(moments[0].image, textHeight: nil)
        let sheet = try Storyboard.sheet(moments, unit: unit)
        let sheetPath = base + " storyboard.png"
        try writePNG(sheet, to: sheetPath)
        let framesDir = base + " frames"
        try FileManager.default.createDirectory(atPath: framesDir, withIntermediateDirectories: true)
        let list: [Args] = try moments.enumerated().map { i, m in
            let path = "\(framesDir)/\(String(format: "%02d", i + 1))-\(String(format: "%.1f", m.t))s.png"
            try writePNG(m.image, to: path)
            var entry: Args = ["t": NSDecimalNumber(string: String(format: "%.1f", m.t)), "frame": path]
            let changes: [Args] = m.changes.map { c in
                var r: Args = ["box": [Int(c.rect.minX), Int(c.rect.minY), Int(c.rect.width), Int(c.rect.height)]]
                if c.before != c.after { r["text_before"] = c.before; r["text_after"] = c.after }
                return r
            }
            if !changes.isEmpty { entry["changes"] = changes }
            return entry
        }
        Library.add(try Library.record(path: sheetPath, img: sheet, window: nil))

        info["video"] = videoURL.path
        if let gifURL { info["gif"] = gifURL.path }
        info["storyboard"] = sheetPath
        info["duration"] = NSDecimalNumber(string: String(format: "%.1f", elapsed))
        info["moments"] = list
        if recorder.storyboard.moments.count > moments.count {
            info["note"] = "\(recorder.storyboard.moments.count) moments changed; the storyboard shows \(moments.count) of them, evenly spread."
        }
        if let until { info["until_met"] = met; if !met { info["until_note"] = "Stopped at \(Int(seconds))s without the condition being met." }; _ = until }
        return ToolResult(info: info, image: flag(a, "preview", true) ? sheet : nil)
    }

    /// Blocks on a completion-handler API. ScreenCaptureKit calls back on its
    /// own queues, so waiting here doesn't deadlock the MCP loop.
    static func wait<T>(_ call: (@escaping (T?, Error?) -> Void) -> Void) throws -> T {
        let done = DispatchSemaphore(value: 0)
        var value: T?, failure: Error?
        call { v, e in value = v; failure = e; done.signal() }
        done.wait()
        if let failure { throw ShotError("Screen recording failed: \(failure.localizedDescription)") }
        guard let value else { throw ShotError("Screen recording returned nothing") }
        return value
    }

    static func wait(_ call: (@escaping (Error?) -> Void) -> Void) throws {
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        call { e in failure = e; done.signal() }
        done.wait()
        if let failure { throw ShotError("Screen recording failed: \(failure.localizedDescription)") }
    }
}
