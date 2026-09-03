//
//  ViewportHighlightTests.swift
//  The apply layer: syntax colours are painted for the SCREEN, as temporary
//  attributes on the layout manager, and never written into the text storage.
//
//  What each group here pins down:
//   - cost: a paint covers the viewport plus a screen of margin, whatever the
//     file's size, and a scroll paints only the strip that came into view;
//   - ownership: the paint touches only the keys in
//     `HighlightStyleTable.ownedAttributeKeys`, so compare mode's
//     `.backgroundColor` temporary attributes and it can share one layout
//     manager, and entering compare mode leaves nothing of ours behind;
//   - separation: the storage carries base attributes only, so undo/redo cannot
//     restore a stale colour and a theme flip is a repaint, not a re-parse.
//

import AppKit
import XCTest
@testable import SheepText

#if DEBUG

@MainActor
private enum ViewportFixture {

    /// 2000 numbered lines, ~20 UTF-16 units each: two orders of magnitude more
    /// text than a 200 pt viewport can show.
    static let longSource: String = (0..<2000)
        .map { String(format: "line %04d aaaa bbbb", $0) }
        .joined(separator: "\n") + "\n"

    static let keyword = HighlightStyleTable.styleID(forCapture: "keyword")
    static let string = HighlightStyleTable.styleID(forCapture: "string")

    /// One run per line, so every painted character carries a token colour.
    static func runsForEveryLine(in text: String) -> [HighlightRun] {
        var runs: [HighlightRun] = []
        let ns = text as NSString
        var location = 0
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            if line.length > 1 {
                runs.append(HighlightRun(location: line.location, length: line.length - 1,
                                         style: runs.count.isMultiple(of: 2) ? keyword : string))
            }
            location = NSMaxRange(line)
        }
        return runs
    }
}

// MARK: - Cost: the screen, not the file

@MainActor
final class ViewportPaintCostTests: XCTestCase {

    func testAPaintCoversTheViewportAndItsMarginAndNotTheFile() throws {
        let probe = EditorViewAuditSeam.Probe(text: ViewportFixture.longSource)
        probe.setRuns(ViewportFixture.runsForEveryLine(in: ViewportFixture.longSource))

        let viewport = try XCTUnwrap(probe.viewportRange)
        let painted = probe.paintedCharacterCount()

        XCTAssertGreaterThan(painted, 0, "nothing was painted at all")
        XCTAssertEqual(painted, viewport.length,
                       "the paint must cover exactly the viewport range it asked for")
        XCTAssertLessThan(
            painted, probe.storage.length / 10,
            "a paint covered \(painted) of \(probe.storage.length) characters — that is the file, not the screen"
        )
    }

    /// The runs cover every line; only the ones on screen may end up painted.
    func testCharactersFarBelowTheViewportAreNotPainted() {
        let probe = EditorViewAuditSeam.Probe(text: ViewportFixture.longSource)
        probe.setRuns(ViewportFixture.runsForEveryLine(in: ViewportFixture.longSource))
        let colors = probe.paintedForegroundColors()
        XCTAssertNotNil(colors[0], "the first line is on screen and must be painted")
        XCTAssertNil(colors[colors.count - 2], "the last line is nowhere near the screen")
    }

    /// Scrolling paints the strip that came into view, not the viewport again.
    func testScrollingPaintsOnlyTheDelta() throws {
        let probe = EditorViewAuditSeam.Probe(text: ViewportFixture.longSource)
        probe.setRuns(ViewportFixture.runsForEveryLine(in: ViewportFixture.longSource))
        let firstPaint = EditorViewAuditSeam.lastPaintedCharacterCount
        XCTAssertGreaterThan(firstPaint, 0)

        probe.scroll(toY: 60)
        let delta = EditorViewAuditSeam.lastPaintedCharacterCount
        XCTAssertGreaterThan(delta, 0, "the strip that scrolled in was never painted")
        XCTAssertLessThan(delta, firstPaint / 2,
                          "a 60 pt scroll repainted \(delta) of \(firstPaint) characters")
    }

    /// A scroll back into what is already painted does nothing at all — the
    /// painted window is remembered, not recomputed.
    func testAScrollBackIntoThePaintedWindowPaintsNothing() {
        let probe = EditorViewAuditSeam.Probe(text: ViewportFixture.longSource)
        probe.setRuns(ViewportFixture.runsForEveryLine(in: ViewportFixture.longSource))
        probe.scroll(toY: 300)
        let paints = EditorViewAuditSeam.viewportPaintCount
        probe.scroll(toY: 260)
        XCTAssertEqual(EditorViewAuditSeam.viewportPaintCount, paints,
                       "scrolling back over painted text repainted it")
    }

