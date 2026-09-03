import AppKit
import XCTest
@testable import SheepText

@MainActor
final class Swift6AppKitRegressionTests: XCTestCase {
    /// The incremental path must not silently degrade back into a full rebuild.
    ///
    /// It once did: the parse was reused but the highlights query still walked
    /// the whole tree and a document-sized attributed string was allocated from
    /// scratch every pass, so an edit in a 100k-character file cost 451 ms
    /// against 520 ms for a clean parse — 13%. With the query range-restricted
    /// and last pass's attributes spliced and reused it is ~11 ms. The 5x
    /// threshold below is deliberately far looser than the ~44x measured, so
    /// this fails on a structural regression, not on a slow machine.
    func testIncrementalHighlightIsSubstantiallyCheaperThanCleanParse() {
        let line = "func value(_ input: Int) -> Int { let result = input * 2; return result } // probe 0\n"
        let base = String(repeating: line, count: 100_000 / (line as NSString).length)
        let documentID = UUID()
        _ = SyntaxEngine.shared.highlightImmediately(
            text: base, language: "swift", isDark: true, documentID: documentID
        )

        var incremental: [Double] = []
        var clean: [Double] = []
        for index in 1...5 {
            let edited = base.replacingOccurrences(
                of: "probe 0",
                with: "probe \(index)",
                options: [],
                range: base.range(of: "probe 0")
            )
            var start = CFAbsoluteTimeGetCurrent()
            _ = SyntaxEngine.shared.highlightImmediately(
                text: edited, language: "swift", isDark: true, documentID: documentID
            )
            incremental.append(CFAbsoluteTimeGetCurrent() - start)
            start = CFAbsoluteTimeGetCurrent()
            _ = SyntaxEngine.shared.highlightImmediately(
                text: edited, language: "swift", isDark: true
            )
            clean.append(CFAbsoluteTimeGetCurrent() - start)
        }
        incremental.sort()
        clean.sort()

        XCTAssertLessThan(
            incremental[2] * 5, clean[2],
            "incremental median \(incremental[2] * 1000) ms vs clean \(clean[2] * 1000) ms"
        )
        SyntaxEngine.shared.discardSession(for: documentID)
    }

    /// The risky half of the incremental highlight: an edit whose effect reaches
    /// far outside the edited line. Opening a block comment retints everything
    /// down to the closing delimiter, so the reused attributes have to be
    /// invalidated across that whole span, not just the paragraph that changed.
    func testIncrementalHighlightMatchesCleanParseWhenABlockCommentOpensAndCloses() {
        let documentID = UUID()
        let plain = """
        let alpha = 1
        let beta = 2
        let gamma = 3
        func use() -> Int { alpha + beta + gamma }
        """
        let commented = plain.replacingOccurrences(
            of: "let alpha = 1",
            with: "/* let alpha = 1"
        ).replacingOccurrences(
            of: "let gamma = 3",
            with: "let gamma = 3 */"
        )

        for step in [plain, commented, plain] {
            let incremental = SyntaxEngine.shared.highlightImmediately(
                text: step, language: "swift", isDark: true, documentID: documentID
            )
            let clean = SyntaxEngine.shared.highlightImmediately(
                text: step, language: "swift", isDark: true
            )
            XCTAssertNotNil(incremental)
            XCTAssertNotNil(clean)
            if let incremental, let clean {
                XCTAssertTrue(
                    incremental.isEqual(to: clean),
                    "incremental highlight diverged from a clean parse"
                )
            }
        }
        SyntaxEngine.shared.discardSession(for: documentID)
    }

    /// Markdown takes the incremental path since September 2026 (fences come
    /// from the block grammar, and a changed range is widened to the fence it
    /// overlaps), so this is a genuine incremental-vs-clean check, not a check
    /// that a full rebuild equals itself.
    func testIncrementalHighlightMatchesCleanParseForMarkdownFence() {
        let documentID = UUID()
        let opened = "# Title\n\n```swift\nlet x = 1\n```\n\ntrailing text\n"
        let closed = "# Title\n\n```swift\nlet x = 1\nlet y = 2\n```\n\ntrailing text\n"

        for step in [opened, closed, opened] {
            let incremental = SyntaxEngine.shared.highlightImmediately(
                text: step, language: "markdown", isDark: true, documentID: documentID
            )
            let clean = SyntaxEngine.shared.highlightImmediately(
                text: step, language: "markdown", isDark: true
            )
            if let incremental, let clean {
                XCTAssertTrue(incremental.isEqual(to: clean))
            }
        }
        SyntaxEngine.shared.discardSession(for: documentID)
    }

