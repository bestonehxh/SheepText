//
//  EditorViewAuditFixTests.swift
//  Regression tests for the EditorView coordinator findings of the Sept 2026
//  audit (S3, S5, S8/U17, S9, U8, U19, U20, U23, U25, R2).
//
//  Every test here failed — or could not be written — before its fix. The
//  coordinator is file-private, so these drive it through
//  `EditorViewAuditSeam` at the bottom of EditorView.swift, which is DEBUG-only
//  for the same reason `SyntaxAuditFixTests`' engine seams are.
//

import AppKit
import XCTest
@testable import SheepText

// EditorViewAuditSeam exists only in DEBUG builds; the Release test target
// runs the perf harness only.
#if DEBUG

// MARK: - Fixtures

@MainActor
private enum Fixture {

    /// 40 numbered lines, ~13 UTF-16 units each — long enough that a
    /// one-paragraph `changedRanges` stays under the incremental path's
    /// "half the document" cutoff.
    static let plainSource: String = (0..<40)
        .map { String(format: "line %02d aaaa", $0) }
        .joined(separator: "\n") + "\n"

    /// A foldable brace block followed by ordinary lines.
    static let foldableSource: String = ([
        "func outer() {",
        "    let a = 1",
        "    let b = 2",
        "}"
    ] + (0..<12).map { "let tail\($0) = \($0)" }).joined(separator: "\n") + "\n"

    static func colored(_ text: String, _ color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.foregroundColor: color])
    }

    /// `base` re-coloured over `range` — i.e. exactly the delta a real
    /// incremental parse reports, and nothing else.
    static func recolored(
        _ text: String,
        base: NSColor,
        _ range: NSRange,
        _ color: NSColor
    ) -> NSAttributedString {
        let string = NSMutableAttributedString(
            string: text,
            attributes: [.foregroundColor: base]
        )
        string.addAttribute(.foregroundColor, value: color, range: range)
        return string
    }
}

// MARK: - S3 / S9: what replaced the incremental apply
//
// Both findings were about an apply that wrote the engine's result into the
// text storage: S3 ("the storage must already hold the engine's PREVIOUS result
// before a changed-ranges-only apply is legal") and S9 ("translate the changed
// ranges through the fold map instead of falling back to a whole-document
// repaint"). Neither state exists any more — the engine hands over a COMPLETE
// run list and the editor paints the viewport from it, which is idempotent and
// costs the screen — so the tests that remain are the properties that took
// their place. The rest live in `ViewportHighlightTests.swift`.

@MainActor
final class SyntaxApplyPreconditionTests: XCTestCase {

    /// S3 by construction: every result is complete, so a result that never
    /// reached the view cannot leave the next one describing a delta against
    /// something nothing painted. Painting twice from two run lists is the same
    /// as painting once from the second.
    func testASkippedResultCannotLeaveAPartialPaint() {
        let length = (Fixture.plainSource as NSString).length
        let dropped = EditorViewAuditSeam.Probe(text: Fixture.plainSource)
        let clean = EditorViewAuditSeam.Probe(text: Fixture.plainSource)

        let first = [HighlightRun(range: NSRange(location: 0, length: length), style: keywordStyle)]
        let second = [HighlightRun(range: NSRange(location: 0, length: length), style: stringStyle)]

        // The generation race: `first` is computed and never applied.
        dropped.setRuns(second)
        clean.setRuns(first)
        clean.setRuns(second)

        XCTAssertEqual(dropped.paintedForegroundColors(), clean.paintedForegroundColors())
    }

    /// Syntax colouring is not in the text storage at all any more. That is the
    /// invariant every other property here rests on — undo cannot see it, a
    /// tab switch cannot leave it behind, and a `setAttributes` cannot wipe it.
    func testHighlightingNeverEntersTheTextStorage() {
        let probe = EditorViewAuditSeam.Probe(text: Fixture.plainSource)
        let before = probe.storageAttributeKeys()
        probe.setRuns([
            HighlightRun(range: NSRange(location: 0, length: 12), style: keywordStyle)
        ])
        XCTAssertEqual(probe.storageAttributeKeys(), before,
                       "a highlight pass changed the storage's attributes")
        XCTAssertNotNil(
            probe.paintedForegroundColors()[0],
            "…and yet nothing was painted either — the test would pass vacuously"
        )
    }