    /// Scrolling to a region that was never painted still shows the right
    /// colours: the paint is driven by the runs, which describe the whole file.
    func testScrollingFarDownPaintsTheRightColoursThere() throws {
        let probe = EditorViewAuditSeam.Probe(text: ViewportFixture.longSource)
        let runs = ViewportFixture.runsForEveryLine(in: ViewportFixture.longSource)
        probe.setRuns(runs)
        probe.scroll(toY: 4000)

        let viewport = try XCTUnwrap(probe.viewportRange)
        let colors = probe.paintedForegroundColors()
        let middle = viewport.location + viewport.length / 2
        let expected = HighlightStyleTable.color(
            HighlightRunList.style(at: middle, in: runs), isDark: probe.isDark
        )
        if let expected {
            XCTAssertEqual(colors[middle], expected)
        } else {
            XCTAssertNotNil(colors[middle], "even unstyled characters get the base colour")
        }
    }
}

// MARK: - Ownership of temporary attributes

@MainActor
final class ViewportPaintOwnershipTests: XCTestCase {

    /// Compare mode paints word-level diffs as `.backgroundColor` temporary
    /// attributes on the SAME layout manager. The two must coexist: the syntax
    /// paint may only add and remove the keys it owns.
    func testThePaintLeavesForeignTemporaryAttributesAlone() throws {
        let probe = EditorViewAuditSeam.Probe(text: ViewportFixture.longSource)
        let layoutManager = try XCTUnwrap(probe.textView.layoutManager)
        let marked = NSRange(location: 0, length: 20)
        layoutManager.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow,
                                            forCharacterRange: marked)

        probe.setRuns(ViewportFixture.runsForEveryLine(in: ViewportFixture.longSource))
        probe.setRuns([])   // a second generation: clears everything it owns

        XCTAssertEqual(
            layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: 0,
                                             effectiveRange: nil) as? NSColor,
            NSColor.systemYellow,
            "the syntax paint removed a temporary attribute it does not own"
        )
    }

    /// Entering compare mode replaces the storage with filler-padded display
    /// text. Any foreground left painted would tint whatever now sits at those
    /// offsets — text from the other side of the diff, or a blank filler line.
    func testEnteringCompareModeLeavesNoStaleForegroundPaint() {
        let probe = EditorViewAuditSeam.Probe(text: ViewportFixture.longSource)
        probe.setRuns(ViewportFixture.runsForEveryLine(in: ViewportFixture.longSource))
        XCTAssertGreaterThan(probe.paintedCharacterCount(), 0)

        let peer = Document(url: nil, initialText: "other\n", encoding: .utf8, hasBOM: false)
        probe.setComparePeer(peer)

        XCTAssertEqual(probe.paintedCharacterCount(), 0,
                       "compare mode inherited the previous document's colours")
        XCTAssertTrue(probe.runs.isEmpty)
    }

    /// …and leaving compare mode paints again from a fresh pass.
    func testLeavingCompareModeRepaints() {
        let probe = EditorViewAuditSeam.Probe(text: ViewportFixture.longSource)
        let peer = Document(url: nil, initialText: "other\n", encoding: .utf8, hasBOM: false)
        probe.setComparePeer(peer)
        probe.setComparePeer(nil)
        probe.setRuns(ViewportFixture.runsForEveryLine(in: ViewportFixture.longSource))
        XCTAssertGreaterThan(probe.paintedCharacterCount(), 0)
    }

    /// A paint in compare mode is a no-op: compare panes are not syntax
    /// highlighted, and their display text is not the document's text at all.
    func testNothingIsPaintedWhileInCompareMode() {
        let probe = EditorViewAuditSeam.Probe(text: ViewportFixture.longSource)
        let peer = Document(url: nil, initialText: "other\n", encoding: .utf8, hasBOM: false)
        probe.setComparePeer(peer)
        probe.setRuns(ViewportFixture.runsForEveryLine(in: ViewportFixture.longSource))
        XCTAssertEqual(probe.paintedCharacterCount(), 0)
    }
}

// MARK: - Separation from the text storage

@MainActor
final class ViewportPaintStorageTests: XCTestCase {

    /// Undo works on the text storage. Since no syntax colour is ever written
    /// there, undo and redo cannot restore one — the failure mode of every
    /// editor that colours by mutating its storage.
    func testUndoAndRedoNeverSeeAHighlight() throws {
        let probe = EditorViewAuditSeam.Probe(text: "let value = 1\nlet other = 2\n")
        probe.textView.allowsUndo = true
        probe.textView.typingAttributes = probe.baseAttributes
        probe.setRuns([HighlightRun(location: 0, length: 3, style: ViewportFixture.keyword)])

        // Every colour any token style can produce, in both appearances. None of
        // them may ever appear in the storage — that is the whole invariant.
        let tokenColors: Set<NSColor> = Set(
            HighlightStyleTable.styles.indices.flatMap { index -> [NSColor] in
                [true, false].compactMap {
                    HighlightStyleTable.color(HighlightStyleID(index), isDark: $0)
                }
            }
        )
        XCTAssertFalse(tokenColors.isEmpty)
        func storageColorsAreBaseOnly() -> Bool {
            (0..<probe.storage.length).allSatisfy { index in
                guard let color = probe.storage.attribute(.foregroundColor, at: index,
                                                          effectiveRange: nil) as? NSColor
                else { return true }
                return !tokenColors.contains(color)
            }
        }

        XCTAssertTrue(storageColorsAreBaseOnly())
        XCTAssertNotNil(probe.paintedForegroundColors()[0],
                        "nothing was painted — the test would pass vacuously")

        probe.textView.setSelectedRange(NSRange(location: 0, length: 0))
        probe.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(storageColorsAreBaseOnly(), "typing wrote a colour into the storage")

        probe.textView.undoManager?.undo()
        XCTAssertTrue(storageColorsAreBaseOnly(), "undo restored a colour into the storage")
        probe.textView.undoManager?.redo()
        XCTAssertTrue(storageColorsAreBaseOnly(), "redo restored a colour into the storage")
    }