    /// Plugin JS runs on the main thread (PluginHost is @MainActor), so a bridge
    /// that unconditionally blocks on `DispatchQueue.main.sync` deadlocks the
    /// app. This is the exact path the bundled hello-world plugin takes from
    /// `hello.countLines` and `hello.reverseLine`.
    ///
    /// If this ever regresses the test will hang rather than fail — that is the
    /// same symptom the user gets, and it is not something an assertion can
    /// catch after the fact.
    func testPluginBridgesDoNotDeadlockOnTheMainThread() {
        XCTAssertTrue(Thread.isMainThread)

        let bridge = EditorBridge()
        // No key window in a unit test, so these take the "no editor" branch —
        // which still crosses `pluginMainSync`, the part that used to hang.
        XCTAssertEqual(bridge.getText(), "")
        XCTAssertEqual(bridge.getLanguage(), "plaintext")
        XCTAssertEqual(bridge.getCurrentLine()["number"] as? Int, 0)
        bridge.replaceSelection("ignored")
        bridge.replaceCurrentLine("ignored")

        let workspace = WorkspaceBridge(workspace: nil)
        XCTAssertEqual(workspace.getRootPath(), "")
        XCTAssertTrue(workspace.findFiles("*.swift").isEmpty)

        XCTAssertEqual(pluginMainSync { 41 + 1 }, 42)
    }