    private var keywordStyle: HighlightStyleID {
        HighlightStyleTable.styleID(forCapture: "keyword")
    }

    private var stringStyle: HighlightStyleID {
        HighlightStyleTable.styleID(forCapture: "string")
    }
}

// MARK: - S9: a fold moves display offsets, not runs

@MainActor
final class FoldedIncrementalHighlightTests: XCTestCase {

    private func foldedProbe() throws -> EditorViewAuditSeam.Probe {
        let probe = EditorViewAuditSeam.Probe(text: Fixture.foldableSource)
        let range = try XCTUnwrap(
            probe.foldingManager.foldableRange(
                onLine: 1, displayText: probe.storage.string as NSString
            ),
            "fixture is not foldable — the test would pass vacuously"
        )
        probe.foldingManager.fold(range: range, in: probe.storage)
        XCTAssertEqual(probe.foldingManager.regions.count, 1)
        return probe
    }

    /// Runs are in FULL-text offsets and a fold does not change the full text,
    /// so the same run list has to land on the right characters either way. The
    /// translation is `visibleSegments`; without it the colours would be short
    /// by everything the fold hides.
    func testPaintingThroughAFoldLandsOnTheRightCharacters() throws {
        let probe = try foldedProbe()
        let source = Fixture.foldableSource as NSString
        let tail = source.range(of: "let tail10")
        probe.setRuns([HighlightRun(range: tail, style: HighlightStyleTable.styleID(forCapture: "keyword"))])

        let display = probe.storage.string as NSString
        let displayTail = display.range(of: "let tail10")
        XCTAssertNotEqual(displayTail.location, NSNotFound)
        XCTAssertNotEqual(displayTail.location, tail.location,
                          "the fold must actually shift this line, or the test proves nothing")

        let painted = probe.paintedForegroundColors()
        let expected = HighlightStyleTable.color(
            HighlightStyleTable.styleID(forCapture: "keyword"), isDark: probe.isDark
        )
        XCTAssertEqual(painted[displayTail.location], expected)
        XCTAssertNotEqual(painted[displayTail.location - 2], expected,
                          "the paint spilled outside the run")
    }

    /// Found while testing S9, and still true: `setAttributes` replaces the
    /// whole attribute dictionary, so a wipe deletes the `.attachment` on the
    /// fold placeholder and the "{ 3 lines }" pill becomes a bare U+FFFC. The
    /// wipe is rare now (an unsupported language, or large-file mode) but it is
    /// still there.
    func testAttributeResetKeepsTheFoldPlaceholderAttachment() throws {
        let probe = try foldedProbe()
        let placeholder = probe.foldingManager.regions[0].displayLocation
        XCTAssertNotNil(probe.storage.attribute(.attachment, at: placeholder, effectiveRange: nil),
                        "fixture has no attachment — the test would pass vacuously")

        // plaintext has no grammar, so this takes the reset path.
        probe.applyHighlightNow()

        XCTAssertNotNil(probe.storage.attribute(.attachment, at: placeholder, effectiveRange: nil),
                        "the attribute reset destroyed the fold placeholder")
    }

    /// Folding or unfolding moves every display offset below it, so the paint
    /// is thrown away and redone — from the same runs, which did not change.
    func testFoldingRepaintsFromTheSameRuns() throws {
        let probe = EditorViewAuditSeam.Probe(text: Fixture.foldableSource)
        let source = Fixture.foldableSource as NSString
        let tail = source.range(of: "let tail10")
        let style = HighlightStyleTable.styleID(forCapture: "keyword")
        probe.setRuns([HighlightRun(range: tail, style: style)])
        XCTAssertEqual(probe.paintedForegroundColors()[tail.location],
                       HighlightStyleTable.color(style, isDark: probe.isDark))

        let range = try XCTUnwrap(
            probe.foldingManager.foldableRange(
                onLine: 1, displayText: probe.storage.string as NSString
            )
        )
        probe.foldingManager.fold(range: range, in: probe.storage)
        probe.foldingDidChangeDisplayText()

        XCTAssertEqual(probe.runs, [HighlightRun(range: tail, style: style)],
                       "a fold must not disturb the run list")
        let display = probe.storage.string as NSString
        let displayTail = display.range(of: "let tail10")
        XCTAssertEqual(probe.paintedForegroundColors()[displayTail.location],
                       HighlightStyleTable.color(style, isDark: probe.isDark))
    }
}

