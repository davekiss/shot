import AppKit
import CoreText

/// Type styles for labels and counters, picked like text styles in a photo
/// app: `pixel` is shot's own voice, the rest trade character for plain
/// readability. Any installed font name works too.
enum Fonts {
    static let styles = ["pixel", "clean", "rounded", "serif", "mono"]

    /// The default style: SHOT_FONT if set, else pixel.
    static var defaultStyle: String {
        let s = ProcessInfo.processInfo.environment["SHOT_FONT"]?.trimmingCharacters(in: .whitespaces) ?? ""
        return s.isEmpty ? "pixel" : s
    }

    private static let pixelDescriptor: CTFontDescriptor? = {
        guard let data = Data(base64Encoded: departureMonoOTF) else { return nil }
        return CTFontManagerCreateFontDescriptorFromData(data as CFData)
    }()

    static func font(_ style: String?, size: CGFloat, bold: Bool) -> NSFont {
        let weight: NSFont.Weight = bold ? .bold : .medium
        func system(_ design: NSFontDescriptor.SystemDesign) -> NSFont {
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            return base.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        }
        switch (style ?? defaultStyle).lowercased() {
        case "pixel":
            // Departure Mono is drawn on an 11px grid; whole multiples keep its edges crisp.
            let snapped = size >= 11 ? (size / 11).rounded() * 11 : size
            if let d = pixelDescriptor { return CTFontCreateWithFontDescriptor(d, snapped, nil) as NSFont }
            return system(.monospaced)
        case "clean": return NSFont.systemFont(ofSize: size, weight: weight)
        case "rounded": return system(.rounded)
        case "serif": return system(.serif)
        case "mono": return system(.monospaced)
        case let name: return NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
        }
    }

    /// Tracking that suits the face: pixel and mono type is spaced by its grid.
    static func kern(_ font: NSFont) -> CGFloat {
        font.isFixedPitch ? 0 : font.pointSize * -0.01
    }
}
