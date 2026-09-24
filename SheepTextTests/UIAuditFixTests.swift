//
//  UIAuditFixTests.swift
//  Regression tests for the app / UI findings of the Sept 2026 audit.
//  One test (or group) per finding id; the id is named in each test's comment
//  so a failure points straight back at what it is protecting.
//

import AppKit
import SwiftUI
import XCTest
@testable import SheepText

// MARK: - U9 — UpdateChecker.isNewer

final class UpdateCheckerVersionTests: XCTestCase {

    /// The bug: `split(separator: ".").compactMap { Int($0) }` DROPPED any
    /// component that did not parse whole, which shifts every later component
    /// left. "1.3.5-beta.2" became [1, 3, 2] — read as 1.3.2, i.e. a downgrade
    /// — and "1.3.5 (17)" became [1, 3], read as 1.3.0.
    func testPreReleaseTagIsNotNewerThanItsRelease() {
        XCTAssertFalse(UpdateChecker.isNewer("1.3.5-beta.2", than: "1.3.5"))
        XCTAssertFalse(UpdateChecker.isNewer("1.3.5+build.9", than: "1.3.5"))
    }

    func testBuildNumberSuffixIsNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("1.3.5 (17)", than: "1.3.5"))
    }

    func testComponentsCompareNumericallyNotLexically() {
        XCTAssertTrue(UpdateChecker.isNewer("1.10.0", than: "1.9.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.9.0", than: "1.10.0"))
    }

    func testMissingComponentsCountAsZero() {
        XCTAssertTrue(UpdateChecker.isNewer("2.0", than: "1.9.9"))
        XCTAssertFalse(UpdateChecker.isNewer("1.3", than: "1.3.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.3.1", than: "1.3"))
    }

    func testEqualVersionsAreNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("1.3.5", than: "1.3.5"))
    }

    /// A component that is not a number at all must become 0 rather than
    /// vanish, so the positions of the components after it do not move.
    func testUnparseableComponentDoesNotShiftLaterComponents() {
        XCTAssertTrue(UpdateChecker.isNewer("1.x.9", than: "1.0.8"))
        XCTAssertFalse(UpdateChecker.isNewer("1.x.7", than: "1.0.8"))
    }

    // MARK: U3 — launch-check throttle

    func testAutomaticCheckIsSkippedWhenPreferenceIsOff() {
        XCTAssertFalse(UpdateChecker.isAutomaticCheckDue(enabled: false, lastCheck: nil, now: Date()))
    }

    func testFirstEverAutomaticCheckIsDue() {
        XCTAssertTrue(UpdateChecker.isAutomaticCheckDue(enabled: true, lastCheck: nil, now: Date()))
    }

    func testAutomaticCheckIsThrottledForTwentyFourHours() {
        let now = Date()
        let hourAgo = now.addingTimeInterval(-3600)
        XCTAssertFalse(UpdateChecker.isAutomaticCheckDue(enabled: true, lastCheck: hourAgo, now: now))

        let dayAgo = now.addingTimeInterval(-UpdateChecker.automaticCheckInterval - 1)
        XCTAssertTrue(UpdateChecker.isAutomaticCheckDue(enabled: true, lastCheck: dayAgo, now: now))
    }

    /// A clock correction can leave a timestamp in the future. That must not
    /// mean "never check again".
    func testFutureTimestampIsTreatedAsDue() {
        let now = Date()
        XCTAssertTrue(
            UpdateChecker.isAutomaticCheckDue(enabled: true, lastCheck: now.addingTimeInterval(600), now: now)
        )
    }
}

// MARK: - U4 — save commands act on ONE document

@MainActor
final class SaveTargetResolutionTests: XCTestCase {

    /// With no editor focused, the target is the active tab — the behaviour
    /// callers already relied on.
    func testTargetFallsBackToTheActiveDocument() {
        let documents = DocumentStore()
        let doc = documents.newUntitled()
        XCTAssertEqual(BuiltInCommands.saveTargetDocumentID(documents), doc.id)
    }

