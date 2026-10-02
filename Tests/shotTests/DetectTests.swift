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

    func testWholeWordsBeatFragments() throws {
        let img = render(["SUPPORT_EMAIL=help", "PORT=3000"], size: 36, width: 1000)
        var found: [Args] = []
        _ = try Targets.resolve([["type": "ellipse", "target": "PORT"]], ocr: OCRText(img), unit: 5, found: &found)
        let matched = try XCTUnwrap(found.first?["matched"] as? String)
        XCTAssertTrue(matched.hasPrefix("PORT") && !matched.contains("SUPPORT"), matched)
    }

    func testMarksOnAdjacentLinesDontTouch() throws {
        // Tightly set terminal lines: a box on one and a circle on the next
        // must not run into each other or into the line between.
        let img = render(["ONCALL_PHONE=(555) 867-5309", "LOG_LEVEL=debug", "PORT=3000"], size: 32, width: 1200)
        let ocr = OCRText(img)
        var found: [Args] = []
        let out = try Targets.resolve([["type": "rect", "target": "LOG_LEVEL"], ["type": "ellipse", "target": "PORT"]],
                                      ocr: ocr, unit: 9, found: &found)
        let rect = try XCTUnwrap(box(out[0])), ellipse = try XCTUnwrap(box(out[1]))
        let phone = try XCTUnwrap(ocr.find("ONCALL").first).line
        XCTAssertFalse(rect.intersects(ellipse), "box \(rect) runs into circle \(ellipse)")
        XCTAssertFalse(rect.intersects(phone), "box \(rect) swallows the line above \(phone)")
    }

    func testLabelsStayInsideTheCrop() throws {
        let img = render(["Read the docs"], size: 40, width: 1400, mono: false, at: [CGPoint(x: 500, y: 600)], height: 1000)
        let ocr = OCRText(img)
        let visible = try XCTUnwrap(ocr.find("Read the docs").first).line.insetBy(dx: -300, dy: -40)
        var found: [Args] = []
        let out = try Targets.resolve([["type": "text", "target": "Read the docs", "text": "Start here", "background": true]],
                                      ocr: ocr, unit: 6, visible: visible, found: &found)
        let at = try XCTUnwrap(point(out[0]["at"])), (w, h) = Targets.labelSize(out[0], 6)
        XCTAssertTrue(visible.contains(CGRect(x: at.x, y: at.y, width: w, height: h)), "label falls outside the crop")
    }

    func testMissingTextListsWhatIsThere() {
        let img = render(["Save", "Cancel"], size: 40, width: 800, mono: false)
        var found: [Args] = []
        XCTAssertThrowsError(try Targets.resolve([["type": "rect", "target": "Delete"]], ocr: OCRText(img), unit: 5, found: &found)) { e in
            let msg = (e as? ShotError).map { "\($0)" } ?? "\(e)"
            XCTAssertTrue(msg.contains("Cancel"), msg)
        }
    }

    func testCounterSitsBesideTheTextNotOnIt() throws {
        let img = render(["Pricing"], size: 40, width: 1000, mono: false, at: [CGPoint(x: 500, y: 200)], height: 500)
        let ocr = OCRText(img)
        let text = try XCTUnwrap(ocr.find("Pricing").first).rect
        var found: [Args] = []
        let out = try Targets.resolve([["type": "counter", "target": "Pricing"]], ocr: ocr, unit: 6, found: &found)
        let at = try XCTUnwrap(point(out[0]["at"]))
        XCTAssertLessThanOrEqual(at.x + Annotator.counterRadius(6), text.minX, "counter overlaps the text")
        XCTAssertEqual(at.y, text.midY, accuracy: 4)
    }

    func testCounterMovesAboveWhenTheLeftIsTaken() throws {
        // "Developers" sits right where the counter for "Pricing" would go.
        let img = render(["Developers", "Pricing"], size: 40, width: 1200, mono: false,
                         at: [CGPoint(x: 300, y: 300), CGPoint(x: 540, y: 300)], height: 700)
        let ocr = OCRText(img)
        let developers = try XCTUnwrap(ocr.find("Developers").first).rect
        var found: [Args] = []
        let out = try Targets.resolve([["type": "counter", "target": "Pricing"]], ocr: ocr, unit: 6, found: &found)
        let at = try XCTUnwrap(point(out[0]["at"])), r = Annotator.counterRadius(6)
        XCTAssertFalse(CGRect(x: at.x - r, y: at.y - r, width: r * 2, height: r * 2).intersects(developers), "counter covers Developers")
    }

    func testLabelAndArrowOnTheSameTargetMakeACallout() throws {
        let img = render(["Read the docs"], size: 40, width: 1400, mono: false, at: [CGPoint(x: 600, y: 400)], height: 900)
        var found: [Args] = []
        let out = try Targets.resolve([
            ["type": "arrow", "target": "Read the docs"],
            ["type": "text", "target": "Read the docs", "text": "Start here", "background": true],
        ], ocr: OCRText(img), unit: 6, found: &found)
        let tail = try XCTUnwrap(point(out[0]["from"])), at = try XCTUnwrap(point(out[1]["at"]))
        // The arrow's tail should touch the label's pill (within a few px), wherever it lands.
        let (w, h) = Targets.labelSize(["text": "Start here", "background": true], 6)
        let pill = CGRect(x: at.x, y: at.y, width: w, height: h)
        let dx = max(pill.minX - tail.x, 0, tail.x - pill.maxX), dy = max(pill.minY - tail.y, 0, tail.y - pill.maxY)
        XCTAssertLessThan(hypot(dx, dy), 6, "label \(pill) doesn't meet the arrow tail \(tail)")
    }

    func testCropKeepsTheWholeLine() throws {
        let line = "Stream it, moderate it, search it, analyze it"
        let img = render([line], size: 36, width: 1600, mono: false, at: [CGPoint(x: 200, y: 300)], height: 700)
        let ocr = OCRText(img)
        let whole = try XCTUnwrap(ocr.find(line).first).rect
        let r = try Targets.crop(["target": "moderate it", "pad": 10], ocr: ocr, unit: 6)
        XCTAssertLessThanOrEqual(r.minX, whole.minX)
        XCTAssertGreaterThanOrEqual(r.maxX, whole.maxX)
    }

    func testCropFramesEveryListedLine() throws {
        let img = render(["First line of copy", "Second line of copy"], size: 36, width: 1200, mono: false,
                         at: [CGPoint(x: 200, y: 200), CGPoint(x: 200, y: 400)], height: 700)
        let ocr = OCRText(img)
        let second = try XCTUnwrap(ocr.find("Second line").first).line
        let r = try Targets.crop(["target": ["First line", "Second line"], "pad": 10], ocr: ocr, unit: 6)
        XCTAssertTrue(r.contains(second), "crop \(r) misses the second line \(second)")
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

final class FontTests: XCTestCase {
    func testPixelIsTheEmbeddedDepartureMono() {
        XCTAssertTrue(Fonts.font("pixel", size: 22, bold: true).fontName.contains("Departure"))
    }

    func testPixelSnapsToItsGrid() {
        XCTAssertEqual(Fonts.font("pixel", size: 30, bold: false).pointSize, 33)
    }

    func testUnknownFontFallsBackToTheSystemFace() {
        let f = Fonts.font("No Such Font 123", size: 20, bold: false)
        XCTAssertEqual(f.pointSize, 20)
        XCTAssertFalse(f.fontName.contains("No Such"))
    }
}

final class ComposeTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("shot-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Keep test output out of the real ~/Screenshots index.
        setenv("SHOT_LIBRARY", dir.path, 1)
    }

    override func tearDown() { unsetenv("SHOT_LIBRARY") }

    func input() throws -> String {
        let path = dir.appendingPathComponent("in.png").path
        try writePNG(render(["GITHUB_TOKEN=ghp_8fKz2LqP9xR4tV7bN1mC5dH3jW6yA0sE", "LOG_LEVEL=debug"]), to: path)
        return path
    }

    func testComposeCoversSecretsWithoutBeingAsked() throws {
        let result = try Tools.compose(["input": try input(), "output": dir.appendingPathComponent("out.png").path, "preview": false])
        let redacted = try XCTUnwrap(result.info["redacted"] as? [Args])
        XCTAssertTrue(redacted.contains { $0["kind"] as? String == "secret" }, "\(redacted)")
        XCTAssertNotNil(result.info["redacted_note"])
    }

    func testRedactionCanBeTurnedOff() throws {
        let result = try Tools.compose(["input": try input(), "output": dir.appendingPathComponent("out.png").path,
                                        "preview": false, "redact_sensitive": false])
        XCTAssertNil(result.info["redacted"])
    }

    func testTheLibraryOverrideKeepsTheRealIndexUntouched() throws {
        _ = try Tools.compose(["input": try input(), "output": dir.appendingPathComponent("out.png").path, "preview": false])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".shot-index.json").path))
    }
}
