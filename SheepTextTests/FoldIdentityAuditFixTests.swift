//
//  FoldIdentityAuditFixTests.swift
//  Round-2 audit: T1 / T2 / T3 / T5 — a collapsed fold must never cost the user
//  the text behind it.
//
//  Every test here failed before the `.foldRegionID` redesign. The three data
//  loss shapes they pin are:
//
//    T1  a grouped edit (Replace All, multi-cursor typing, ⇧⌘D, ⇧⌘K) arrives as
//        ONE coalesced notification spanning every sub-edit, so offset
//        arithmetic wrote off every fold lying between the first cursor and the
//        last;
//    T2  a whole-document transform (trim on save, line endings, indentation,
//        sort) reads the DISPLAY string, so it replaced the storage — U+FFFC
//        included — and the folded blocks went with it;
//    T3  ⌘Z after deleting a chip put the placeholder back with nothing behind
//        it.
//
//  In all three the placeholder survived into `document.text`, i.e. into the
//  draft and onto disk.
//

import AppKit
import XCTest
@testable import SheepText

@MainActor
final class FoldIdentityAuditFixTests: XCTestCase {

    // MARK: - Fixtures

    /// An UndoManager the text view will actually use. `NSTextView` outside a
    /// window has none of its own.
    @MainActor
    private final class UndoDelegate: NSObject, NSTextViewDelegate {
        let manager = UndoManager()
        func undoManager(for view: NSTextView) -> UndoManager? { manager }
    }

    private struct Fixture {
        let window: NSWindow
        let view: EditorTextView
        let storage: NSTextStorage
        let document: Document
        let folding: FoldingManager
        let undo: UndoDelegate
    }