    /// `prepareSave` no longer trims (auto save must never rewrite the user's
    /// text), so a manual save has to. A background tab has no text view, and
    /// the trim still has to happen for it — Save All writes it too.
    func testTrimAppliesToADocumentWithNoLiveEditor() {
        let documents = DocumentStore()
        let doc = documents.newUntitled()
        doc.lineEnding = .lf
        doc.autoTrimTrailingWhitespace = true
        doc.text = "a   \nb\t\nc"

        BuiltInCommands.trimDocumentIfNeeded(doc.id, in: documents)

        XCTAssertEqual(doc.text, "a\nb\nc")
    }

    func testTrimIsSkippedWhenTheOptionIsOff() {
        let documents = DocumentStore()
        let doc = documents.newUntitled()
        doc.autoTrimTrailingWhitespace = false
        doc.text = "a   \nb"

        BuiltInCommands.trimDocumentIfNeeded(doc.id, in: documents)

        XCTAssertEqual(doc.text, "a   \nb")
    }

    func testSaveAllTrimsEveryDirtyDocument() {
        let documents = DocumentStore()
        let first = documents.newUntitled()
        let second = documents.newUntitled()
        for doc in [first, second] {
            doc.lineEnding = .lf
            doc.autoTrimTrailingWhitespace = true
            doc.text = "x   "
            doc.isDirty = true
        }

        BuiltInCommands.trimAllDirtyDocumentsIfNeeded(in: documents)

        XCTAssertEqual(first.text, "x")
        XCTAssertEqual(second.text, "x", "Save All used to trim only the focused editor's document")
    }
}

// MARK: - U18 — editor-appearance notification coalescing

@MainActor
final class EditorAppearanceCoalescingTests: XCTestCase {

    /// `AppPreferences` used to write straight to `UserDefaults.standard`, and
    /// the test host IS the app (same bundle id, same container). Under XCTest
    /// it now writes to a per-process suite (`AppStorageLocation`), so this
    /// restore is a second line of defence rather than the only one. This class used to
    /// leave the font-size slider at 35 pt and the line-number switch flipped in
    /// the user's real preferences — and the release script runs the suite
    /// right before it installs, so every release shipped with huge text.
    /// Snapshot what we touch and put it back, whatever the outcome.
    private var savedFontSize: Double = 0
    private var savedShowsLineNumbers = true

    override func setUp() {
        super.setUp()
        let live = AppPreferences()
        savedFontSize = live.editorFontSize
        savedShowsLineNumbers = live.showsLineNumbers
    }

    override func tearDown() {
        let live = AppPreferences()
        live.editorFontSize = savedFontSize
        live.showsLineNumbers = savedShowsLineNumbers
        super.tearDown()
    }

    /// Every observer of `.editorAppearanceDidChange` clears its highlight cache
    /// and re-highlights the whole document. Dragging the font-size slider from
    /// 9 pt to 36 pt posted it 27 times — 27 full re-parses for one gesture.
    ///
    /// Leading + trailing: the first step is still immediate, everything inside
    /// the coalescing window collapses into one trailing post.
    func testASliderDragCollapsesIntoTwoNotifications() {
        let preferences = AppPreferences()
        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: .editorAppearanceDidChange, object: nil, queue: .main
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        for size in 9...35 {
            preferences.editorFontSize = Double(size)
        }
        XCTAssertEqual(posts, 1, "the first change must still be immediate")

        let settled = expectation(description: "coalescing window elapsed")
        DispatchQueue.main.asyncAfter(
            deadline: .now() + AppPreferences.editorAppearanceCoalescingWindow * 3
        ) { settled.fulfill() }
        wait(for: [settled], timeout: 5)

        XCTAssertEqual(posts, 2, "27 slider steps must cost 2 notifications, not 27")
    }

    /// A single change (a checkbox, a font pick) must still be immediate and
    /// must not fire a second time when the window closes.
    func testASingleChangePostsExactlyOnce() {
        let preferences = AppPreferences()
        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: .editorAppearanceDidChange, object: nil, queue: .main
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        preferences.showsLineNumbers.toggle()
        XCTAssertEqual(posts, 1)

        let settled = expectation(description: "coalescing window elapsed")
        DispatchQueue.main.asyncAfter(
            deadline: .now() + AppPreferences.editorAppearanceCoalescingWindow * 3
        ) { settled.fulfill() }
        wait(for: [settled], timeout: 5)

        XCTAssertEqual(posts, 1, "the trailing edge must not duplicate a lone change")
    }
}