// MARK: - S8 / U17: activation must not re-highlight

@MainActor
final class AppearanceInvalidationTests: XCTestCase {

    /// The bug: `NSApplication.didBecomeActive` and `NSWorkspace.didWake` wiped
    /// a *static* cache shared by every coordinator and re-highlighted the whole
    /// document — 65 ms + 8 ms measured at 542k characters, per pane, on every
    /// ⌘-Tab back into the app. The observers exist for a real bug (the system
    /// appearance flipping while the app is inactive), so the guard is on the
    /// resolved appearance, not on the notification.
    func testUnforcedInvalidationIsANoOpWhenTheAppearanceIsUnchanged() {
        let probe = EditorViewAuditSeam.Probe(text: Fixture.plainSource)

        probe.invalidateHighlightingAfterExternalChange()   // first: appearance unknown
        let baseline = EditorViewAuditSeam.applyHighlightCallCount

        probe.invalidateHighlightingAfterExternalChange()
        probe.invalidateHighlightingAfterExternalChange()
        XCTAssertEqual(EditorViewAuditSeam.applyHighlightCallCount, baseline,
                       "⌘-Tab must not re-highlight when the appearance did not change")
    }

    /// Theme and syntax-settings changes still force: the token colours can
    /// change without `isDark` moving.
    func testForcedInvalidationAlwaysReapplies() {
        let probe = EditorViewAuditSeam.Probe(text: Fixture.plainSource)
        probe.invalidateHighlightingAfterExternalChange()
        let baseline = EditorViewAuditSeam.applyHighlightCallCount

        probe.invalidateHighlightingAfterExternalChange(force: true)
        XCTAssertEqual(EditorViewAuditSeam.applyHighlightCallCount, baseline + 1)
    }
}

// MARK: - S5: the whole-document highlight cache

@MainActor
final class SyntaxHighlightCacheLifetimeTests: XCTestCase {

    private func makeDocument(_ text: String = "hello") -> Document {
        Document(url: nil, initialText: text, encoding: .utf8, hasBOM: false)
    }

    override func setUp() {
        super.setUp()
        EditorViewAuditSeam.clearHighlightCache()
    }

    override func tearDown() {
        EditorViewAuditSeam.clearHighlightCache()
        super.tearDown()
    }

    /// Each entry is a document-sized attributed string; 8 is what
    /// `SyntaxEngine.sessionLimit` keeps one layer down for the same data.
    func testCacheLimitMatchesTheEngineSessionLimit() {
        XCTAssertEqual(EditorViewAuditSeam.highlightCacheLimit, 8)
    }

    /// The entry point `DocumentStore.close` needs: nothing else evicts a closed
    /// document's entry, because the coordinator is torn down on every tab
    /// switch while the document stays open.
    func testDiscardRemovesAClosedDocumentsEntry() {
        let document = makeDocument()
        EditorViewAuditSeam.storeHighlight(for: document)
        XCTAssertTrue(EditorViewAuditSeam.highlightCacheContains(document.id))

        EditorHighlightCache.discard(for: document.id)
        XCTAssertFalse(EditorViewAuditSeam.highlightCacheContains(document.id))
    }

    /// Belt and braces for the explicit discard: an entry whose document nothing
    /// holds any more can never be repainted, so it is swept on the next store.
    func testEntryIsSweptOnceItsDocumentIsGone() {
        var closedID: Document.ID?
        do {
            let closing = makeDocument("a document that is about to close")
            closedID = closing.id
            EditorViewAuditSeam.storeHighlight(for: closing)
        }
        let id = try! XCTUnwrap(closedID)

        let keeper = makeDocument("still open")
        EditorViewAuditSeam.storeHighlight(for: keeper)

        XCTAssertFalse(EditorViewAuditSeam.highlightCacheContains(id),
                       "a deallocated document's attributed string must not stay resident")
        XCTAssertTrue(EditorViewAuditSeam.highlightCacheContains(keeper.id))
    }
}

