//
//  TextViewAudit2FixTests.swift
//  Round-2 audit: T4, T6, H3, C5, TP1, TP2, CP4.
//
//  Each of these failed before its fix; the reproductions are in the batch
//  report. Everything here is wrong-output or a behaviour contract a perf change
//  had to keep — the perf numbers themselves live in
//  PerfHarnessAudit2TextViewTests.
//

import AppKit
import XCTest
@testable import SheepText

@MainActor
final class TextViewAudit2FixTests: XCTestCase {

    // MARK: - Fixtures

    private struct Fixture {
        let window: NSWindow
        let scrollView: NSScrollView
        let view: EditorTextView
        let storage: NSTextStorage
        let layoutManager: NSLayoutManager
        let container: NSTextContainer
        let document: Document
    }

    /// A manual TextKit 1 stack inside a real scroll view and window, so
    /// `visibleRect`, glyph ranges and line fragments are all real.
    private func makeEditor(_ text: String, height: CGFloat = 400) -> Fixture {
        let storage = NSTextStorage()
        let layoutManager = DiffLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 600, height: height),
                                  textContainer: container)
        layoutManager.ownerTextView = view
        view.isRichText = false
        view.allowsUndo = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width]
        view.string = text

        let document = Document(url: nil, initialText: text, encoding: .utf8, hasBOM: false)
        view.document = document

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: height))
        scrollView.hasVerticalScroller = true
        scrollView.documentView = view

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scrollView
        window.makeFirstResponder(view)
        layoutManager.ensureLayout(for: container)
        view.setFrameOrigin(.zero)
        scrollView.layoutSubtreeIfNeeded()
        return Fixture(window: window, scrollView: scrollView, view: view, storage: storage,
                       layoutManager: layoutManager, container: container, document: document)
    }

    // MARK: - T4: Go to Line agrees with the gutter

    /// `rangeOfCharacter(from: .newlines)` returns one UTF-16 unit at a time and
    /// does not fold a CRLF pair into one match, so every line counted twice on a
    /// Windows file and ⌘L / a Find-in-Files click landed around line N/2.
    func testGoToLineMatchesTheGuttersLineNumbersOnEveryLineEnding() {
        let bodies = [
            "LF": (1...12).map { "line \($0)" }.joined(separator: "\n"),
            "CRLF": (1...12).map { "line \($0)" }.joined(separator: "\r\n"),
            "lone CR": (1...12).map { "line \($0)" }.joined(separator: "\r"),
            "mixed": "a\r\nb\rc\nd\r\ne",
            "form feed": "a\nb\u{000C}c\nd\ne"
        ]
        for (name, body) in bodies {
            let f = makeEditor(body)
            let ns = f.storage.string as NSString
            for line in 1...14 {
                f.view.goToLine(line)
                XCTAssertEqual(f.view.selectedRange().location,
                               TextLineIndex.lineStart(of: line, in: ns),
                               "\(name): line \(line) landed somewhere else than the gutter's row")
            }
        }
    }

    /// The point of the fix, stated as the user sees it: the same body with LF
    /// and with CRLF puts the caret on the same TEXT.
    func testGoToLinePutsTheCaretOnTheSameTextWhateverTheLineEnding() {
        let lf = makeEditor((1...12).map { "line \($0)" }.joined(separator: "\n"))
        let crlf = makeEditor((1...12).map { "line \($0)" }.joined(separator: "\r\n"))
        for line in 1...12 {
            lf.view.goToLine(line)
            crlf.view.goToLine(line)
            let a = Self.rowText(in: lf.storage.string as NSString, from: lf.view.selectedRange().location)
            let b = Self.rowText(in: crlf.storage.string as NSString, from: crlf.view.selectedRange().location)
            XCTAssertEqual(a, b, "line \(line)")
        }
    }

    /// Characters from `start` up to the next line break, whatever it is.
    private nonisolated static func rowText(in ns: NSString, from start: Int) -> String {
        var end = start
        while end < ns.length {
            let unit = ns.character(at: end)
            if unit == 0x0A || unit == 0x0D { break }
            end += 1
        }
        return ns.substring(with: NSRange(location: start, length: end - start))
    }

    func testGoToLinePastTheEndClampsToTheEnd() {
        let f = makeEditor("a\nb\nc")
        f.view.goToLine(99)
        XCTAssertEqual(f.view.selectedRange().location, f.storage.length)
        f.view.goToLine(0)   // refused, caret unmoved
        XCTAssertEqual(f.view.selectedRange().location, f.storage.length)
    }

    // MARK: - T6: the line memo survives a storage swap

    private func reportedLine(_ view: EditorTextView, at location: Int) -> Int {
        var line = -1
        let token = NotificationCenter.default.addObserver(
            forName: EditorTextView.selectionDidChange, object: view, queue: nil
        ) { note in line = (note.userInfo?["line"] as? Int) ?? -1 }
        defer { NotificationCenter.default.removeObserver(token) }
        view.setSelectedRange(NSRange(location: location, length: 0))
        return line
    }

    /// A tab switch replaces the text through `textView.string = …`: the same
    /// NSTextStorage object, here the same length, and no
    /// `NSText.didChangeNotification`. The memo's stamp did not move, so the
    /// line numbers came from the previous document's newlines.
    func testTheLineMemoIsDroppedWhenTheStorageIsReplacedWithEqualLengthText() {
        let a = "aaaa\nbbbb\ncccc\ndddd\n"
        let b = "aa\nbb\ncc\ndd\nee\nffff\n"
        XCTAssertEqual((a as NSString).length, (b as NSString).length, "fixture lengths must match")

        let f = makeEditor(a)
        let near = (a as NSString).length - 2
        XCTAssertEqual(reportedLine(f.view, at: near),
                       TextLineIndex.lineNumber(in: a as NSString, at: near))

        f.view.string = b
        XCTAssertEqual(reportedLine(f.view, at: near),
                       TextLineIndex.lineNumber(in: b as NSString, at: near),
                       "the memo outlived a storage swap of the same length")
    }

    // MARK: - H3: the Thai fallback survives an unchanged-font assignment

    /// `NSTextView.font =` writes `.font` over the whole storage whether or not
    /// the value differs, and the fallback was only restored `if fontChanged` —
    /// so a theme, appearance or language change stripped it for good.
    func testAnUnchangedFontAssignmentKeepsTheThaiFallback() {
        let preferences = AppPreferences()
        preferences.editorFontSize = 13
        let f = makeEditor("let x = 1\nภาษาไทย\n")
        f.view.preferences = preferences
        f.view.applyDocumentVisualSettings()
        f.view.applyThaiFontFallback()

        let thai = ("let x = 1\n" as NSString).length
        let before = f.storage.attribute(.font, at: thai, effectiveRange: nil) as? NSFont
        XCTAssertNotEqual(before?.fontName, f.view.font?.fontName, "fixture has no Thai fallback")

        f.view.applyDocumentVisualSettings()   // same size, so `fontChanged` is false

        let after = f.storage.attribute(.font, at: thai, effectiveRange: nil) as? NSFont
        XCTAssertEqual(after?.fontName, before?.fontName, "the Thai fallback was wiped")
        XCTAssertEqual(after?.pointSize, before?.pointSize)
        XCTAssertNil(f.storage.attribute(.kern, at: thai, effectiveRange: nil),
                     "the fallback's kern removal went with it")
    }

    /// The other half of the same guarantee: a size change still moves the
    /// fallback to the new size (this is what `fontChanged` was there for).
    func testASizeChangeStillMovesTheThaiFallbackToTheNewSize() {
        let preferences = AppPreferences()
        preferences.editorFontSize = 13
        let f = makeEditor("let x = 1\nภาษาไทย\n")
        f.view.preferences = preferences
        f.view.applyDocumentVisualSettings()
        f.view.applyThaiFontFallback()

        preferences.editorFontSize = 22
        f.view.applyDocumentVisualSettings()
        let thai = ("let x = 1\n" as NSString).length
        let after = f.storage.attribute(.font, at: thai, effectiveRange: nil) as? NSFont
        XCTAssertEqual(after?.pointSize, 22)
        XCTAssertNotEqual(after?.fontName, f.view.font?.fontName)
    }

    // MARK: - C5: compare rows are LF-only

    /// The row definition itself, against the pipeline's own reference
    /// (`CompareDisplayLines.forEachLine`), walking forwards and backwards.
    func testTheCompareRowCursorAgreesWithTheComparePipeline() {
        let samples = [
            "plain": "aaa\nbbb\nccc\n",
            "CRLF": "aaa\r\nbbb\r\nccc\r\n",
            "lone CR": "aaa\rbbb\nccc\n",
            "U+2028": "aaa\u{2028}bbb\nccc\n",
            "U+2029": "aaa\u{2029}bbb\nccc\n",
            "NEL": "aaa\u{0085}bbb\nccc\n",
            "CR only": "aaa\rbbb\rccc\r",
            "no trailing break": "aaa\nbbb"
        ]
        for (name, text) in samples {
            let ns = text as NSString
            // Reference: the row each offset belongs to, straight from the
            // pipeline's splitter.
            var expected = [Int](repeating: 0, count: ns.length + 1)
            var row = 0
            CompareDisplayLines.forEachLine(in: ns) { range in
                for offset in range.location..<NSMaxRange(range) { expected[offset] = row }
                row += 1
                return true
            }
            expected[ns.length] = max(0, row - 1)

            var cursor = TextLineIndex.LineFeedCursor()
            for offset in 0..<ns.length {
                XCTAssertEqual(cursor.lineNumber(in: ns, at: offset, stamp: 1) - 1, expected[offset],
                               "\(name): forward at \(offset)")
            }
            for offset in stride(from: ns.length - 1, through: 0, by: -1) {
                XCTAssertEqual(cursor.lineNumber(in: ns, at: offset, stamp: 1) - 1, expected[offset],
                               "\(name): backward at \(offset)")
            }
        }
    }

    private func makeCompareInfo(symbol: String, style: CompareLineStyle,
                                 realLine: Int?) -> CompareLineInfo {
        CompareLineInfo(realLineNumber: realLine, isFiller: false, gutterSymbol: symbol,
                        style: style, mappedLineNumber: nil, charHighlights: [])
    }

    /// End to end: a lone CR inside the first row used to shift every symbol,
    /// line number and transfer-arrow block below it by one row, so the arrow
    /// drawn beside a row copied a DIFFERENT block than the one clicked.
    func testTheCompareGuttersTransferArrowBelongsToTheRowItIsDrawnOn() {
        // Three LF rows; the first contains a lone CR, which TextKit treats as a
        // line break and the compare pipeline does not.
        let display = "aaa\rbbb\nccc\nddd\n"
        let f = makeEditor(display)
        let gutter = LineNumberRulerView(scrollView: f.scrollView, textView: f.view)
        gutter.frame = NSRect(x: 0, y: 0, width: 44, height: f.view.frame.height)
        gutter.compareLineInfos = [
            makeCompareInfo(symbol: "", style: .same, realLine: 1),
            makeCompareInfo(symbol: "+", style: .added, realLine: 2),
            makeCompareInfo(symbol: "", style: .same, realLine: 3)
        ]
        gutter.compareTransferPointsRight = true
        gutter.onCompareBlockTransfer = { _ in }

        guard let rep = gutter.bitmapImageRepForCachingDisplay(in: gutter.bounds) else {
            return XCTFail("no bitmap rep")
        }
        gutter.cacheDisplay(in: gutter.bounds, to: rep)

        XCTAssertEqual(gutter.transferArrowRowsForTesting, [NSRange(location: 1, length: 1)],
                       "the arrow was attributed to the wrong display row")
    }

    // MARK: - TP2: the fold-chevron cache may lag, but must come right

    func testFoldMarkersLagATextEditAndThenCatchUp() {
        let source = """
        func one() {
            let a = 1
        }
        let tail = 0
        """
        let f = makeEditor(source)
        let gutter = LineNumberRulerView(scrollView: f.scrollView, textView: f.view)
        let folding = FoldingManager()
        gutter.foldingManager = folding
        f.view.foldingManager = folding

        XCTAssertEqual(gutter.foldMarkersForTesting(documentID: f.document.id).foldable, [1])

        // Append a second block. The gutter is allowed to keep drawing the old
        // chevrons for a beat...
        f.view.setSelectedRange(NSRange(location: f.storage.length, length: 0))
        f.view.insertText("\nfunc two() {\n    let b = 2\n}\n",
                          replacementRange: NSRange(location: f.storage.length, length: 0))
        XCTAssertEqual(gutter.foldMarkersForTesting(documentID: f.document.id).foldable, [1],
                       "a keystroke paid for a whole-document brace scan")

        // ...but not for two.
        let settled = expectation(description: "debounced recompute")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(gutter.foldMarkersForTesting(documentID: f.document.id).foldable, [1, 5],
                       "the chevrons never caught up")
    }

    /// Folding is an interaction, not typing — it must not be debounced.
    func testFoldingRecomputesTheChevronsAtOnce() throws {
        let source = "func one() {\n    let a = 1\n}\nlet tail = 0\n"
        let f = makeEditor(source)
        let gutter = LineNumberRulerView(scrollView: f.scrollView, textView: f.view)
        let folding = FoldingManager()
        gutter.foldingManager = folding
        f.view.foldingManager = folding
        _ = gutter.foldMarkersForTesting(documentID: f.document.id)

        let range = try XCTUnwrap(folding.foldableRange(onLine: 1, displayText: f.storage.string as NSString))
        folding.fold(range: range, in: f.storage)

        XCTAssertEqual(gutter.foldMarkersForTesting(documentID: f.document.id).folded, [1],
                       "the fold chip's chevron was debounced")
    }

    // MARK: - TP1: a pinch keeps the top line without forcing layout

    private func topCharacter(_ f: Fixture) -> Int {
        let clip = f.scrollView.contentView
        let point = NSPoint(x: 0, y: clip.bounds.minY - f.view.textContainerOrigin.y + 1)
        let glyph = f.layoutManager.glyphIndex(for: point, in: f.container)
        return f.layoutManager.characterIndexForGlyph(at: glyph)
    }

    private func scroll(_ f: Fixture, toCharacter index: Int) {
        let glyph = f.layoutManager.glyphIndexForCharacter(at: index)
        let y = f.layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
            + f.view.textContainerOrigin.y
        f.scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        f.scrollView.reflectScrolledClipView(f.scrollView.contentView)
    }

    /// A pinch resolves its anchor ONCE, when the fingers come off, instead of
    /// on every 0.15 s tick — the tick's lookup forces layout of everything above
    /// the anchor. The user-visible contract is unchanged: the line the gesture
    /// started on is the line under the top edge when it ends.
    func testAPinchPutsTheStartingLineBackWhenTheGestureEnds() {
        let lines = (0..<400).map { String(format: "line %04d", $0) }
        let f = makeEditor(lines.joined(separator: "\n") + "\n")
        let preferences = AppPreferences()
        preferences.editorFontSize = 13
        f.view.preferences = preferences
        f.view.applyDocumentVisualSettings()
        f.layoutManager.ensureLayout(for: f.container)

        let anchor = 200 * 10
        scroll(f, toCharacter: anchor)
        XCTAssertEqual(topCharacter(f), anchor, "fixture did not scroll")

        f.view.beginPinchForTesting()
        for size in [14.0, 15.0, 16.0] {
            preferences.editorFontSize = size
            f.view.applyDocumentVisualSettings()
        }
        f.view.endPinchForTesting()
        f.layoutManager.ensureLayout(for: f.container)

        XCTAssertEqual(f.view.font?.pointSize, 16)
        XCTAssertEqual(topCharacter(f), anchor, "the pinch lost the line it started on")
    }

    /// And the ticks themselves must not resolve it: the anchor lookup is what
    /// forces the layout. Nothing else in this class can see that, so it is
    /// asserted the only way it shows from outside — the view does NOT stay
    /// anchored mid-gesture.
    func testAPinchTickDoesNotResolveTheAnchor() {
        let lines = (0..<400).map { String(format: "line %04d", $0) }
        let f = makeEditor(lines.joined(separator: "\n") + "\n")
        let preferences = AppPreferences()
        preferences.editorFontSize = 13
        f.view.preferences = preferences
        f.view.applyDocumentVisualSettings()
        f.layoutManager.ensureLayout(for: f.container)

        let anchor = 200 * 10
        scroll(f, toCharacter: anchor)
        let offsetBefore = f.scrollView.contentView.bounds.minY

        f.view.beginPinchForTesting()
        preferences.editorFontSize = 26
        f.view.applyDocumentVisualSettings()
        XCTAssertEqual(f.scrollView.contentView.bounds.minY, offsetBefore,
                       "a pinch tick re-anchored, which is the 0.5 s layout it exists to avoid")
        f.view.endPinchForTesting()
    }

    // MARK: - CP4: lineHighlights shift in place

    /// The in-place rewrite must agree with the old `compactMap` in all five
    /// overlap cases, in both directions.
    func testLineHighlightsShiftTheSameWayTheRebuildDid() {
        let text = String(repeating: "0123456789\n", count: 40)
        let f = makeEditor(text)
        guard let layoutManager = f.layoutManager as? DiffLayoutManager else {
            return XCTFail("not a DiffLayoutManager")
        }
        let color = NSColor.red

        func rows() -> [(range: NSRange, color: NSColor)] {
            (0..<40).map { (range: NSRange(location: $0 * 11, length: 11), color: color) }
        }

        // An insertion in the middle of row 20, a deletion spanning rows 5-7,
        // and an equal-length overwrite straddling row 30's boundary.
        let edits: [(NSRange, String)] = [
            (NSRange(location: 20 * 11 + 4, length: 0), "XY"),
            (NSRange(location: 5 * 11 + 3, length: 25), ""),
            (NSRange(location: 30 * 11 - 2, length: 5), "")
        ]

        for (range, replacement) in edits {
            layoutManager.lineHighlights = rows()
            let before = layoutManager.lineHighlights
            let delta = (replacement as NSString).length - range.length
            f.storage.replaceCharacters(in: range, with: replacement)

            let expected = Self.referenceShift(before, editedRange:
                                                NSRange(location: range.location,
                                                        length: (replacement as NSString).length),
                                               delta: delta)
            XCTAssertEqual(layoutManager.lineHighlights.map(\.range), expected.map(\.range),
                           "edit \(range) → \"\(replacement)\"")
            XCTAssertEqual(layoutManager.lineHighlights.map(\.range),
                           layoutManager.lineHighlights.map(\.range).sorted { $0.location < $1.location },
                           "the array must stay sorted — drawBackground binary-searches it")
            // Put the text back for the next case.
            f.view.string = text
        }
    }

    /// The pre-fix implementation, verbatim, as the oracle.
    private nonisolated static func referenceShift(
        _ items: [(range: NSRange, color: NSColor)],
        editedRange newCharRange: NSRange,
        delta: Int
    ) -> [(range: NSRange, color: NSColor)] {
        let editStart = newCharRange.location
        let oldEditEnd = editStart + (newCharRange.length - delta)
        return items.compactMap { item in
            let start = item.range.location
            let end = NSMaxRange(item.range)
            var loc = start
            var len = item.range.length
            if end <= editStart {
                return item
            } else if start >= oldEditEnd {
                loc += delta
            } else if start <= editStart && end >= oldEditEnd {
                len += delta
            } else if start < editStart {
                len = editStart - start
            } else if end > oldEditEnd {
                loc = editStart + newCharRange.length
                len = end - oldEditEnd
            } else {
                return nil
            }
            guard loc >= 0, len > 0 else { return nil }
            return (range: NSRange(location: loc, length: len), color: item.color)
        }
    }
}