    /// A manual TextKit 1 stack, exactly like `EditorView.makeNSView`.
    private func makeEditor(_ text: String) -> Fixture {
        let storage = NSTextStorage()
        let layoutManager = DiffLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400),
                                  textContainer: container)
        layoutManager.ownerTextView = view
        view.isRichText = false
        view.allowsUndo = true
        view.smartInsertDeleteEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.string = text

        let document = Document(url: nil, initialText: text, encoding: .utf8, hasBOM: false)
        view.document = document
        let folding = FoldingManager()
        view.foldingManager = folding
        let undo = UndoDelegate()
        view.delegate = undo

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        return Fixture(window: window, view: view, storage: storage,
                       document: document, folding: folding, undo: undo)
    }

    @discardableResult
    private func fold(_ f: Fixture, onLine line: Int) throws -> Int {
        let range = try XCTUnwrap(
            f.folding.foldableRange(onLine: line, displayText: f.storage.string as NSString),
            "fixture is not foldable on line \(line) — the test would pass vacuously"
        )
        f.folding.fold(range: range, in: f.storage)
        return range.location
    }

    private func assertNoPlaceholder(_ text: String, _ message: String = "",
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(text.unicodeScalars.contains { $0.value == 0xFFFC },
                       "text still contains U+FFFC. \(message)", file: file, line: line)
    }

    /// Two brace blocks with a line of prose between them, and `target` both
    /// above and below every fold — the audit's own repro shape.
    private func twoBlockSource(ending: String = "\n") -> String {
        [
            "let target = 0",
            "func one() {",
            "    let a = 1",
            "}",
            "// middle target",
            "func two() {",
            "    let b = 2",
            "}",
            "let target = 3",
            ""
        ].joined(separator: ending)
    }

    // MARK: - T1: grouped edits

    /// The exact `else` branch the arithmetic used to take: two sub-edits in one
    /// `beginEditing`/`endEditing` group, one above the placeholder and one
    /// below, neither of them anywhere near it.
    func testAGroupedEditStraddlingAFoldKeepsIt() throws {
        try assertStraddlingGroupKeepsTheFold(ending: "\n")
    }

    func testAGroupedEditStraddlingAFoldKeepsItOnCRLF() throws {
        try assertStraddlingGroupKeepsTheFold(ending: "\r\n")
    }

    private func assertStraddlingGroupKeepsTheFold(ending: String,
                                                   file: StaticString = #filePath,
                                                   line: UInt = #line) throws {
        let src = twoBlockSource(ending: ending)
        let f = makeEditor(src)
        try fold(f, onLine: 2)
        XCTAssertEqual(f.folding.regions.count, 1, file: file, line: line)

        let ns = f.storage.string as NSString
        let below = ns.range(of: "let target = 3")
        let above = ns.range(of: "let target = 0")
        f.storage.beginEditing()
        f.storage.replaceCharacters(in: below, with: "let TARGET = 3")
        f.storage.replaceCharacters(in: above, with: "let TARGET = 0")
        f.storage.endEditing()

        XCTAssertEqual(f.folding.regions.count, 1,
                       "the fold was dropped although nothing touched its placeholder",
                       file: file, line: line)
        let rebuilt = f.folding.fullText(from: f.storage)
        assertNoPlaceholder(rebuilt, file: file, line: line)
        XCTAssertEqual(rebuilt,
                       src.replacingOccurrences(of: "let target = 3", with: "let TARGET = 3")
                          .replacingOccurrences(of: "let target = 0", with: "let TARGET = 0"),
                       file: file, line: line)
    }

    /// Find bar → Replace All. One `shouldChangeText(inRanges:)`, one storage
    /// group, one coalesced notification.
    func testReplaceAllAcrossAFoldKeepsTheFoldedBlock() throws {
        let src = twoBlockSource()
        let f = makeEditor(src)
        try fold(f, onLine: 2)

        let ns = f.storage.string as NSString
        var ranges: [NSRange] = []
        var search = NSRange(location: 0, length: ns.length)
        while true {
            let hit = ns.range(of: "target", options: [], range: search)
            guard hit.location != NSNotFound else { break }
            ranges.append(hit)
            search = NSRange(location: NSMaxRange(hit), length: ns.length - NSMaxRange(hit))
        }
        XCTAssertGreaterThanOrEqual(ranges.count, 3, "fixture needs matches either side of the fold")

        XCTAssertEqual(f.view.replaceOccurrences(ranges, with: "TARGET"), ranges.count)

        XCTAssertEqual(f.folding.regions.count, 1, "Replace All destroyed the fold")
        let rebuilt = f.folding.fullText(from: f.storage)
        assertNoPlaceholder(rebuilt)
        XCTAssertEqual(rebuilt, src.replacingOccurrences(of: "target", with: "TARGET"))
    }

    /// ⌘D twice, then type: `insertText(_:atRanges:)`, one storage group.
    func testMultiCursorTypingAcrossAFoldKeepsTheFoldedBlock() throws {
        let src = twoBlockSource()
        let f = makeEditor(src)
        try fold(f, onLine: 2)

        let ns = f.storage.string as NSString
        let above = ns.range(of: "let target = 0")
        let below = ns.range(of: "let target = 3")
        f.view.setSelectedRanges([NSValue(range: above), NSValue(range: below)],
                                 affinity: .downstream, stillSelecting: false)
        f.view.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(f.folding.regions.count, 1, "multi-cursor typing destroyed the fold")
        let rebuilt = f.folding.fullText(from: f.storage)
        assertNoPlaceholder(rebuilt)
        XCTAssertEqual(rebuilt,
                       src.replacingOccurrences(of: "let target = 0", with: "X")
                          .replacingOccurrences(of: "let target = 3", with: "X"))
    }

    /// ⇧⌘K with cursors on lines either side of the fold.
    func testDeleteCurrentLinesAcrossAFoldKeepsTheFoldedBlock() throws {
        let src = twoBlockSource()
        let f = makeEditor(src)
        try fold(f, onLine: 2)

        let ns = f.storage.string as NSString
        let above = ns.range(of: "let target = 0")
        let below = ns.range(of: "let target = 3")
        f.view.setSelectedRanges([NSValue(range: above), NSValue(range: below)],
                                 affinity: .downstream, stillSelecting: false)
        f.view.deleteCurrentLines()

        XCTAssertEqual(f.folding.regions.count, 1, "⇧⌘K destroyed the fold")
        let rebuilt = f.folding.fullText(from: f.storage)
        assertNoPlaceholder(rebuilt)
        XCTAssertTrue(rebuilt.contains("let a = 1"), "the folded body is gone")
    }

    /// ⇧⌘D with cursors on lines either side of the fold.
    func testDuplicateCurrentLinesAcrossAFoldKeepsTheFoldedBlock() throws {
        let src = twoBlockSource()
        let f = makeEditor(src)
        try fold(f, onLine: 2)

        let ns = f.storage.string as NSString
        let above = ns.range(of: "let target = 0")
        let below = ns.range(of: "let target = 3")
        f.view.setSelectedRanges([NSValue(range: above), NSValue(range: below)],
                                 affinity: .downstream, stillSelecting: false)
        f.view.duplicateCurrentLines()

        XCTAssertEqual(f.folding.regions.count, 1, "⇧⌘D destroyed the fold")
        let rebuilt = f.folding.fullText(from: f.storage)
        assertNoPlaceholder(rebuilt)
        XCTAssertTrue(rebuilt.contains("let a = 1"), "the folded body is gone")
    }

    func testTwoFoldsAndAGroupedEditSpanningBothKeepBoth() throws {
        let src = twoBlockSource()
        let f = makeEditor(src)
        // Fold the second block first so the first block's offsets stay valid.
        try fold(f, onLine: 6)
        try fold(f, onLine: 2)
        XCTAssertEqual(f.folding.regions.count, 2)

        let ns = f.storage.string as NSString
        let below = ns.range(of: "let target = 3")
        let above = ns.range(of: "let target = 0")
        f.storage.beginEditing()
        f.storage.replaceCharacters(in: below, with: "Z")
        f.storage.replaceCharacters(in: above, with: "Y")
        f.storage.endEditing()

        XCTAssertEqual(f.folding.regions.count, 2, "a group spanning both folds ate them")
        let rebuilt = f.folding.fullText(from: f.storage)
        assertNoPlaceholder(rebuilt)
        XCTAssertEqual(rebuilt,
                       src.replacingOccurrences(of: "let target = 0", with: "Y")
                          .replacingOccurrences(of: "let target = 3", with: "Z"))
    }

    /// The other half of the same rule: a group that really does delete one
    /// placeholder must drop that region and only that one.
    func testAGroupedEditThatDeletesOneFoldKeepsTheOther() throws {
        let f = makeEditor(twoBlockSource())
        try fold(f, onLine: 6)
        try fold(f, onLine: 2)
        let first = try XCTUnwrap(f.folding.regions.first)
        let second = try XCTUnwrap(f.folding.regions.last)
        let secondID = second.id

        let tail = (f.storage.string as NSString).range(of: "let target = 3")
        f.storage.beginEditing()
        f.storage.replaceCharacters(in: tail, with: "Z")
        f.storage.replaceCharacters(in: first.displayRange, with: "")
        f.storage.endEditing()

        XCTAssertEqual(f.folding.regions.count, 1, "the surviving fold went with the deleted one")
        XCTAssertEqual(f.folding.regions.first?.id, secondID)
        let rebuilt = f.folding.fullText(from: f.storage)
        assertNoPlaceholder(rebuilt)
        XCTAssertFalse(rebuilt.contains("let a = 1"), "the deleted block came back")
        XCTAssertTrue(rebuilt.contains("let b = 2"), "the surviving block is gone")
    }

    /// Folding an outer block over a collapsed inner one used to capture the
    /// DISPLAY substring, so the outer region's text carried the inner chip's
    /// U+FFFC — and `fullText` spliced that into `document.text` and onto disk.
    /// Folding over an inner fold now dissolves it into the outer block.
    func testFoldingOverACollapsedFoldKeepsTheInnerBlocksText() throws {
        let src = """
        let target = 0
        func outer() {
            if x {
                inner()
            }
            done()
        }
        let target = 9
        """
        let f = makeEditor(src)
        let ns = f.storage.string as NSString
        // Inner block first, then the outer one which now contains its chip.
        let inner = try XCTUnwrap(f.folding.foldableRange(onLine: 3, displayText: ns))
        f.folding.fold(range: inner, in: f.storage)
        let outer = try XCTUnwrap(
            f.folding.foldableRange(onLine: 2, displayText: f.storage.string as NSString)
        )
        f.folding.fold(range: outer, in: f.storage)
        XCTAssertEqual(f.folding.regions.count, 1,
                       "the inner fold must be absorbed, not left pointing into hidden text")

        let live = f.storage.string as NSString
        let below = live.range(of: "let target = 9")
        let above = live.range(of: "let target = 0")
        f.storage.beginEditing()
        f.storage.replaceCharacters(in: below, with: "let TARGET = 9")
        f.storage.replaceCharacters(in: above, with: "let TARGET = 0")
        f.storage.endEditing()

        let rebuilt = f.folding.fullText(from: f.storage)
        assertNoPlaceholder(rebuilt)
        XCTAssertEqual(rebuilt, src.replacingOccurrences(of: "let target", with: "let TARGET"))
    }

    // MARK: - T2: whole-document transforms

    func testTrimTrailingWhitespaceKeepsTheFoldedBlock() throws {
        let src = "alpha   \nfunc one() {\n    let a = 1\n}\nomega   \n"
        let f = makeEditor(src)
        try fold(f, onLine: 2)

        f.view.trimTrailingWhitespace()

        let rebuilt = f.folding.fullText(from: f.storage)
        assertNoPlaceholder(rebuilt)
        XCTAssertEqual(rebuilt, "alpha\nfunc one() {\n    let a = 1\n}\nomega\n")
        assertNoPlaceholder(f.storage.string, "the transform left a placeholder in the storage")
    }

    func testConvertLineEndingsKeepsTheFoldedBlock() throws {
        let src = "alpha\nfunc one() {\n    let a = 1\n}\nomega\n"
        let f = makeEditor(src)
        try fold(f, onLine: 2)

        f.view.convertLineEndings(to: .crlf)

        let rebuilt = f.folding.fullText(from: f.storage)
        assertNoPlaceholder(rebuilt)
        XCTAssertEqual(rebuilt, src.replacingOccurrences(of: "\n", with: "\r\n"))
    }

    func testConvertIndentationKeepsTheFoldedBlock() throws {
        let src = "alpha\nfunc one() {\n    let a = 1\n}\nomega\n"
        let f = makeEditor(src)
        try fold(f, onLine: 2)

        f.view.convertIndentation(to: .tabs)

        let rebuilt = f.folding.fullText(from: f.storage)
        assertNoPlaceholder(rebuilt)
        XCTAssertTrue(rebuilt.contains("\tlet a = 1"), "the folded body was not converted: \(rebuilt)")
    }

    func testSortLinesWithNoSelectionKeepsTheFoldedBlock() throws {
        let src = "zulu\nfunc one() {\n    let a = 1\n}\nalpha\n"
        let f = makeEditor(src)
        try fold(f, onLine: 2)

        f.view.setSelectedRange(NSRange(location: 0, length: 0))
        f.view.sortSelectedLines()

        let rebuilt = f.folding.fullText(from: f.storage)
        assertNoPlaceholder(rebuilt)
        XCTAssertTrue(rebuilt.contains("let a = 1"), "the folded body is gone: \(rebuilt)")
        assertNoPlaceholder(f.storage.string)
    }

    // MARK: - T3: undo

    func testUndoOfADeletedChipBringsTheFoldBack() throws {
        let src = "alpha\nfunc one() {\n    let a = 1\n}\nomega\n"
        let f = makeEditor(src)
        try fold(f, onLine: 2)
        let placeholder = try XCTUnwrap(f.folding.regions.first?.displayLocation)
        let id = try XCTUnwrap(f.folding.regions.first?.id)

        f.undo.manager.groupsByEvent = false
        f.undo.manager.beginUndoGrouping()
        let target = NSRange(location: placeholder, length: 1)
        XCTAssertTrue(f.view.shouldChangeText(in: target, replacementString: ""))
        f.storage.replaceCharacters(in: target, with: "")
        f.view.didChangeText()
        f.undo.manager.endUndoGrouping()

        XCTAssertTrue(f.folding.regions.isEmpty, "the chip is gone; the region must not be live")
        assertNoPlaceholder(f.folding.fullText(from: f.storage))

        XCTAssertTrue(f.undo.manager.canUndo)
        f.undo.manager.undo()

        XCTAssertEqual(f.folding.regions.count, 1, "the undo put a placeholder back with no fold behind it")
        XCTAssertEqual(f.folding.regions.first?.id, id)
        let rebuilt = f.folding.fullText(from: f.storage)
        assertNoPlaceholder(rebuilt)
        XCTAssertEqual(rebuilt, src)
    }

    func testRedoAfterThatUndoRemovesTheFoldAgain() throws {
        let src = "alpha\nfunc one() {\n    let a = 1\n}\nomega\n"
        let f = makeEditor(src)
        try fold(f, onLine: 2)
        let placeholder = try XCTUnwrap(f.folding.regions.first?.displayLocation)

        f.undo.manager.groupsByEvent = false
        f.undo.manager.beginUndoGrouping()
        let target = NSRange(location: placeholder, length: 1)
        XCTAssertTrue(f.view.shouldChangeText(in: target, replacementString: ""))
        f.storage.replaceCharacters(in: target, with: "")
        f.view.didChangeText()
        f.undo.manager.endUndoGrouping()

        f.undo.manager.undo()
        XCTAssertEqual(f.folding.regions.count, 1)
        f.undo.manager.redo()

        XCTAssertTrue(f.folding.regions.isEmpty)
        let rebuilt = f.folding.fullText(from: f.storage)
        assertNoPlaceholder(rebuilt)
        XCTAssertEqual(rebuilt, "alpha\nfunc one() \nomega\n")
    }

    // MARK: - The safety net

    /// A placeholder whose identity was stripped (a whole-storage `setAttributes`
    /// REPLACES the dictionary) must still be re-seated, not written off.
    func testAPlaceholderThatLostItsIdentityIsStillReSeated() throws {
        let src = twoBlockSource()
        let f = makeEditor(src)
        try fold(f, onLine: 2)

        let placeholder = try XCTUnwrap(f.folding.regions.first?.displayLocation)
        f.storage.removeAttribute(.foldRegionID,
                                  range: NSRange(location: placeholder, length: 1))

        let ns = f.storage.string as NSString
        let below = ns.range(of: "let target = 3")
        let above = ns.range(of: "let target = 0")
        f.storage.beginEditing()
        f.storage.replaceCharacters(in: below, with: "Z")
        f.storage.replaceCharacters(in: above, with: "Y")
        f.storage.endEditing()

        XCTAssertEqual(f.folding.regions.count, 1, "the anonymous placeholder was written off")
        let rebuilt = f.folding.fullText(from: f.storage)
        assertNoPlaceholder(rebuilt)
        XCTAssertTrue(rebuilt.contains("let a = 1"))
    }

    /// `fullText` must never hand back a placeholder it could have resolved,
    /// whatever went wrong upstream. Here one chip is really deleted and another
    /// loses its identity in the same group, so the counts disagree and no
    /// re-seating is safe — the attachment object is the last thing that knows
    /// what the character stood for.
    func testFullTextResolvesAnOrphanPlaceholderFromTheAttachment() throws {
        let src = twoBlockSource()
        let f = makeEditor(src)
        try fold(f, onLine: 6)
        try fold(f, onLine: 2)
        XCTAssertEqual(f.folding.regions.count, 2)

        let first = try XCTUnwrap(f.folding.regions.first)
        let second = try XCTUnwrap(f.folding.regions.last)
        f.storage.removeAttribute(.foldRegionID, range: second.displayRange)

        f.storage.beginEditing()
        f.storage.replaceCharacters(in: (f.storage.string as NSString).range(of: "let target = 3"),
                                    with: "Z")
        f.storage.replaceCharacters(in: first.displayRange, with: "")
        f.storage.endEditing()

        XCTAssertTrue(f.folding.regions.isEmpty, "a mismatched count must not be re-seated by order")
        let rebuilt = f.folding.fullText(from: f.storage)
        assertNoPlaceholder(rebuilt, "the orphan was copied into document.text")
        XCTAssertTrue(rebuilt.contains("let b = 2"), "the orphan's block was dropped: \(rebuilt)")
    }

    /// A genuine object-replacement character in the user's own text is content,
    /// not a fold, and must come back out unchanged.
    func testAnUnrelatedObjectReplacementCharacterIsPreserved() throws {
        let src = "alpha \u{FFFC} beta\nfunc one() {\n    let a = 1\n}\nomega\n"
        let f = makeEditor(src)
        try fold(f, onLine: 2)

        let rebuilt = f.folding.fullText(from: f.storage)
        XCTAssertEqual(rebuilt, src)
    }

    // MARK: - T5: the restored block wears the current font

    func testUnfoldRestoresTheBlockAtTheCurrentFontSize() throws {
        let preferences = AppPreferences()
        preferences.editorFontSize = 13
        let src = "alpha\nfunc one() {\n    let a = 1\n}\nomega\n"
        let f = makeEditor(src)
        f.view.preferences = preferences
        f.view.applyDocumentVisualSettings()
        try fold(f, onLine: 2)

        preferences.editorFontSize = 24
        f.view.applyDocumentVisualSettings()

        let placeholder = try XCTUnwrap(f.folding.regions.first?.displayLocation)
        let restored = try XCTUnwrap(
            f.folding.unfold(at: placeholder, in: f.storage,
                             baseAttributes: f.view.editorBaseAttributes())
        )
        XCTAssertEqual(f.storage.string, src)

        f.storage.enumerateAttribute(.font, in: restored, options: []) { value, range, _ in
            XCTAssertEqual((value as? NSFont)?.pointSize, 24,
                           "restored text is still at the old size at \(range)")
        }
    }

    /// The chip itself used to be pinned at 13 pt, so its row kept 13 pt metrics
    /// in a 24 pt editor.
    func testTheFoldChipTakesTheRowsOwnFontSize() throws {
        let preferences = AppPreferences()
        preferences.editorFontSize = 24
        let f = makeEditor("alpha\nfunc one() {\n    let a = 1\n}\nomega\n")
        f.view.preferences = preferences
        f.view.applyDocumentVisualSettings()
        try fold(f, onLine: 2)

        let placeholder = try XCTUnwrap(f.folding.regions.first?.displayLocation)
        let font = f.storage.attribute(.font, at: placeholder, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, 24, "the fold chip is still hard-coded to 13 pt")
    }

    // MARK: - No second live placeholder for one fold

    /// ⇧⌘D on a chip's line used to copy the raw U+FFFC — a bare attachment
    /// character with no fold behind it, which then travelled into the file.
    func testDuplicatingAChipsLineExpandsTheBlockInstead() throws {
        let src = "alpha\nfunc one() {\n    let a = 1\n}\nomega\n"
        let f = makeEditor(src)
        try fold(f, onLine: 2)
        let placeholder = try XCTUnwrap(f.folding.regions.first?.displayLocation)

        f.view.setSelectedRange(NSRange(location: placeholder, length: 0))
        f.view.duplicateCurrentLines()

        assertNoPlaceholder(f.folding.fullText(from: f.storage))
        XCTAssertEqual(f.folding.regions.count, 1, "the original fold was lost")
        let rebuilt = f.folding.fullText(from: f.storage)
        XCTAssertEqual(rebuilt.components(separatedBy: "let a = 1").count - 1, 2,
                       "the duplicate did not carry the block: \(rebuilt)")
    }

    /// Dragging a selection out used AppKit's own pasteboard writer, which
    /// serialises the display text — placeholder and all.
    func testDragWriteSelectionExpandsFolds() throws {
        let src = "alpha\nfunc one() {\n    let a = 1\n}\nomega\n"
        let f = makeEditor(src)
        try fold(f, onLine: 2)

        f.view.setSelectedRange(NSRange(location: 0, length: f.storage.length))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("sheeptext.test.drag"))
        pasteboard.clearContents()
        XCTAssertTrue(f.view.writeSelection(to: pasteboard, types: [.string]))
        let written = try XCTUnwrap(pasteboard.string(forType: .string))
        assertNoPlaceholder(written)
        XCTAssertTrue(written.contains("let a = 1"))
    }

    // MARK: - Randomised: the model is the truth

    /// A few thousand random edits, single and grouped, against a naive model.
    ///
    /// The model is a shadow string in which each fold is one PRIVATE-USE
    /// character instead of U+FFFC, so it knows which fold is where without
    /// asking the manager. Every edit is applied to both; the expected full text
    /// is the shadow with each surviving sentinel replaced by its block. Fixed
    /// seed, so a failure is reproducible.
    func testRandomEditsAgreeWithANaiveModel() throws {
        var rng = SeededGenerator(seed: 0x5EED_1234)
        let alphabet = Array("abcXY \n\t{}")

        for trial in 0..<60 {
            let ending = (trial % 3 == 1) ? "\r\n" : "\n"
            var lines: [String] = []
            for block in 0..<4 {
                lines.append("head \(block)")
                lines.append("func f\(block)() {")
                lines.append("    body \(block)")
                lines.append("}")
            }
            lines.append("")
            let src = lines.joined(separator: ending)

            let storage = NSTextStorage(string: src)
            let folding = FoldingManager()

            // Fold a random subset, bottom-up so the earlier offsets stay valid.
            var foldedLines: [Int] = []
            for block in (0..<4).reversed() where rng.next(below: 3) != 0 {
                foldedLines.append(block * 4 + 2)
            }
            for line in foldedLines {
                guard let range = folding.foldableRange(onLine: line,
                                                        displayText: storage.string as NSString)
                else { continue }
                folding.fold(range: range, in: storage)
            }
            guard !folding.regions.isEmpty else { continue }

            // Build the shadow: same length, sentinels where the chips are.
            let shadow = NSMutableString(string: storage.string)
            var blocks: [unichar: String] = [:]
            for (index, region) in folding.regions.enumerated() {
                let sentinel = unichar(0xE000 + index)
                shadow.replaceCharacters(in: region.displayRange,
                                         with: String(utf16CodeUnits: [sentinel], count: 1))
                blocks[sentinel] = region.originalText
            }

            for step in 0..<50 {
                let subEdits = 1 + rng.next(below: 3)
                var ranges: [NSRange] = []
                var used = IndexSet()
                for _ in 0..<subEdits {
                    let length = storage.length
                    guard length > 0 else { break }
                    let location = rng.next(below: length)
                    let span = min(rng.next(below: 6), length - location)
                    let range = NSRange(location: location, length: span)
                    // Non-overlapping and non-abutting, so back-to-front
                    // application is well defined on both sides.
                    let padded = NSRange(location: max(0, location - 1), length: span + 2)
                    guard !used.intersects(integersIn: padded.location..<NSMaxRange(padded)) else { continue }
                    used.insert(integersIn: padded.location..<NSMaxRange(padded))
                    ranges.append(range)
                }
                guard !ranges.isEmpty else { continue }
                ranges.sort { $0.location < $1.location }
                let replacements = ranges.map { _ -> String in
                    String((0..<rng.next(below: 5)).map { _ in alphabet[rng.next(below: alphabet.count)] })
                }

                let grouped = ranges.count > 1 || rng.next(below: 2) == 0
                if grouped { storage.beginEditing() }
                for index in ranges.indices.reversed() {
                    storage.replaceCharacters(in: ranges[index], with: replacements[index])
                    shadow.replaceCharacters(in: ranges[index], with: replacements[index])
                }
                if grouped { storage.endEditing() }

                var expected = ""
                for unit in 0..<shadow.length {
                    let c = shadow.character(at: unit)
                    if let block = blocks[c] {
                        expected += block
                    } else {
                        expected += String(utf16CodeUnits: [c], count: 1)
                    }
                }

                let rebuilt = folding.fullText(from: storage)
                XCTAssertEqual(rebuilt, expected,
                               "trial \(trial) step \(step): full text diverged from the model")
                guard rebuilt == expected else { return }
            }
        }
    }
}

/// Deterministic xorshift, so a randomised failure is reproducible.
struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    /// Uniform-enough in `0..<bound`; 0 for a non-positive bound.
    mutating func next(below bound: Int) -> Int {
        guard bound > 0 else { return 0 }
        return Int(next() % UInt64(bound))
    }
}
