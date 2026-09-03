//
//  TextViewAuditFixTests.swift
//  Regression tests for the September 2026 EditorTextView audit fixes
//  (T3, T4, T7, T9, T10, T11, T12, T13, S10, U14, U15).
//
//  The test target does not set SWIFT_DEFAULT_ACTOR_ISOLATION, so a class that
//  touches AppKit or DocumentStore declares @MainActor itself.
//

import AppKit
import XCTest
@testable import SheepText

@MainActor
final class TextViewAuditFixTests: XCTestCase {

    // MARK: - Fixtures

    /// A view on a **manual TextKit 1 stack**, exactly like `EditorView.makeNSView`.
    /// `NSTextView(frame:)` alone builds a TextKit 2 stack on macOS 13+, whose
    /// `layoutManager` is nil — half of what is tested here needs it.
    private func makeEditor(
        _ text: String,
        width: CGFloat = 600
    ) -> (window: NSWindow, view: EditorTextView, document: Document, layoutManager: NSLayoutManager) {
        let storage = NSTextStorage()
        let layoutManager = DiffLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let view = EditorTextView(
            frame: NSRect(x: 0, y: 0, width: width, height: 400),
            textContainer: container
        )
        view.isRichText = false
        view.allowsUndo = true
        view.smartInsertDeleteEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.string = text

        // `EditorTextView.document` is weak — the caller must bind the document
        // or the line-ending / indentation lookups fall back to defaults.
        let document = Document(url: nil, initialText: text, encoding: .utf8, hasBOM: false)
        view.document = document

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = view
        window.makeFirstResponder(view)
        return (window, view, document, layoutManager)
    }

    private func setCarets(_ view: EditorTextView, _ ranges: [NSRange]) {
        view.setSelectedRanges(ranges.map { NSValue(range: $0) },
                               affinity: .downstream, stillSelecting: false)
    }

    private func selection(_ view: EditorTextView) -> [NSRange] {
        (view.selectedRanges as? [NSRange]) ?? []
    }

    /// Marks whole lines as compare-mode filler, the way `CompareDisplayBuilder` does:
    /// the attribute sits on every character of the padded row.
    private func markFillerLines(_ storage: NSTextStorage, lineIndices: Set<Int>) {
        let ns = storage.string as NSString
        var line = 0
        var location = 0
        while location <= ns.length {
            let range = ns.lineRange(for: NSRange(location: min(location, max(ns.length - 1, 0)), length: 0))
            if lineIndices.contains(line), range.length > 0 {
                storage.addAttribute(.isFillerLine, value: true, range: range)
            }
            line += 1
            if NSMaxRange(range) <= location { break }
            location = NSMaxRange(range)
            if location >= ns.length { break }
        }
    }

    // MARK: - T3 — multi-cursor typing

    // NOTE ON WHAT MULTI-CURSOR MEANS HERE. `NSTextView` cannot hold two
    // *empty* selections: `setSelectedRanges` with two zero-length ranges keeps
    // one and drops the rest (verified against plain AppKit — see
    // scratchpad/audit-textview/mcursor.swift). So a multi-cursor state in this
    // app is always several NON-empty ranges, which is exactly what ⌘D
    // (`addNextMatch`) produces. Typing then collapses back to a single caret,
    // because the result is zero-length ranges again; that is AppKit's limit,
    // not this fix's. What the fix changes is that the text at EVERY range is
    // replaced instead of only the primary one.

    func testInsertTextReplacesEveryCursorNotJustThePrimary() {
        let (_, view, _, _) = makeEditor("alpha\nbravo\ncharlie\n")
        setCarets(view, [NSRange(location: 0, length: 1), NSRange(location: 6, length: 1)])
        XCTAssertEqual(selection(view).count, 2, "fixture did not hold two selections")

        view.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(view.string, "Xlpha\nXravo\ncharlie\n")
    }

    func testInsertTextFansOutToEverySelection() {
        let (_, view, _, _) = makeEditor("alpha\nbravo\ncharlie\n")
        setCarets(view, [NSRange(location: 0, length: 2), NSRange(location: 6, length: 2)])

        view.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(view.string, "Xpha\nXavo\ncharlie\n")
        // AppKit keeps one caret (see the note above); it must be the primary
        // one, sitting just after the text this cursor inserted.
        XCTAssertEqual(selection(view).first, NSRange(location: 1, length: 0))
    }