    func testDiffLayoutManagerKeepsHighlightRangesAlignedAfterReplacement() {
        let storage = NSTextStorage(string: "aa\nbb\ncc\n")
        let layoutManager = DiffLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 500, height: 500))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        layoutManager.lineHighlights = [
            (NSRange(location: 0, length: 3), .systemRed),
            (NSRange(location: 3, length: 3), .systemGreen),
            (NSRange(location: 6, length: 3), .systemPurple),
        ]

        storage.replaceCharacters(in: NSRange(location: 3, length: 2), with: "BBBB")

        XCTAssertEqual(layoutManager.lineHighlights.map(\.range), [
            NSRange(location: 0, length: 3),
            NSRange(location: 3, length: 5),
            NSRange(location: 8, length: 3),
        ])
    }

    func testCiscoHighlightResultCrossesWorkerQueueIntact() {
        let source = "vlan 100,306s\nspanning-tree mode rpvsts\n"
        guard let result = SyntaxEngine.shared.highlightImmediately(
            text: source,
            language: "cisco_ios",
            isDark: true
        ) else {
            return XCTFail("Cisco highlighter returned nil")
        }

        let ns = source as NSString
        let validRange = ns.range(of: "100")
        let invalidVLANRange = ns.range(of: "306s")
        let invalidModeRange = ns.range(of: "rpvsts")
        let validColor = result.attribute(.foregroundColor, at: validRange.location, effectiveRange: nil) as? NSColor
        let invalidVLANColor = result.attribute(.foregroundColor, at: invalidVLANRange.location, effectiveRange: nil) as? NSColor
        let invalidModeColor = result.attribute(.foregroundColor, at: invalidModeRange.location, effectiveRange: nil) as? NSColor

        XCTAssertNotNil(validColor)
        XCTAssertNotNil(invalidVLANColor)
        XCTAssertNotNil(invalidModeColor)
        XCTAssertNotEqual(validColor, invalidVLANColor)
        XCTAssertEqual(invalidVLANColor, invalidModeColor)
    }

    func testArubaCXUsesSheepTermNetworkRules() {
        let source = """
        ! Aruba CX configuration
        interface 1/1/24
        description uplink 10.20.30.40 aabb.ccdd.eeff
        vlan 10,20-30
        state connected warning down
        """
        guard let result = SyntaxEngine.shared.highlightImmediately(
            text: source,
            language: "aruba_cx",
            isDark: true
        ) else {
            return XCTFail("Aruba CX highlighter returned nil")
        }

        let ns = source as NSString
        func color(_ token: String) -> NSColor? {
            let range = ns.range(of: token)
            return result.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
        }

        let comment = color("! Aruba")
        let port = color("1/1/24")
        let ipv4 = color("10.20.30.40")
        let mac = color("aabb.ccdd.eeff")
        let vlan = color("vlan 10,20-30")
        let good = color("connected")
        let warning = color("warning")
        let bad = color("down")

        for highlighted in [comment, port, ipv4, mac, vlan, good, warning, bad] {
            XCTAssertNotNil(highlighted)
        }
        XCTAssertNotEqual(good, warning)
        XCTAssertNotEqual(warning, bad)
        XCTAssertNotEqual(ipv4, mac)
        XCTAssertTrue(SyntaxEngine.supportsHighlighting("aoscx"))
        XCTAssertEqual(
            LanguageDetector.detect(for: URL(fileURLWithPath: "/tmp/switch.aoscx")),
            "aruba_cx"
        )
    }

    func testIncrementalTreeSitterMatchesCleanParseForUnicodeAndCRLFEdit() {
        let documentID = UUID()
        let original = "let title = \"แกะ 🐑\"\r\nfunc value() -> Int { 1 }\r\n"
        let edited = "let title = \"แกะน้อย 🐑\"\r\nfunc value() -> Int { return 2 }\r\n"

        XCTAssertNotNil(SyntaxEngine.shared.highlightImmediately(
            text: original,
            language: "swift",
            isDark: true,
            documentID: documentID
        ))
        let incremental = SyntaxEngine.shared.highlightImmediately(
            text: edited,
            language: "swift",
            isDark: true,
            documentID: documentID
        )
        let clean = SyntaxEngine.shared.highlightImmediately(
            text: edited,
            language: "swift",
            isDark: true
        )

        XCTAssertNotNil(incremental)
        XCTAssertNotNil(clean)
        if let incremental, let clean {
            XCTAssertTrue(incremental.isEqual(to: clean))
        }
        // Unlike its three siblings this used to end without discarding, leaking
        // one session — text, tree copy and attributed string — into the LRU for
        // the rest of the test run.
        SyntaxEngine.shared.discardSession(for: documentID)
    }
}

final class Swift6BackgroundRegressionTests: XCTestCase {
    func testCompareDiffCountsRunOffMainActor() async {
        let counts = await Task.detached(priority: .utility) {
            CompareDiffCounter.make(leftText: "same", rightText: "same\nadded")
        }.value

        XCTAssertEqual(counts, CompareDiffCounts(removed: 0, added: 1, changed: 0, moved: 0))
    }

    func testTextDecodingRunsOffMainActor() async {
        let data = Data("hello\r\nสวัสดี".utf8)
        let decoded = await Task.detached(priority: .utility) {
            TextFileIO.decode(data: data)
        }.value

        XCTAssertEqual(decoded.text, "hello\r\nสวัสดี")
        XCTAssertEqual(decoded.encoding, .utf8)
        XCTAssertFalse(decoded.hadBOM)
    }

    func testFindInFilesRunsOffMainActor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sheeptext-swift6-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("alpha needle omega\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("nothing here\nneedle again\n".utf8).write(to: root.appendingPathComponent("b.txt"))

        let tree = FileNode.scan(at: root)
        let options = FindInFilesOptions(
            query: "needle",
            caseSensitive: true,
            wholeWord: false,
            useRegex: false
        )
        let summary = try await Task.detached(priority: .userInitiated) {
            try FindInFilesEngine.search(root: root, tree: tree, options: options)
        }.value

        XCTAssertEqual(summary.matches.count, 2)
        XCTAssertEqual(summary.searchedFiles, 2)
        XCTAssertEqual(Set(summary.matches.map(\.lineNumber)), [1, 2])
    }
}