// MARK: - U21 — file tree flattening

@MainActor
final class FileTreeFlatteningTests: XCTestCase {

    private func node(_ path: String, isDirectory: Bool, children: [FileNode]? = nil) -> FileNode {
        FileNode(url: URL(fileURLWithPath: path), isDirectory: isDirectory, children: children)
    }

    /// The flattened list must be the depth-first order the nested VStacks
    /// produced, with the same levels — this is what makes one LazyVStack a
    /// drop-in for the recursive one.
    func testFlattenProducesDepthFirstRowsWithLevels() {
        let tree = [
            node("/w/src", isDirectory: true, children: [
                node("/w/src/a.swift", isDirectory: false),
                node("/w/src/deep", isDirectory: true, children: [
                    node("/w/src/deep/b.swift", isDirectory: false)
                ])
            ]),
            node("/w/README.md", isDirectory: false)
        ]

        let expanded: Set<URL> = [
            URL(fileURLWithPath: "/w/src").standardizedFileURL,
            URL(fileURLWithPath: "/w/src/deep").standardizedFileURL
        ]
        let rows = FileTreeView.flatten(tree, expandedFolders: expanded)

        XCTAssertEqual(rows.map(\.node.url.lastPathComponent),
                       ["src", "a.swift", "deep", "b.swift", "README.md"])
        XCTAssertEqual(rows.map(\.level), [0, 1, 1, 2, 0])
    }

    func testCollapsedFoldersContributeNoRows() {
        let tree = [
            node("/w/src", isDirectory: true, children: [
                node("/w/src/a.swift", isDirectory: false)
            ])
        ]
        let rows = FileTreeView.flatten(tree, expandedFolders: [])
        XCTAssertEqual(rows.map(\.node.url.lastPathComponent), ["src"])
    }

    func testRowIdentitiesAreUnique() {
        let tree = [
            node("/w/src", isDirectory: true, children: [
                node("/w/src/a.swift", isDirectory: false),
                node("/w/src/b.swift", isDirectory: false)
            ])
        ]
        let rows = FileTreeView.flatten(
            tree,
            expandedFolders: [URL(fileURLWithPath: "/w/src").standardizedFileURL]
        )
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }
}

// MARK: - S4 — SQL numeric literals

@MainActor
final class SQLNumberHighlightTests: XCTestCase {

    /// `#match?` predicates are compiled with `NSRegularExpression`, where `%d`
    /// is a literal percent followed by a d — a Lua character class that never
    /// matches a digit. Both SQL number patterns were therefore dead and every
    /// numeric literal kept the earlier `(literal) @string` capture, rendering
    /// green instead of orange.
    func testSQLIntegerLiteralIsColouredAsANumberNotAString() throws {
        let text = "SELECT 42, 3.14, 'text' FROM t;"
        let highlighted = try XCTUnwrap(
            SyntaxEngine.shared.highlightImmediately(text: text, language: "sql", isDark: true),
            "SQL grammar or queries did not load"
        )

        let ns = text as NSString
        let numberColour = try colour(in: highlighted, at: ns.range(of: "42"))
        let floatColour = try colour(in: highlighted, at: ns.range(of: "3.14"))
        let stringColour = try colour(in: highlighted, at: ns.range(of: "'text'"))

        // One Dark "number" is #D19A66; "string" is #98C379.
        XCTAssertEqual(hex(numberColour), "D19A66", "42 is not painted as a number")
        XCTAssertEqual(hex(floatColour), "D19A66", "3.14 is not painted as a number")
        XCTAssertNotEqual(hex(numberColour), hex(stringColour))
    }

    private func colour(in string: NSAttributedString, at range: NSRange) throws -> NSColor {
        XCTAssertNotEqual(range.location, NSNotFound)
        let attributes = string.attributes(at: range.location, effectiveRange: nil)
        return try XCTUnwrap(attributes[.foregroundColor] as? NSColor, "no colour at \(range)")
    }

    private func hex(_ colour: NSColor) -> String {
        let rgb = colour.usingColorSpace(.sRGB) ?? colour
        return String(
            format: "%02X%02X%02X",
            Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()),
            Int((rgb.blueComponent * 255).rounded())
        )
    }
}