    /// The path a real keystroke takes: AppKit's input system calls the
    /// `NSTextInputClient` method, not the `NSTextView` one.
    func testTypingThroughNSTextInputClientFansOut() {
        let (_, view, _, _) = makeEditor("alpha\nbravo\n")
        setCarets(view, [NSRange(location: 0, length: 1), NSRange(location: 6, length: 1)])

        (view as NSTextInputClient).insertText(
            "Z", replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        XCTAssertEqual(view.string, "Zlpha\nZravo\n")
    }

    func testMultiCursorInsertIsOneUndoStep() {
        let (_, view, _, _) = makeEditor("alpha\nbravo\n")
        setCarets(view, [NSRange(location: 0, length: 1), NSRange(location: 6, length: 1)])
        view.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.string, "Xlpha\nXravo\n")

        view.undoManager?.undo()
        XCTAssertEqual(view.string, "alpha\nbravo\n", "one keystroke must be one undo step")
    }

    func testInsertTabIndentsEveryCursor() {
        let (_, view, document, _) = makeEditor("alpha\nbravo\n")
        document.indentation = .spaces2
        setCarets(view, [NSRange(location: 0, length: 1), NSRange(location: 6, length: 1)])

        view.insertTab(nil)

        XCTAssertEqual(view.string, "  lpha\n  ravo\n")
    }

    func testPasteInsertsAtEveryCursor() {
        let (_, view, _, _) = makeEditor("alpha\nbravo\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("//", forType: .string)
        setCarets(view, [NSRange(location: 0, length: 1), NSRange(location: 6, length: 1)])

        view.paste(nil)

        XCTAssertEqual(view.string, "//lpha\n//ravo\n")
    }

    // MARK: - T4 — plural shouldChangeText honours filler lines

    func testPluralShouldChangeTextRefusesFillerLines() {
        let (_, view, _, _) = makeEditor("real one\nfiller\nreal two\n")
        guard let storage = view.textStorage else { return XCTFail("no storage") }
        markFillerLines(storage, lineIndices: [1])

        let fillerStart = ("real one\n" as NSString).length
        let ok = view.shouldChangeText(
            inRanges: [NSValue(range: NSRange(location: 0, length: 1)),
                       NSValue(range: NSRange(location: fillerStart, length: 1))],
            replacementStrings: ["A", "B"]
        )
        XCTAssertFalse(ok, "a plural edit touching a filler line must be refused")
    }

    func testMultiCursorInsertRefusedWhenOneCaretIsOnAFillerLine() {
        let (_, view, _, _) = makeEditor("real one\nfiller\nreal two\n")
        guard let storage = view.textStorage else { return XCTFail("no storage") }
        markFillerLines(storage, lineIndices: [1])
        let before = view.string

        setCarets(view, [NSRange(location: 0, length: 1),
                         NSRange(location: ("real one\n" as NSString).length, length: 1)])
        view.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(view.string, before, "filler protection must survive the fan-out")
    }

    // MARK: - T13 — the Thai sanitiser is for interactive typing only

    /// U+0E48 MAI EK typed twice in a row is the duplicate the sanitiser exists to drop.
    func testInteractiveThaiTypingStillDropsADuplicatedMark() {
        let (_, view, _, _) = makeEditor("\u{0E01}\u{0E48}")   // ก + ่
        view.setSelectedRange(NSRange(location: 2, length: 0))

        view.insertText("\u{0E48}", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(view.string, "\u{0E01}\u{0E48}", "the duplicate mark must not be inserted")
    }

    func testPastedThaiKeepsItsOwnDoubledMarks() {
        let (_, view, _, _) = makeEditor("")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\u{0E01}\u{0E48}\u{0E48}", forType: .string)

        view.paste(nil)

        XCTAssertEqual(view.string, "\u{0E01}\u{0E48}\u{0E48}",
                       "paste is not interactive typing; it must be inserted verbatim")
    }

    // MARK: - T11 — line commands are one storage-editing group

    private final class EditCounter: NSObject, NSTextStorageDelegate {
        var processedEdits = 0
        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            if editedMask.contains(.editedCharacters) { processedEdits += 1 }
        }
    }

    func testDeleteCurrentLinesIsOneEditingGroup() {
        let (_, view, _, _) = makeEditor("one\ntwo\nthree\nfour\n")
        guard let storage = view.textStorage else { return XCTFail("no storage") }
        let counter = EditCounter()
        storage.delegate = counter

        setCarets(view, [NSRange(location: 0, length: 1),
                         NSRange(location: 4, length: 1),
                         NSRange(location: 8, length: 1)])
        view.deleteCurrentLines()

        XCTAssertEqual(view.string, "four\n")
        XCTAssertEqual(counter.processedEdits, 1,
                       "three deleted lines must coalesce into one processEditing pass")
        storage.delegate = nil
    }

    func testDuplicateCurrentLinesIsOneEditingGroup() {
        let (_, view, _, _) = makeEditor("one\ntwo\n")
        guard let storage = view.textStorage else { return XCTFail("no storage") }
        let counter = EditCounter()
        storage.delegate = counter

        setCarets(view, [NSRange(location: 0, length: 1), NSRange(location: 4, length: 1)])
        view.duplicateCurrentLines()

        XCTAssertEqual(view.string, "one\none\ntwo\ntwo\n")
        XCTAssertEqual(counter.processedEdits, 1)
        storage.delegate = nil
    }

    // MARK: - T12 — fold/filler-aware copy covers every selection

    /// Two disjoint selections where the FIRST one spans a filler line. AppKit's
    /// own `copy:` already joins several selections with a newline, so the bug
    /// only shows when the fold/filler-aware branch takes over: it read
    /// `selectedRange()` — the primary range — and silently dropped the rest.
    func testCopyCoversEverySelectedRange() {
        let (_, view, _, _) = makeEditor("alpha\nfiller\nbravo\ncharlie\n")
        guard let storage = view.textStorage else { return XCTFail("no storage") }
        markFillerLines(storage, lineIndices: [1])

        let bravoStart = ("alpha\nfiller\n" as NSString).length
        let charlieStart = ("alpha\nfiller\nbravo\n" as NSString).length
        setCarets(view, [NSRange(location: 0, length: bravoStart + 5),   // alpha + filler + bravo
                         NSRange(location: charlieStart, length: 7)])    // charlie

        NSPasteboard.general.clearContents()
        view.copy(nil)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "alpha\nbravo\ncharlie")
    }