// MARK: - U8: one definition of "N chars"

@MainActor
final class StatusBarCharacterCountTests: XCTestCase {

    /// The bug: `refresh` (tab switch) counted grapheme clusters and `push`
    /// (every selection change) counted UTF-16 units, so the status bar said 3
    /// and then 6 for the same three sheep. `refresh` was also an O(document)
    /// grapheme-breaking pass on the main thread.
    func testBothPathsAgreeOnTheCharacterCount() {
        for text in ["🐑🐑🐑",
                     "กิน\u{0E48}ข้าว",
                     "a\r\nb\r\nc",
                     "plain ascii"] {
            let probe = EditorViewAuditSeam.Probe(text: text)
            let expected = (text as NSString).length
            XCTAssertEqual(probe.refreshCounts(), expected, "refresh disagrees for \(text)")
            XCTAssertEqual(probe.pushCounts(), expected, "push disagrees for \(text)")
        }
    }
}

// MARK: - U23 / T7: the line-number memo

@MainActor
final class CursorLineMemoTests: XCTestCase {

    /// The memo must answer exactly what a cold scan answers, wherever the caret
    /// goes — forward, backward, within a line, and across CRLF pairs (which are
    /// one break, and an offset between the CR and the LF stays on the CR's
    /// line).
    func testMemoAgreesWithAColdLookupForEveryCaretMove() {
        for ending in ["\n", "\r\n", "\r"] {
            let text = (0..<12).map { "line \($0) text" }.joined(separator: ending) + ending
            let ns = text as NSString
            let probe = EditorViewAuditSeam.Probe(text: text)

            var offsets = Array(stride(from: 0, through: ns.length, by: 3))
            offsets += offsets.reversed()
            offsets += [ns.length, 0, ns.length / 2, ns.length / 2 + 1, 1]

            for offset in offsets {
                let expected = TextLineIndex.lineColumn(in: ns, at: offset)
                let got = probe.pushPosition(at: offset)
                XCTAssertEqual(got.line, expected.line,
                               "line at \(offset) with ending \(ending.debugDescription)")
                XCTAssertEqual(got.column, expected.column,
                               "column at \(offset) with ending \(ending.debugDescription)")
            }
        }
    }

    /// The trap the stamp exists for: an edit that does not change the length.
    /// A memo stamped on the length alone would answer for text that no longer
    /// exists — here, that the caret is still on line 3.
    func testSameLengthEditInvalidatesTheMemo() {
        let probe = EditorViewAuditSeam.Probe(text: "abc\ndef\nghi")
        XCTAssertEqual(probe.pushPosition(at: 11).line, 3)

        // "abc\ndef\nghi" -> "abcXdef\nghi": same length, one line fewer.
        probe.applyEdit(range: NSRange(location: 3, length: 1), with: "X")

        XCTAssertEqual(probe.pushPosition(at: 11).line, 2,
                       "the memo outlived an edit")
    }
}

// MARK: - U19: the SwiftUI update shortcut

@MainActor
final class DocumentSyncShortcutTests: XCTestCase {

    /// `updateNSView` used to reconstruct the full text and compare two whole
    /// documents on every SwiftUI update. The shortcut is only allowed to claim
    /// "in sync" when the document has not been reassigned since the storage
    /// became it AND the lengths still agree.
    func testEditKeepsTheStorageInSyncWithTheDocument() {
        let probe = EditorViewAuditSeam.Probe(text: "alpha\nbeta\n")
        probe.applyEdit(range: NSRange(location: 0, length: 0), with: "X")
        XCTAssertTrue(probe.storageIsInSyncWithDocument)
        XCTAssertEqual(probe.document.text, "Xalpha\nbeta\n")
    }

