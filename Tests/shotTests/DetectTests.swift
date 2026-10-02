import AppKit
import XCTest
@testable import shot

/// Draws lines of text the way a terminal or editor would show them, and
/// returns the image plus where each line was drawn (top-left origin, pixels).
func render(_ lines: [String], size: CGFloat = 30, width: Int = 1600, mono: Bool = true,
            at positions: [CGPoint]? = nil, height: Int? = nil) -> CGImage {
    let H = height ?? (60 + lines.count * Int(size * 1.9))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: width, height: H).fill()
    let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
    for (i, l) in lines.enumerated() {
        let p = positions?[i] ?? CGPoint(x: 30, y: 30 + CGFloat(i) * size * 1.9)
        // AppKit draws bottom-up; flip the top-left position.
        (l as NSString).draw(at: NSPoint(x: p.x, y: CGFloat(H) - p.y - size * 1.2), withAttributes: attrs)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage!
}

final class SensitiveTests: XCTestCase {
    // Fake values shaped like the real thing.
    let env = [
        "ANTHROPIC_API_KEY=sk-ant-api03-Xq7Lm2Pz9Rt4Vb8Nc1Kd6Hf3",
        "GITHUB_TOKEN=ghp_8fKz2LqP9xR4tV7bN1mC5dH3jW6yA0sE",
        "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE",
        "DB_PASSWORD=hunter2hunter2",
        "Contact: jane.doe@example.com",
        "Card on file: 4242 4242 4242 4242",
        "Docs: /Users/someone/code/shot/Sources/shot/Tools.swift",
        "Order #1234567890123 shipped Oct 2",
    ]

    lazy var findings = Sensitive.scan(render(env))

    func testFindsEachSecretOnItsOwnLine() {
        let secrets = findings.filter { $0.kind == "secret" }
        for prefix in ["sk-ant", "ghp_", "AKIA", "hunter2"] {
            XCTAssertTrue(secrets.contains { $0.text.hasPrefix(prefix) }, "missed the secret starting \(prefix): \(secrets.map(\.text))")
        }
        XCTAssertTrue(findings.contains { $0.kind == "email" })
        XCTAssertTrue(findings.contains { $0.kind == "card" })
    }

    func testLeavesPathsAndOrderNumbersAlone() {
        XCTAssertFalse(findings.contains { $0.text.contains("Tools.swift") || $0.text.contains("Sources") }, "\(findings.map(\.text))")
        XCTAssertFalse(findings.contains { $0.text.contains("1234567890123") }, "\(findings.map { ($0.kind, $0.text) })")
    }

    func testCoversTheValueButNotTheVariableName() throws {
        let img = render(env)
        let label = try XCTUnwrap(OCRText(img, correct: false).find("GITHUB_TOKEN").first)
        let key = try XCTUnwrap(findings.first { $0.text.hasPrefix("ghp_") })
        XCTAssertGreaterThan(key.rect.minX, label.rect.minX + label.rect.width * 0.8, "redaction starts inside GITHUB_TOKEN")
    }

    func testCoversASecretToTheEndOfTheWordEvenWhenTheMatchStopsEarly() throws {
        // "$" isn't a key character, so the pattern match ends there; the
        // characters after it must still be covered.
        let img = render(["TOKEN=ghp_8fKz2LqP9xR4tV7bN1m$C5dH3jW6yA0sE"])
        let key = try XCTUnwrap(Sensitive.scan(img).first { $0.text.hasPrefix("ghp_") })
        XCTAssertTrue(key.text.hasSuffix("A0sE"), "covered only \(key.text)")
    }

    func testResultsNeverCarryTheFullValue() {
        for f in findings where f.text.count > 8 {
            let info = Sensitive.info(f)
            XCTAssertFalse(String(describing: info).contains(f.text), "\(f.kind) leaked in \(info)")
        }
    }

    func testCoversThePasswordInAConnectionURL() throws {
        let img = render(["DATABASE_URL=postgres://app:hunter2hunter2@db:5432/acme"])
        let f = try XCTUnwrap(Sensitive.scan(img).first { $0.kind == "secret" })
        XCTAssertEqual(f.text, "hunter2hunter2")
    }

