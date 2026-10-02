import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct ShotError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

typealias Args = [String: Any]

// MARK: - Argument parsing

func num(_ a: Args, _ key: String) -> Double? {
    if let n = a[key] as? NSNumber { return n.doubleValue }
    if let s = a[key] as? String { return Double(s) }
    return nil
}

func flag(_ a: Args, _ key: String, _ fallback: Bool = false) -> Bool {
    if let n = a[key] as? NSNumber { return n.boolValue }
    return fallback
}

func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

/// Accepts [x, y] or {"x": .., "y": ..}.
func point(_ v: Any?) -> CGPoint? {
    if let arr = v as? [NSNumber], arr.count == 2 {
        return CGPoint(x: arr[0].doubleValue, y: arr[1].doubleValue)
    }
    if let d = v as? Args, let x = num(d, "x"), let y = num(d, "y") {
        return CGPoint(x: x, y: y)
    }
    return nil
}

/// Reads x, y, width, height from a dictionary (top-left origin).
func box(_ v: Any?) -> CGRect? {
    guard let d = v as? Args, let x = num(d, "x"), let y = num(d, "y"),
          let w = num(d, "width") ?? num(d, "w"), let h = num(d, "height") ?? num(d, "h") else { return nil }
    return CGRect(x: x, y: y, width: w, height: h).standardized
}

func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }

// MARK: - Colors

let defaultColor = "#7C5CFF"

private let namedColors: [String: String] = [
    "red": "#FF3B30", "orange": "#FF9500", "yellow": "#FFCC00", "green": "#34C759",
    "blue": "#007AFF", "purple": "#7C5CFF", "pink": "#FF2D55", "white": "#FFFFFF",
    "black": "#000000", "gray": "#8E8E93", "grey": "#8E8E93",
]

private func parseHex(_ raw: String) -> CGColor? {
    var s = raw.trimmingCharacters(in: .whitespaces).lowercased()
    if let named = namedColors[s] { s = named }
    if s.hasPrefix("#") { s.removeFirst() }
    if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
    if s.count == 6 { s += "ff" }
    guard s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
    return CGColor(
        srgbRed: CGFloat((v >> 24) & 0xff) / 255, green: CGFloat((v >> 16) & 0xff) / 255,
        blue: CGFloat((v >> 8) & 0xff) / 255, alpha: CGFloat(v & 0xff) / 255)
}

/// Parses "#RGB", "#RRGGBB", "#RRGGBBAA" or a color name, falling back to `fallback`.
func color(_ v: Any?, _ fallback: String) -> CGColor {
    if let s = v as? String, let c = parseHex(s) { return c }
    return parseHex(fallback) ?? CGColor(gray: 0, alpha: 1)
}

// MARK: - Images

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgbSpace(_ img: CGImage) -> CGColorSpace {
    if let cs = img.colorSpace, cs.model == .rgb { return cs }
    return sRGB
}

func makeContext(_ w: Int, _ h: Int, space: CGColorSpace = sRGB) -> CGContext? {
    let make = { (cs: CGColorSpace) in
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
    return make(space) ?? make(sRGB)
}

func loadImage(_ path: String) throws -> CGImage {
    let url = URL(fileURLWithPath: expand(path))
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        throw ShotError("Can't read an image at \(path)")
    }
    return img
}

func encode(_ img: CGImage, as type: UTType, quality: Double? = nil) -> Data? {
    let data = NSMutableData()
    guard let dst = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
    var props: [CFString: Any] = [:]
    if let quality { props[kCGImageDestinationLossyCompressionQuality] = quality }
    CGImageDestinationAddImage(dst, img, props as CFDictionary)
    return CGImageDestinationFinalize(dst) ? data as Data : nil
}

func writePNG(_ img: CGImage, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let data = encode(img, as: .png) else { throw ShotError("Couldn't encode PNG") }
    try data.write(to: url)
}

func copyToClipboard(_ img: CGImage) {
    guard let data = encode(img, as: .png) else { return }
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setData(data, forType: .png)
}

/// Downscaled JPEG for returning to the model, plus the scale relative to the full image.
func preview(_ img: CGImage, maxEdge: Int = 1568) -> (Data, Double)? {
    let scale = min(1, Double(maxEdge) / Double(max(img.width, img.height)))
    let w = max(1, Int(Double(img.width) * scale)), h = max(1, Int(Double(img.height) * scale))
    guard let ctx = makeContext(w, h) else { return nil }
    ctx.interpolationQuality = .high
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let small = ctx.makeImage(), let data = encode(small, as: .jpeg, quality: 0.82) else { return nil }
    return (data, Double(w) / Double(img.width))
}

/// Color of a single pixel (top-left origin).
func pixelColor(_ img: CGImage, x: Int = 0, y: Int = 0) -> CGColor {
    guard let one = img.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
          let ctx = makeContext(1, 1), let data = ctx.data else { return CGColor(gray: 1, alpha: 1) }
    ctx.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let p = data.bindMemory(to: UInt8.self, capacity: 4)
    return CGColor(srgbRed: CGFloat(p[0]) / 255, green: CGFloat(p[1]) / 255, blue: CGFloat(p[2]) / 255, alpha: 1)
}

// MARK: - Paths

func uniquePath(_ path: String) -> String {
    let fm = FileManager.default
    guard fm.fileExists(atPath: path) else { return path }
    let base = (path as NSString).deletingPathExtension, ext = (path as NSString).pathExtension
    var i = 2
    while fm.fileExists(atPath: "\(base) \(i).\(ext)") { i += 1 }
    return "\(base) \(i).\(ext)"
}

func timestampedPath(_ prefix: String) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
    return uniquePath("\(NSHomeDirectory())/Screenshots/\(prefix) \(f.string(from: Date())).png")
}

func editedPath(for input: String) -> String {
    let base = (expand(input) as NSString).deletingPathExtension
    return uniquePath("\(base) edited.png")
}

func run(_ exe: String, _ args: [String]) throws -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    return (p.terminationStatus, out)
}
