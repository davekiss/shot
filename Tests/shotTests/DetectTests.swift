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

    func testLoopsNeverCutIntoTheTextTheyCircle() throws {
        // Tight terminal lines leave little room above and below.
        let img = render(["ANTHROPIC_API_KEY=sk-ant", "GITHUB_TOKEN=ghp_8fKz", "PORT=3000", "LOG_LEVEL=debug"], size: 32, width: 1200)
        let ocr = OCRText(img)
        for word in ["GITHUB_TOKEN", "PORT"] {
            var found: [Args] = []
            let out = try Targets.resolve([["type": "ellipse", "target": word]], ocr: ocr, unit: 9, found: &found)
            let loop = try XCTUnwrap(box(out[0])), n = CGFloat(num(out[0], "_exponent") ?? 2)
            let w: CGFloat = 9 * 0.85
            let text = try XCTUnwrap(ocr.find(word).first).rect.insetBy(dx: -(w * 0.5 + Annotator.haloWidth(w)), dy: -(w * 0.5 + Annotator.haloWidth(w)))
            let a = loop.width / 2, b = loop.height / 2
            for corner in [CGPoint(x: text.minX, y: text.minY), CGPoint(x: text.maxX, y: text.maxY)] {
                let inside = pow(abs(corner.x - loop.midX) / a, n) + pow(abs(corner.y - loop.midY) / b, n)
                XCTAssertLessThanOrEqual(inside, 1.0001, "\(word): the loop cuts the text's corner (\(inside))")
            }
        }
    }

    func testBoxesClearTheirTextOnTightLines() throws {
        let img = render(["GITHUB_TOKEN=ghp_8fKz", "STRIPE_SECRET=sk_live", "DATABASE_URL=postgres"], size: 32, width: 1200)
        let ocr = OCRText(img)
        var found: [Args] = []
        let out = try Targets.resolve([["type": "ellipse", "target": "GITHUB_TOKEN"], ["type": "rect", "target": "STRIPE_SECRET"]],
                                      ocr: ocr, unit: 9, found: &found)
        let rect = try XCTUnwrap(box(out[1])), pen = CGFloat(num(out[1], "stroke") ?? 9 * 0.85)
        let text = try XCTUnwrap(ocr.find("STRIPE_SECRET").first).rect
        let inner = rect.insetBy(dx: pen * 0.5 + Annotator.haloWidth(pen), dy: pen * 0.5 + Annotator.haloWidth(pen))
        XCTAssertTrue(inner.contains(text), "the box's stroke reaches into its text: inner \(inner), text \(text)")
    }

    func testSketchLoopsOnlyDriftOutward() {
        let r = CGRect(x: 100, y: 100, width: 300, height: 80)
        let path = Sketch.ellipse(r, width: 6)
        var minScale = CGFloat.infinity
        path.applyWithBlock { el in
            let p = el.pointee.points[0]
            let v = pow((p.x - r.midX) / (r.width / 2), 2) + pow((p.y - r.midY) / (r.height / 2), 2)
            minScale = min(minScale, v)
        }
        XCTAssertGreaterThanOrEqual(minScale, 0.999, "the sketch loop dips inside its ellipse")
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

    func testDiffFindsTheChangedWordAndItsText() throws {
        let before = dir.appendingPathComponent("before.png").path, after = dir.appendingPathComponent("after.png").path
        try writePNG(render(["Status: Draft", "Owner: Dave", "Region: us-east"], size: 36, width: 1000, mono: false), to: before)
        try writePNG(render(["Status: Published", "Owner: Dave", "Region: us-east"], size: 36, width: 1000, mono: false), to: after)
        let result = try Tools.diff(["before": before, "after": after, "preview": false])
        XCTAssertEqual(result.info["changed"] as? Int, 1)
        let region = try XCTUnwrap((result.info["regions"] as? [Args])?.first)
        XCTAssertTrue((region["text_before"] as? String ?? "").contains("Draft"), "\(region)")
        XCTAssertTrue((region["text_after"] as? String ?? "").contains("Published"), "\(region)")
    }

    func testDiffOfIdenticalImagesFindsNothing() throws {
        let p = try input()
        XCTAssertEqual(try Tools.diff(["before": p, "after": p, "preview": false]).info["changed"] as? Int, 0)
    }

    func testDiffRefusesDifferentSizes() throws {
        let small = dir.appendingPathComponent("small.png").path
        try writePNG(render(["x"], width: 400), to: small)
        XCTAssertThrowsError(try Tools.diff(["before": small, "after": try input(), "preview": false]))
    }

    func testWaitConditionsReadTheScreen() throws {
        let img = render(["Deploying…", "Build 42"], size: 36, width: 900, mono: false)
        XCTAssertTrue(Wait.met(.text("Build 42"), img))
        XCTAssertFalse(Wait.met(.text("Deployed"), img))
        XCTAssertTrue(Wait.met(.gone("Error"), img))
        XCTAssertFalse(Wait.met(.gone("Deploying"), img))
    }

    func testTheLibraryOverrideKeepsTheRealIndexUntouched() throws {
        _ = try Tools.compose(["input": try input(), "output": dir.appendingPathComponent("out.png").path, "preview": false])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".shot-index.json").path))
    }
}

final class ScaleTests: XCTestCase {
    func testOneGiantLineDoesNotBlowUpTheMarks() {
        let img = render(["Deployed"], size: 120, width: 1000, mono: false, height: 480)
        let unit = Annotator.markUnit(img, textHeight: OCRText(img).textHeight)
        let base = CGFloat(sqrt(1000.0 * 480) / 200)
        XCTAssertLessThanOrEqual(unit, base * 2.2 + 0.01)
    }

    func testOrdinaryTextSetsTheScale() {
        XCTAssertEqual(Annotator.markUnit(render(["x"], width: 2880, height: 1800), textHeight: 40), 40 / 3.4, accuracy: 0.01)
    }
}

final class StoryboardTests: XCTestCase {
    func testKeepsOnlyTheMomentsThatChanged() {
        let deploying = render(["Status: Deploying"], size: 40, width: 900, mono: false)
        let deployed = render(["Status: Deployed"], size: 40, width: 900, mono: false)
        var board = Storyboard()
        for (i, frame) in [deploying, deploying, deploying, deployed, deployed].enumerated() { board.consider(frame, at: Double(i) * 0.25) }
        board.finish()
        XCTAssertEqual(board.moments.map(\.t), [0, 0.75])
        let change = board.moments[1].changes.first
        XCTAssertTrue(change?.before.contains("Deploying") == true && change?.after.contains("Deployed") == true,
                      "expected whole-line text, got \(String(describing: change))")
    }

    func testPickingKeepsFirstAndLast() {
        var board = Storyboard()
        for i in 0..<30 { board.consider(render(["Frame \(i)"], size: 40, width: 600, mono: false), at: Double(i)) }
        let picked = board.picked(12)
        XCTAssertEqual(picked.count, 12)
        XCTAssertEqual(picked.first?.t, 0)
        XCTAssertEqual(picked.last?.t, board.moments.last?.t)
    }

    func testSheetLaysMomentsOutInAGrid() throws {
        var board = Storyboard()
        for i in 0..<5 { board.consider(render(["Step \(i)"], size: 40, width: 800, mono: false, height: 450), at: Double(i)) }
        let sheet = try Storyboard.sheet(board.moments, unit: 4)
        XCTAssertEqual(sheet.width, 3 * 900 + 4 * 36)   // five moments: three columns
        XCTAssertGreaterThan(sheet.height, sheet.width / 3)
    }
}