    func testCoversPhoneNumbersByDefault() {
        let img = render(["Call (555) 867-5309 or +1 555.123.4567 today"])
        XCTAssertEqual(Sensitive.scan(img).filter { $0.kind == "phone" }.count, 2)
    }

    func testLuhn() {
        XCTAssertTrue(Sensitive.luhn("4242 4242 4242 4242"))
        XCTAssertFalse(Sensitive.luhn("4242 4242 4242 4241"))
        XCTAssertFalse(Sensitive.luhn("4242"))
    }

    func testRandomLookingStrings() {
        XCTAssertTrue(Sensitive.looksRandom("Zx9Qw3Er7Ty1Ui5Op2As8Df4Gh6Jk0Lz"))
        XCTAssertFalse(Sensitive.looksRandom("/Users/someone/code/shot/Sources/Tools"))
        XCTAssertFalse(Sensitive.looksRandom("CamelCaseIdentifierName2"))
    }
}

final class TargetTests: XCTestCase {
    func testCounterLandsOnTheNamedText() throws {
        let img = render(["Save", "Cancel"], size: 40, width: 1200, mono: false,
                         at: [CGPoint(x: 100, y: 100), CGPoint(x: 700, y: 400)], height: 800)
        var found: [Args] = []
        let out = try Targets.resolve([["type": "counter", "target": "Cancel"]], ocr: OCRText(img), unit: 5, found: &found)
        let at = try XCTUnwrap(point(out[0]["at"]))
        XCTAssertEqual(at.x, 700, accuracy: 30)
        XCTAssertEqual(at.y, 400, accuracy: 40)
        XCTAssertEqual(found.first?["matched"] as? String, "Cancel")
    }

    func testCoordinatesTheCallerGaveWin() throws {
        let img = render(["Save"], size: 40, width: 800, mono: false)
        var found: [Args] = []
        let out = try Targets.resolve([["type": "counter", "target": "Save", "at": [5, 5]]], ocr: OCRText(img), unit: 5, found: &found)
        XCTAssertEqual(point(out[0]["at"]), CGPoint(x: 5, y: 5))
    }

    func testPrefersAnExactLineOverAMention() throws {
        let img = render(["Save your work before you go", "Save"], size: 36, width: 1200, mono: false)
        var found: [Args] = []
        _ = try Targets.resolve([["type": "rect", "target": "Save"]], ocr: OCRText(img), unit: 5, found: &found)
        XCTAssertEqual(found.first?["matched"] as? String, "Save")
    }

    func testMissingTextListsWhatIsThere() {
        let img = render(["Save", "Cancel"], size: 40, width: 800, mono: false)
        var found: [Args] = []
        XCTAssertThrowsError(try Targets.resolve([["type": "rect", "target": "Delete"]], ocr: OCRText(img), unit: 5, found: &found)) { e in
            let msg = (e as? ShotError).map { "\($0)" } ?? "\(e)"
            XCTAssertTrue(msg.contains("Cancel"), msg)
        }
    }

    func testArrowStaysClearOfOtherText() throws {
        // A paragraph directly under the target and to its left: the arrow
        // should come from the open right side, not through the paragraph.
        let lines = ["Target", "lorem ipsum dolor sit amet consectetur", "adipiscing elit sed do eiusmod tempor", "incididunt ut labore et dolore magna"]
        let img = render(lines, size: 32, width: 1400, mono: false,
                         at: [CGPoint(x: 600, y: 300), CGPoint(x: 100, y: 380), CGPoint(x: 100, y: 440), CGPoint(x: 100, y: 500)], height: 900)
        let ocr = OCRText(img)
        var found: [Args] = []
        let out = try Targets.resolve([["type": "arrow", "target": "Target"]], ocr: ocr, unit: 6, found: &found)
        let from = try XCTUnwrap(point(out[0]["from"])), to = try XCTUnwrap(point(out[0]["to"]))
        let others = ocr.observations.map { ocr.rect($0) }.filter { !$0.contains(CGPoint(x: 650, y: 320)) }
        for k in 1...10 {
            let f = CGFloat(k) / 10
            let p = CGPoint(x: to.x + (from.x - to.x) * f, y: to.y + (from.y - to.y) * f)
            XCTAssertFalse(others.contains { $0.contains(p) }, "arrow crosses text at \(p)")
        }
    }
}