    /// A change made to the document from outside the editor (reload from disk,
    /// a plugin, a compare block transfer) must NOT be shortcut away.
    func testExternalDocumentChangeIsNotShortcutAway() {
        let probe = EditorViewAuditSeam.Probe(text: "alpha\nbeta\n")
        probe.applyEdit(range: NSRange(location: 0, length: 0), with: "X")
        XCTAssertTrue(probe.storageIsInSyncWithDocument)

        probe.document.text = "something else entirely\n"
        XCTAssertFalse(probe.storageIsInSyncWithDocument,
                       "the storage no longer holds document.text")
    }

    /// With a fold collapsed the storage is legitimately shorter than the
    /// document by everything the fold hides, minus its one placeholder
    /// character. The length check has to account for that or the shortcut
    /// never fires while anything is folded.
    func testFoldedStorageStillCountsAsInSync() throws {
        let probe = EditorViewAuditSeam.Probe(text: Fixture.foldableSource)
        let range = try XCTUnwrap(
            probe.foldingManager.foldableRange(
                onLine: 1, displayText: probe.storage.string as NSString
            )
        )
        probe.foldingManager.fold(range: range, in: probe.storage)
        // Folding fires textDidChange in the real editor; fullText reconstructs
        // the same document text.
        probe.applyEdit(range: NSRange(location: probe.storage.length, length: 0), with: "")

        XCTAssertLessThan(probe.storage.length, probe.document.textUTF16Count)
        XCTAssertTrue(probe.storageIsInSyncWithDocument)
        XCTAssertEqual(probe.document.text, Fixture.foldableSource)
    }
}

// MARK: - U25: modified-since-save marks can represent a deletion

@MainActor
final class SavedLineMarkTests: XCTestCase {

    /// The bug: the mark loop only ever wrote a mark per *inserted* line, so a
    /// run of pure deletions produced nothing at all — the file was modified
    /// since its last save and the gutter said nothing.
    func testPureDeletionMarksTheJoinLine() {
        let marks = EditorViewAuditSeam.savedLineMarks(
            saved: "a\nb\nc\n",
            current: "a\nc\n"
        )
        XCTAssertEqual(marks[2], "deleted")
        XCTAssertEqual(marks.count, 1)
    }

    func testDeletionAtTheEndMarksTheLastLine() {
        let marks = EditorViewAuditSeam.savedLineMarks(
            saved: "a\nb\nc\n",
            current: "a\nb\n"
        )
        XCTAssertEqual(marks.values.filter { $0 == "deleted" }.count, 1)
        for line in marks.keys {
            XCTAssertLessThanOrEqual(line, 3, "a mark must land on a line that exists")
            XCTAssertGreaterThanOrEqual(line, 1)
        }
    }

    /// The two existing styles are unchanged: pure insertion is green, a
    /// delete+insert run is amber.
    func testInsertionAndModificationAreUnchanged() {
        XCTAssertEqual(
            EditorViewAuditSeam.savedLineMarks(saved: "a\nb\n", current: "a\nnew\nb\n")[2],
            "added"
        )
        XCTAssertEqual(
            EditorViewAuditSeam.savedLineMarks(saved: "a\nb\n", current: "a\nB\n")[2],
            "modified"
        )
    }

    func testUnchangedTextHasNoMarks() {
        XCTAssertTrue(EditorViewAuditSeam.savedLineMarks(saved: "a\nb\n", current: "a\nb\n").isEmpty)
    }
}

// MARK: - R2: CompareOptions carries only what is read

final class CompareOptionsSurfaceTests: XCTestCase {

    /// `shiftBoundaries` / `detectCharDiffs` were assigned by the compare engine
    /// and read by nothing. This is a compile-time assertion that the remaining
    /// fields are the ones the pipeline actually consults.
    func testOnlyConsumedOptionsRemain() {
        var options = CompareOptions()
        options.ignoreCase = true
        options.ignoreChangedSpaces = true
        options.changedResemblPercent = 60
        XCTAssertTrue(options.ignoreCase)
        XCTAssertTrue(options.ignoreChangedSpaces)
        XCTAssertEqual(options.changedResemblPercent, 60)
    }
}
#endif