    /// An edit moves the text under the runs. They are shifted with it, so the
    /// viewport stays right through the rehighlight debounce — which is a
    /// third of a second on a large file.
    func testAnEditShiftsTheRunsWithTheText() {
        let probe = EditorViewAuditSeam.Probe(text: "let value = 1\nlet other = 2\n")
        let keywordRange = NSRange(location: 14, length: 3)   // the second "let"
        probe.setRuns([HighlightRun(range: keywordRange, style: ViewportFixture.keyword)])

        probe.applyEdit(range: NSRange(location: 0, length: 0), with: "abc")

        XCTAssertEqual(probe.runs, [HighlightRun(location: 17, length: 3, style: ViewportFixture.keyword)])
        let expected = HighlightStyleTable.color(ViewportFixture.keyword, isDark: probe.isDark)
        XCTAssertEqual(probe.paintedForegroundColors()[17], expected,
                       "the colour did not move with the text")
    }
}

// MARK: - End to end

@MainActor
final class ViewportEndToEndTests: XCTestCase {

    /// The whole chain, with a real grammar: `applyHighlight` → the engine's
    /// worker queue → a run list → the viewport paint. What the user sees is
    /// the temporary attributes at the end of it.
    func testARealHighlightPassEndsUpPaintedOnScreen() throws {
        let source = String(
            repeating: "func value(_ input: Int) -> Int { return input * 2 }\n", count: 400
        )
        let probe = EditorViewAuditSeam.Probe(text: source, language: "swift")
        probe.applyHighlightNow()

        // The engine answers on the main queue; spin until it does.
        let deadline = Date().addingTimeInterval(10)
        while probe.runs.isEmpty, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertFalse(probe.runs.isEmpty, "the engine produced no runs for Swift")

        let ns = probe.storage.string as NSString
        let keyword = ns.range(of: "func")
        let expected = HighlightStyleTable.color(
            HighlightRunList.style(at: keyword.location, in: probe.runs), isDark: probe.isDark
        )
        XCTAssertNotNil(expected, "`func` did not resolve to a token style")
        XCTAssertEqual(probe.paintedForegroundColors()[keyword.location], expected,
                       "the run list never reached the screen")

        // …and only the screen: the run list covers all 400 lines.
        XCTAssertLessThan(probe.paintedCharacterCount(), probe.storage.length / 4)
        XCTAssertGreaterThan(probe.runs.count, 400, "the runs must cover the whole file")
    }
}

// MARK: - Appearance

@MainActor
final class ViewportAppearanceTests: XCTestCase {

    /// A theme flip re-resolves the palette and repaints what is on screen. It
    /// must not reach the engine: runs carry style ids, not colours.
    func testAnAppearanceChangeRepaintsWithoutReparsing() {
        let probe = EditorViewAuditSeam.Probe(text: "let value = 1\n", language: "swift")
        probe.textView.appearance = NSAppearance(named: .aqua)
        probe.setRuns([HighlightRun(location: 0, length: 3, style: ViewportFixture.keyword)])
        let light = probe.paintedForegroundColors()[0]

        SyntaxEngine.resetHighlightPassCountForTesting()
        probe.textView.appearance = NSAppearance(named: .darkAqua)
        probe.applyEditorAppearance()
        probe.paintViewport()
        let dark = probe.paintedForegroundColors()[0]

        XCTAssertNotNil(light)
        XCTAssertNotNil(dark)
        XCTAssertNotEqual(light, dark, "the repaint did not pick up the new palette")
        XCTAssertEqual(SyntaxEngine.highlightPassCount, 0,
                       "an appearance change re-parsed the document")
    }

    /// The cached runs survive a theme change, which is what lets the repaint
    /// above happen with no engine call at all. This used to `removeAll()` the
    /// cache, so every open document was re-parsed on every ⌘-Tab that changed
    /// the appearance.
    func testTheRunCacheSurvivesAnAppearanceChange() {
        let probe = EditorViewAuditSeam.Probe(text: "let value = 1\n", language: "swift")
        EditorViewAuditSeam.clearHighlightCache()
        EditorViewAuditSeam.storeHighlight(for: probe.document)
        XCTAssertTrue(EditorViewAuditSeam.highlightCacheContains(probe.document.id))

        probe.invalidateHighlightingAfterExternalChange(force: true)

        XCTAssertTrue(EditorViewAuditSeam.highlightCacheContains(probe.document.id),
                      "a theme change threw away runs that are appearance-independent")
    }
}

#endif