    func testCopyStillSkipsFillerLinesInsideOneSelection() {
        let (_, view, _, _) = makeEditor("alpha\nfiller\nbravo\n")
        guard let storage = view.textStorage else { return XCTFail("no storage") }
        markFillerLines(storage, lineIndices: [1])

        setCarets(view, [NSRange(location: 0, length: ("alpha\nfiller\nbravo" as NSString).length)])
        NSPasteboard.general.clearContents()
        view.copy(nil)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "alpha\nbravo")
    }

    // MARK: - T10 — the click clamp does not force whole-document layout

    /// The clamp used to open with `ensureLayout(for: textContainer)` — glyph
    /// generation and layout for the WHOLE document, to answer one mouse click.
    /// Nothing has been laid out yet here, and answering must leave it that way.
    func testClickClampDoesNotForceFullLayout() {
        let source = String(repeating: "0123456789abcde\n", count: 20_000)   // ~320 KB
        let (_, view, _, layoutManager) = makeEditor(source)
        guard let storage = view.textStorage else { return XCTFail("no storage") }

        // Setting `string` on a vertically-resizable view sizes it to fit, which
        // lays the whole document out. Put layout back to where it is in the
        // real app right after an edit: invalid, and re-established lazily for
        // whatever gets drawn.
        layoutManager.invalidateLayout(
            forCharacterRange: NSRange(location: 0, length: storage.length),
            actualCharacterRange: nil
        )
        let laidOutBefore = layoutManager.firstUnlaidCharacterIndex()
        XCTAssertTrue(laidOutBefore < storage.length,
                      "fixture already fully laid out; the test would prove nothing")

        // A click inside the region a first frame would have laid out.
        XCTAssertFalse(view.shouldClampClickToDocumentEnd(at: NSPoint(x: 20, y: 40)),
                       "a click inside the text is not past the end of the document")

        XCTAssertEqual(layoutManager.firstUnlaidCharacterIndex(), laidOutBefore,
                       "answering a click must not lay out the whole document")
    }

    func testClickBelowTheLastLineStillClamps() {
        let (_, view, _, layoutManager) = makeEditor("one\ntwo\nthree\n")
        guard let container = view.textContainer else { return XCTFail("no container") }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)

        XCTAssertTrue(view.shouldClampClickToDocumentEnd(at: NSPoint(x: 10, y: used.maxY + 200)))
        XCTAssertFalse(view.shouldClampClickToDocumentEnd(at: NSPoint(x: 10, y: 4)))
    }

    // MARK: - T7 — the memoised line lookup never reports a stale line

    private func reportedLine(_ view: EditorTextView, at location: Int) -> Int {
        var line = -1
        let token = NotificationCenter.default.addObserver(
            forName: EditorTextView.selectionDidChange, object: view, queue: nil
        ) { note in
            line = (note.userInfo?["line"] as? Int) ?? -1
        }
        defer { NotificationCenter.default.removeObserver(token) }
        view.setSelectedRange(NSRange(location: location, length: 0))
        return line
    }

    func testReportedLineMatchesTextLineIndexAcrossMovesAndEdits() {
        let (_, view, _, _) = makeEditor("l1\r\nl2\r\nl3\r\nl4\r\nl5\r\nl6\r\n")
        guard let storage = view.textStorage else { return XCTFail("no storage") }

        func check(_ location: Int, _ message: String) {
            let expected = TextLineIndex.lineNumber(in: storage.string as NSString, at: location)
            XCTAssertEqual(reportedLine(view, at: location), expected, message)
        }

        // Forward, backward, and repeated — the memo has to survive all three.
        for location in stride(from: 0, through: storage.length, by: 2) { check(location, "forward \(location)") }
        for location in stride(from: storage.length, through: 0, by: -3) { check(location, "backward \(location)") }

        // Now edit, and make sure the memo was thrown away.
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("A\nB\nC\n", replacementRange: NSRange(location: 0, length: 0))
        for location in stride(from: 0, through: storage.length, by: 2) { check(location, "after edit \(location)") }

        // And an equal-length replacement that moves a line break.
        _ = view.shouldChangeText(in: NSRange(location: 1, length: 1), replacementString: "\n")
        storage.replaceCharacters(in: NSRange(location: 1, length: 1), with: "\n")
        view.didChangeText()
        for location in stride(from: 0, through: storage.length, by: 2) { check(location, "after equal-length edit \(location)") }
    }

    // MARK: - S10 — Thai font fallback

    func testThaiFallbackAppliesOnlyToThaiRuns() {
        let text = "abc \u{0E01}\u{0E48}\u{0E02} def \u{0E23}\u{0E39}"
        let (_, view, _, _) = makeEditor(text)
        guard let storage = view.textStorage else { return XCTFail("no storage") }
        let base = view.editorFont

        view.applyThaiFontFallback()

        let ns = text as NSString
        for index in 0..<ns.length {
            let unit = ns.character(at: index)
            let isThai = unit >= 0x0E00 && unit <= 0x0E7F
            let font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont
            if isThai {
                XCTAssertNotEqual(font?.fontName, base.fontName, "Thai unit \(index) kept the base font")
            } else {
                XCTAssertNotEqual(font?.fontName, "Thonburi", "non-Thai unit \(index) got the Thai font")
            }
        }
    }

    func testThaiFallbackLeavesAnAsciiDocumentUntouched() {
        let (_, view, _, _) = makeEditor("plain ascii text\nsecond line\n")
        guard let storage = view.textStorage else { return XCTFail("no storage") }
        let before = NSAttributedString(attributedString: storage)

        view.applyThaiFontFallback()

        XCTAssertTrue(before.isEqual(to: storage),
                      "a document with no Thai must come back byte-for-byte identical")
    }

    // MARK: - U14 — the view does not write display text into the document

    private final class TextSink: NSObject, NSTextViewDelegate {
        weak var document: Document?
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            document?.text = view.string
        }
    }

    /// `document.text` is NOT the storage string: in compare mode it is the text
    /// with filler rows stripped, and with a fold collapsed it is the text with
    /// the placeholder expanded. Both derivations live in the coordinator's
    /// `textDidChange`. The view writing `storage.string` there — as it did,
    /// right before `didChangeText()` — puts display text into the model.
    /// With no delegate attached nothing derives it, so it must stay put.
    func testReplaceTextDoesNotPushDisplayTextIntoTheDocument() {
        let (_, view, document, _) = makeEditor("alpha  \nbravo  \n")
        view.delegate = nil
        document.text = "DERIVED-BY-THE-COORDINATOR"

        view.trimTrailingWhitespace()

        XCTAssertEqual(view.string, "alpha\nbravo\n", "the storage edit itself must still happen")
        XCTAssertEqual(document.text, "DERIVED-BY-THE-COORDINATOR",
                       "document.text is the coordinator's to derive; the view must not overwrite it with the display string")
    }

    func testTrimTrailingWhitespaceStillReachesTheDocumentThroughTheDelegate() {
        let (_, view, document, _) = makeEditor("alpha  \nbravo\t\n")
        let sink = TextSink()
        sink.document = document
        view.delegate = sink

        view.trimTrailingWhitespace()

        XCTAssertEqual(view.string, "alpha\nbravo\n")
        XCTAssertEqual(document.text, "alpha\nbravo\n",
                       "didChangeText must still notify the delegate that derives document.text")
        view.delegate = nil
    }

    func testConvertIndentationStillReachesTheDocumentThroughTheDelegate() {
        let (_, view, document, _) = makeEditor("\tone\n\ttwo\n")
        let sink = TextSink()
        sink.document = document
        view.delegate = sink

        view.convertIndentation(to: .spaces4)

        XCTAssertEqual(view.string, "    one\n    two\n")
        XCTAssertEqual(document.text, "    one\n    two\n")
        view.delegate = nil
    }

    // MARK: - U15 — DocumentStore.documentDidMove

    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sheeptext-move-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testDocumentDidMoveUpdatesTheOpenDocument() throws {
        let dir = makeTempDirectory()
        let from = dir.appendingPathComponent("before.txt")
        let to = dir.appendingPathComponent("after.md")
        try "hello\n".write(to: from, atomically: true, encoding: .utf8)

        let store = DocumentStore()
        guard let doc = store.open(url: from) else { return XCTFail("open failed") }
        XCTAssertEqual(doc.url?.lastPathComponent, "before.txt")

        try FileManager.default.moveItem(at: from, to: to)
        store.documentDidMove(from: from, to: to)

        XCTAssertEqual(doc.url?.canonicalFileURL, to.canonicalFileURL)
        XCTAssertEqual(doc.accessibleURL?.canonicalFileURL, to.canonicalFileURL)
        XCTAssertNotNil(doc.diskModificationDate)
        XCTAssertEqual(doc.diskFileSize, 6)
        XCTAssertTrue(store.recentFiles.contains { $0.canonicalFileURL == to.canonicalFileURL })
        XCTAssertFalse(store.recentFiles.contains { $0.canonicalFileURL == from.canonicalFileURL })
    }

    func testDocumentDidMoveFollowsARenamedDirectory() throws {
        let root = makeTempDirectory()
        let oldDir = root.appendingPathComponent("old")
        let newDir = root.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        let file = oldDir.appendingPathComponent("note.txt")
        try "abc\n".write(to: file, atomically: true, encoding: .utf8)

        let store = DocumentStore()
        guard let doc = store.open(url: file) else { return XCTFail("open failed") }

        try FileManager.default.moveItem(at: oldDir, to: newDir)
        store.documentDidMove(from: oldDir, to: newDir)

        XCTAssertEqual(doc.url?.canonicalFileURL,
                       newDir.appendingPathComponent("note.txt").canonicalFileURL,
                       "a folder rename must carry the documents inside it")
    }

    func testDocumentDidMoveIgnoresUnrelatedDocuments() throws {
        let dir = makeTempDirectory()
        let kept = dir.appendingPathComponent("kept.txt")
        let from = dir.appendingPathComponent("moved.txt")
        let to = dir.appendingPathComponent("moved-2.txt")
        try "one\n".write(to: kept, atomically: true, encoding: .utf8)
        try "two\n".write(to: from, atomically: true, encoding: .utf8)

        let store = DocumentStore()
        guard let keptDoc = store.open(url: kept) else { return XCTFail("open failed") }
        _ = store.open(url: from)

        try FileManager.default.moveItem(at: from, to: to)
        store.documentDidMove(from: from, to: to)

        XCTAssertEqual(keptDoc.url?.canonicalFileURL, kept.canonicalFileURL)
    }
}
