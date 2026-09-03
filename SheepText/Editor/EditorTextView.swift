//
//  EditorTextView.swift
//  NSTextView subclass with multi-cursor editing.
//
//  macOS' NSTextView has supported multi-selection via ⌥-drag since macOS 10.8,
//  exposed through the `selectedRanges` property. We lean on that and add:
//    - ⌘D to add the next occurrence of the current selection as another cursor
//    - ⌘⌥⌃G to add ALL occurrences
//
//  Both are dispatched by BuiltInCommands to EditorCommandTarget.focusedEditor.
//  They used to be broadcast through NotificationCenter, which every live text
//  view answered — in compare mode one ⌘D added cursors in both panes.
//

import AppKit

nonisolated private struct TextKitMainActorValue<Value>: @unchecked Sendable {
    let value: Value
}

extension NSTextView {

    /// Throw away the undo history because the storage was just rewritten behind
    /// the undo manager's back.
    ///
    /// Every entry in the stack is a range measured in the text as it was when
    /// the entry was recorded. Three things in this editor replace the storage
    /// without going through `shouldChangeText`, so those ranges stop describing
    /// anything real:
    ///
    ///   * folding — the block becomes a one-character placeholder, so an edit
    ///     made while a block was folded used to be undone dozens of characters
    ///     away once it was expanded, deleting text elsewhere in the file;
    ///   * switching tabs — one text view serves every tab, so ⌘Z after a switch
    ///     replayed the previous document's edit into the new one;
    ///   * reloading from disk.
    ///
    /// Keeping the stack valid across those would mean making them undoable edits
    /// themselves (or folding in the layout manager, which never touches the
    /// storage). Until then, dropping the history is the only option that cannot
    /// corrupt a document.
    func discardUndoHistory() {
        undoManager?.removeAllActions()
    }
}

extension NSAttributedString.Key {
    nonisolated static let isFillerLine = NSAttributedString.Key("sheeptext.isFillerLine")
}

// MARK: - DiffLayoutManager

/// NSLayoutManager subclass that draws diff highlights at the correct layer:
/// full-width line backgrounds and tight word highlights both appear before
/// text glyphs, so they show as colored backgrounds under the characters.
// NSLayoutManager subclass hooks are nonisolated in AppKit. SheepText only owns
// this layout manager from a main-actor NSTextView; UI reads below assert that
// framework invariant at the narrow access points.
nonisolated final class DiffLayoutManager: NSLayoutManager, NSLayoutManagerDelegate, @unchecked Sendable {

    weak var ownerTextView: NSTextView?

    /// Full-width line background tints (one per diff line paragraph range).
    var lineHighlights: [(range: NSRange, color: NSColor)] = []

    /// Every character edit, as (edited range in NEW coordinates, length delta).
    ///
    /// The editor coordinator uses it to move its highlight runs with the text,
    /// so the colours on screen stay right through the rehighlight debounce.
    /// `NSText.didChangeNotification` — the only other hook — does not say WHAT
    /// changed, and by the time it arrives the offsets are gone.
    nonisolated(unsafe) var onCharactersEdited: (@MainActor (NSRange, Int) -> Void)?

    /// Called (coalesced, on the next main-queue turn) whenever TextKit finishes
    /// laying out a chunk.
    ///
    /// The editor paints syntax colours for the characters on screen, so it has
    /// to hear about anything that changes WHICH characters those are. Scroll
    /// and resize have their own notifications; this catches the rest — the
    /// first layout of a pane that has just been added to a window, a font-size
    /// change, a word-wrap toggle — without the coordinator having to enumerate
    /// them.
    nonisolated(unsafe) var onDidCompleteLayout: (@MainActor () -> Void)?

    /// One pending paint at a time. A `let` of its own rather than a flag on
    /// `self`, so the coalescing can be read and cleared from the main-queue
    /// block without sending the layout manager across isolation.
    private final class PaintGate: @unchecked Sendable {
        private let lock = NSLock()
        private var scheduled = false
        func begin() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if scheduled { return false }
            scheduled = true
            return true
        }
        func end() {
            lock.lock(); scheduled = false; lock.unlock()
        }
    }
    private let layoutPaintGate = PaintGate()

    override init() {
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

    func fixedLineMetrics(for font: NSFont) -> (height: CGFloat, natural: CGFloat, baseline: CGFloat) {
        let natural = font.ascender - font.descender + font.leading
        let owner = ownerTextView
        let configuredHeight = MainActor.assumeIsolated {
            (owner as? EditorTextView)?.editorFixedLineHeight
        }
        let height = configuredHeight ?? ceil(natural * 1.3)
        let topInset = max(0, (height - natural) / 2)
        let opticalBaselineDrop = min(1.5, max(0.5, font.pointSize * 0.08))
        return (height, natural, topInset + font.ascender + opticalBaselineDrop)
    }

    override func defaultLineHeight(for font: NSFont) -> CGFloat {
        fixedLineMetrics(for: font).height
    }

    override func defaultBaselineOffset(for font: NSFont) -> CGFloat {
        fixedLineMetrics(for: font).baseline
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        let storageFont = textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let owner = ownerTextView
        let ownerFont = MainActor.assumeIsolated {
            TextKitMainActorValue(value: owner?.font)
        }.value
        let font = ownerFont
            ?? storageFont
            ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let metrics = fixedLineMetrics(for: font)

        // Both rects get identical origin and height so TextKit places every
        // subsequent line at a uniform step. The baseline offset alone controls
        // where glyphs sit vertically within the fixed-height row.
        lineFragmentRect.pointee.size.height     = metrics.height
        lineFragmentUsedRect.pointee.origin.y    = lineFragmentRect.pointee.origin.y
        lineFragmentUsedRect.pointee.size.height = metrics.height
        baselineOffset.pointee                   = metrics.baseline
        return true
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        didCompleteLayoutFor textContainer: NSTextContainer?,
        atEnd layoutFinishedFlag: Bool
    ) {
        guard let onDidCompleteLayout, layoutPaintGate.begin() else { return }
        let gate = layoutPaintGate
        // Never synchronously: this is called from inside a layout pass, and the
        // paint touches the same layout manager.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                gate.end()
                onDidCompleteLayout()
            }
        }
    }

    override func processEditing(
        for textStorage: NSTextStorage,
        edited editMask: NSTextStorageEditActions,
        range newCharRange: NSRange,
        changeInLength delta: Int,
        invalidatedRange invalidatedCharRange: NSRange
    ) {
        // Keep lineHighlights character ranges in sync with every text edit so
        // highlights don't drift into adjacent lines between applyCompareDisplay calls.
        // Called with the textStorage already reflecting the new content, so the
        // replaced span in OLD coordinates is [editStart, editStart + newLen - delta).
        if delta != 0, editMask.contains(.editedCharacters), !lineHighlights.isEmpty {
            let editStart = newCharRange.location
            let oldEditEnd = editStart + (newCharRange.length - delta)
            lineHighlights = lineHighlights.compactMap { item in
                let start = item.range.location
                let end = NSMaxRange(item.range)
                var loc = start
                var len = item.range.length
                if end <= editStart {
                    // Entirely before the edit — unchanged.
                    return item
                } else if start >= oldEditEnd {
                    // Entirely after the replaced span — shift by delta.
                    loc += delta
                } else if start <= editStart && end >= oldEditEnd {
                    // Fully covers the replaced span — absorb the length change.
                    len += delta
                } else if start < editStart {
                    // Overlaps the front of the replaced span — keep the untouched head.
                    len = editStart - start
                } else if end > oldEditEnd {
                    // Overlaps the back of the replaced span — keep the untouched tail,
                    // repositioned to just after the inserted text.
                    loc = editStart + newCharRange.length
                    len = end - oldEditEnd
                } else {
                    // Entirely inside the replaced span — the highlighted text is gone.
                    return nil
                }
                guard loc >= 0, len > 0 else { return nil }
                return (range: NSRange(location: loc, length: len), color: item.color)
            }
        }
        super.processEditing(for: textStorage, edited: editMask, range: newCharRange,
                             changeInLength: delta,
                             invalidatedRange: invalidatedCharRange)

        // After super, so AppKit has already shifted its own temporary
        // attributes: the coordinator's painted window has to move the same way.
        if editMask.contains(.editedCharacters), let onCharactersEdited {
            MainActor.assumeIsolated { onCharactersEdited(newCharRange, delta) }
        }
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        // ── 1. Full-width line backgrounds ────────────────────────────────────
        if !lineHighlights.isEmpty {
            let owner = ownerTextView
            let ownerWidth = MainActor.assumeIsolated { owner?.bounds.width }
            let viewWidth = max(ownerWidth ?? 2000, 1)

            // Only the rows on screen. This used to convert EVERY highlight's
            // character range to a glyph range and then discard it — around
            // 1200 layout-manager round trips per frame on a large compare, to
            // draw the ~50 rows actually visible.
            //
            // `lineHighlights` is filled by walking paragraphs in order and
            // `processEditing` shifts ranges without reordering them, so it is
            // sorted by location and can be binary-searched. Keep it that way.
            let visibleChars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            let visibleEnd = NSMaxRange(visibleChars)

            var lo = 0, hi = lineHighlights.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if NSMaxRange(lineHighlights[mid].range) <= visibleChars.location {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }

            var i = lo
            while i < lineHighlights.count, lineHighlights[i].range.location < visibleEnd {
                let item = lineHighlights[i]
                i += 1
                let charGlyphs = glyphRange(forCharacterRange: item.range, actualCharacterRange: nil)
                let visible = NSIntersectionRange(charGlyphs, glyphsToShow)
                guard visible.length > 0 else { continue }
                item.color.setFill()
                enumerateLineFragments(forGlyphRange: visible) { lineRect, _, _, _, _ in
                    NSRect(x: 0,
                           y: lineRect.origin.y + origin.y,
                           width: viewWidth,
                           height: lineRect.height).fill()
                }
            }
        }

        // ── 2. Default backgrounds (selection, .backgroundColor temp attrs) ────
        // Word-level diff highlights are applied via addTemporaryAttribute(.backgroundColor)
        // in applyCompareDisplay, so they render here through AppKit's own pipeline.
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

// MARK: - EditorTextView

final class EditorTextView: NSTextView {

    weak var document: Document?
    weak var preferences: AppPreferences?
    weak var foldingManager: FoldingManager?
    var findHighlightRanges: [NSRange] = []
    var findCurrentIdx: Int = 0
    private var isHandlingMouseSelection = false

    /// Posted whenever the selection or text content changes so the status
    /// bar (or any other observer) can refresh. The userInfo carries line,
    /// column, selected-character-count, and total-character-count.
    static let selectionDidChange = Notification.Name("sheeptext.editor.selectionDidChange")

    // No notification observers here on purpose. ⌘D / ⌘⌃⌥D used to arrive as
    // broadcasts (`object: nil`), which every live text view answered — in
    // compare mode that meant both panes gained cursors from one keypress.
    // BuiltInCommands now calls addNextMatch()/addAllMatches() on
    // EditorCommandTarget.focusedEditor instead.

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder {
            EditorCommandTarget.register(self)
        }
        return becameFirstResponder
    }

    override func insertTab(_ sender: Any?) {
        guard let indentation = document?.indentation else {
            super.insertTab(sender)
            return
        }
        // NSNotFound, not selectedRange(): an explicit range is the primary
        // cursor only, and Tab has to indent at every cursor. The Thai
        // sanitiser is suppressed because this is not a keystroke the user
        // typed into the text (see `suppressesThaiSanitizer`).
        suppressesThaiSanitizer = true
        defer { suppressesThaiSanitizer = false }
        insertText(indentation.insertionString,
                   replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// Set while `paste`/`insertTab` route their text through `insertText`, so
    /// the Thai combining-mark sanitiser stays off. It exists to stop a *typed*
    /// mark from being repeated on top of itself; pasted or programmatic text
    /// carries whatever the source had, doubled marks included, and silently
    /// dropping one of them corrupts the paste.
    private var suppressesThaiSanitizer = false

    /// AppKit applies an insertion to **one** range.
    ///
    /// With `replacementRange` = NSNotFound the documentation reads as though
    /// the insertion goes to the whole selection, and on TextKit 1 it does not:
    /// `NSTextView` resolves `rangeForUserTextChange` — the primary range — and
    /// every other cursor is discarded (verified with a standalone AppKit
    /// program; `deleteBackward:` *does* fan out, which is why deleting felt
    /// like it worked and typing did not). So multi-cursor typing inserted one
    /// character at one cursor and collapsed the rest.
    ///
    /// The fan-out below is the same arithmetic as `duplicateCurrentLines`:
    /// plural `shouldChangeText` (one undo step, and the filler-line guard sees
    /// every range), one storage editing group, replacements applied
    /// back-to-front so the offsets stay valid, then the carets rebuilt by
    /// carrying the running delta forward.
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard !hasMarkedText(),
              let insertedText = plainString(from: insertString)
        else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }

        let ranges: [NSRange]
        if replacementRange.location == NSNotFound {
            ranges = (rangesForUserTextChange as? [NSRange])
                ?? (selectedRanges as? [NSRange])
                ?? [selectedRange()]
        } else {
            ranges = [replacementRange]
        }

        // Only an interactive single-cluster keystroke is sanitised. `count == 1`
        // is the grapheme-cluster count, so a Thai base + mark typed as one
        // dead-key sequence still qualifies while a paste never does.
        let sanitizes = !suppressesThaiSanitizer
            && replacementRange.location == NSNotFound
            && insertedText.count == 1

        if ranges.count > 1 {
            var strings: [String] = []
            strings.reserveCapacity(ranges.count)
            for range in ranges {
                let text = sanitizes
                    ? sanitizedThaiCombiningMarks(in: insertedText, replacementRange: range)
                    : insertedText
                strings.append(text)
            }
            // A mark that would be dropped at EVERY cursor is the duplicate the
            // sanitiser exists to refuse; beep and insert nothing, as the
            // single-cursor path does.
            if strings.allSatisfy(\.isEmpty) {
                NSSound.beep()
                return
            }
            if strings.contains(where: { $0 != insertedText }) { NSSound.beep() }
            if insertText(strings, atRanges: ranges) { return }
            return
        }

        guard sanitizes else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }

        let effectiveRange = ranges.first ?? selectedRange()
        let sanitizedText = sanitizedThaiCombiningMarks(
            in: insertedText,
            replacementRange: effectiveRange
        )
        guard !sanitizedText.isEmpty else {
            NSSound.beep()
            return
        }

        if sanitizedText == insertedText {
            super.insertText(insertString, replacementRange: replacementRange)
        } else {
            NSSound.beep()
            super.insertText(sanitizedText, replacementRange: replacementRange)
        }
    }

    /// One replacement per range, as one edit and one undo step. Returns false
    /// when nothing was applied (out-of-bounds ranges, or a filler line).
    @discardableResult
    private func insertText(_ strings: [String], atRanges ranges: [NSRange]) -> Bool {
        guard let storage = textStorage, ranges.count == strings.count else { return false }
        let length = storage.length

        var edits: [(range: NSRange, text: String)] = []
        edits.reserveCapacity(ranges.count)
        for (index, range) in ranges.enumerated() {
            guard range.location != NSNotFound,
                  range.location >= 0,
                  range.length >= 0,
                  NSMaxRange(range) <= length
            else { continue }
            edits.append((range, strings[index]))
        }
        guard !edits.isEmpty else { return false }
        edits.sort { $0.range.location < $1.range.location }

        guard shouldChangeText(inRanges: edits.map { NSValue(range: $0.range) },
                               replacementStrings: edits.map(\.text))
        else { return false }

        storage.beginEditing()
        for edit in edits.reversed() {
            storage.replaceCharacters(in: edit.range, with: edit.text)
        }
        storage.endEditing()

        // Each caret lands after its own insertion, displaced by the net length
        // change of every edit before it.
        var carets: [NSRange] = []
        carets.reserveCapacity(edits.count)
        var shift = 0
        for edit in edits {
            let insertedLength = (edit.text as NSString).length
            let location = edit.range.location + shift + insertedLength
            shift += insertedLength - edit.range.length
            carets.append(NSRange(location: min(max(location, 0), storage.length), length: 0))
        }
        setSelectedRanges(carets as [NSValue], affinity: .downstream, stillSelecting: false)
        didChangeText()
        return true
    }

    private func sanitizedThaiCombiningMarks(
        in insertedText: String,
        replacementRange: NSRange
    ) -> String {
        guard !insertedText.isEmpty,
              let storage = textStorage,
              replacementRange.location >= 0,
              replacementRange.location <= storage.length
        else { return insertedText }

        var result = ""
        var previousScalar = scalarBeforeInsertion(in: storage.string, location: replacementRange.location)
        for scalar in insertedText.unicodeScalars {
            if Self.isThaiCombiningMark(scalar), scalar == previousScalar {
                continue
            }
            result.unicodeScalars.append(scalar)
            previousScalar = scalar
        }
        return result
    }

    private func plainString(from insertString: Any) -> String? {
        if let string = insertString as? String {
            return string
        }
        if let attributedString = insertString as? NSAttributedString {
            return attributedString.string
        }
        return nil
    }

    private func scalarBeforeInsertion(in string: String, location: Int) -> UnicodeScalar? {
        guard location > 0,
              location <= (string as NSString).length,
              let stringIndex = String.Index(
                utf16Offset: location,
                in: string
              ).samePosition(in: string)
        else { return nil }
        return string[..<stringIndex].unicodeScalars.last
    }

    private static func isThaiCombiningMark(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x0E31, 0x0E34...0x0E3A, 0x0E47...0x0E4E:
            return true
        default:
            return false
        }
    }

    private static func isThaiScalar(_ scalar: UnicodeScalar) -> Bool {
        (0x0E00...0x0E7F).contains(scalar.value)
    }

    // MARK: - Filler line protection

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard let storage = textStorage, storage.length > 0 else {
            return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        }
        guard !touchesFillerLine(affectedCharRange, in: storage) else { return false }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    /// The plural form is NOT routed through the singular one by AppKit —
    /// verified: `shouldChangeText(inRanges:replacementStrings:)` on a plain
    /// NSTextView never calls `shouldChangeText(in:replacementString:)`. So
    /// every multi-range edit (this file's own multi-cursor insert and Replace
    /// All, plus anything AppKit routes here) went round the filler-line guard.
    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        guard let storage = textStorage, storage.length > 0 else {
            return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
        }
        for value in affectedRanges where touchesFillerLine(value.rangeValue, in: storage) {
            return false
        }
        return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
    }

    /// True when any part of `range` lies on a compare-mode filler line, which is
    /// padding rather than document content and must never be edited.
    private func touchesFillerLine(_ range: NSRange, in storage: NSTextStorage) -> Bool {
        guard storage.length > 0 else { return false }
        // The paragraph containing the insertion/edit point.
        let loc = min(max(range.location, 0), storage.length - 1)
        if storage.attribute(.isFillerLine, at: loc, effectiveRange: nil) != nil {
            return true
        }
        // For selections spanning several characters, check the interior too.
        guard range.length > 0 else { return false }
        let endLoc = min(NSMaxRange(range), storage.length) - 1
        guard endLoc > loc else { return false }
        var blocked = false
        let span = NSRange(location: loc + 1, length: endLoc - loc)
        storage.enumerateAttribute(.isFillerLine, in: span, options: []) { value, _, stop in
            if value != nil { blocked = true; stop.pointee = true }
        }
        return blocked
    }

    /// Apply the same replacement to many ranges as ONE edit and ONE undo step.
    ///
    /// Find bar's Replace All used to post one notification per match, and each of
    /// those copied the whole document into `document.text` and rescheduled the
    /// draft and auto-save timers — 500 matches in a 500 KB file meant a quarter of
    /// a gigabyte of copying and 500 undo steps to walk back through.
    ///
    /// Returns the number of ranges actually replaced.
    @discardableResult
    func replaceOccurrences(_ ranges: [NSRange], with replacement: String) -> Int {
        guard let storage = textStorage, !ranges.isEmpty else { return 0 }
        let length = storage.length
        let valid = ranges
            .filter { $0.location >= 0 && $0.length >= 0 && NSMaxRange($0) <= length }
            .filter { !touchesFillerLine($0, in: storage) }
            .sorted { $0.location < $1.location }
        guard !valid.isEmpty else { return 0 }

        // The plural form registers a single undo group covering every range.
        let values = valid.map { NSValue(range: $0) }
        let strings = Array(repeating: replacement, count: valid.count)
        guard shouldChangeText(inRanges: values, replacementStrings: strings) else { return 0 }

        storage.beginEditing()
        // Back-to-front so the earlier offsets stay valid.
        for range in valid.reversed() {
            storage.replaceCharacters(in: range, with: replacement)
        }
        storage.endEditing()
        didChangeText()
        return valid.count
    }

    /// Return only real (non-filler) lines joined by newlines.
    /// The document text behind a compare display: every line except the blank
    /// filler rows.
    ///
    /// Runs on every keystroke in compare mode, and its result becomes
    /// `document.text` — i.e. what gets saved. It used to allocate a String per
    /// line and then join them, so a 1200-row display cost about 2 400
    /// allocations and two full copies of the document per character typed.
    /// Contiguous kept lines are now copied as one run.
    ///
    /// A paragraph is judged by the attribute on its FIRST character, exactly as
    /// before. That distinction matters: deleting every marked character instead
    /// would be faster still, but text typed next to a filler line can inherit
    /// the attribute from the neighbouring run, and dropping it here would erase
    /// what the user just typed.
    ///
    /// Lines are found by scanning for LF, never with `NSString.paragraphRange`.
    /// The display text is `rows.joined(separator: "\n")`, and paragraphRange
    /// also breaks on a lone CR and on U+2029 — so on a file with any stray CR
    /// the paragraphs outnumbered the rows, the filler attribute landed a line
    /// early, and a REAL line was dropped out of the document and then autosaved.
    @MainActor
    func realText(from storage: NSTextStorage) -> String {
        let ns = storage.string as NSString
        let length = ns.length
        guard length > 0 else { return "" }

        var keptRuns: [NSRange] = []
        var runStart = -1          // start of the run of kept lines being accumulated
        var runEnd = 0

        func closeRun() {
            guard runStart >= 0 else { return }
            var end = runEnd
            // Strip the run's trailing newline; runs are rejoined below.
            if end > runStart && ns.character(at: end - 1) == 10 { end -= 1 }
            keptRuns.append(NSRange(location: runStart, length: end - runStart))
            runStart = -1
        }

        CompareDisplayLines.forEachLine(in: storage) { lineRange, isFiller in
            if isFiller {
                closeRun()
            } else {
                if runStart < 0 { runStart = lineRange.location }
                runEnd = NSMaxRange(lineRange)
            }
            return true
        }
        closeRun()
        return keptRuns.map { ns.substring(with: $0) }.joined(separator: "\n")
    }

    // MARK: - Current line highlight

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager = layoutManager else { return }

        // Current-line highlight — only when cursor is collapsed (no selection / no find).
        if findHighlightRanges.isEmpty {
            let ranges = selectedRanges.map(\.rangeValue)
            if let primary = ranges.first, primary.length == 0 {
                let charLocation = min(primary.location, textStorage?.length ?? string.utf16.count)
                guard var lineRect = currentVisualLineRect(forCaretAt: charLocation) else { return }
                lineRect.origin.x = 0
                lineRect.size.width = bounds.width
                lineRect.origin.y += textContainerInset.height
                NSColor.bestTextCurrentLine.setFill()
                lineRect.fill()
            }
        }

        // Find highlights — drawn last so nothing overpaints them.
        guard !findHighlightRanges.isEmpty, let tc = textContainer else { return }

        let otherFill = NSColor.bestTextSearchMatch
        let currentFill = NSColor.bestTextSearchCurrent

        let inset = textContainerInset

        // Only the matches on screen are worth laying out. This loop used to call
        // glyphRange/boundingRect for EVERY match on every frame — a short query in a
        // large file yields six figures of them, and scrolling stuttered accordingly.
        // Union with preparedContentRect so responsive scrolling's overdraw band,
        // which is painted before it scrolls into view, still gets its pills.
        let cullRect = (enclosingScrollView?.documentVisibleRect ?? bounds)
            .union(preparedContentRect)
            .union(rect)
            .offsetBy(dx: -inset.width, dy: -inset.height)
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: cullRect, in: tc)
        let visibleChars = layoutManager.characterRange(forGlyphRange: visibleGlyphs,
                                                       actualGlyphRange: nil)

        for (i, charRange) in findHighlightRanges.enumerated() {
            // Plain comparisons, and deliberately not a `break` on the far side:
            // nothing guarantees the caller's ranges are sorted.
            if NSMaxRange(charRange) < visibleChars.location { continue }
            if charRange.location > NSMaxRange(visibleChars) { continue }

            let isCurrent = (i == findCurrentIdx)
            let fillColor = isCurrent ? currentFill : otherFill

            let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange,
                                                      actualCharacterRange: nil)
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, _, _, lineGlyphRange, _ in
                let inter = NSIntersectionRange(glyphRange, lineGlyphRange)
                guard inter.length > 0 else { return }
                let glyphRect = layoutManager.boundingRect(forGlyphRange: inter, in: tc)
                    .offsetBy(dx: inset.width, dy: inset.height)
                let lineBounds = lineRect
                    .offsetBy(dx: inset.width, dy: inset.height)
                    .insetBy(dx: 0, dy: 2)
                var pill = glyphRect.insetBy(dx: -2, dy: 0)
                pill.origin.y = lineBounds.minY
                pill.size.height = max(lineBounds.height, 1)
                fillColor.setFill()
                NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
            }
        }
    }

    private func currentVisualLineRect(forCaretAt charLocation: Int) -> NSRect? {
        guard let layoutManager else { return nil }
        let glyphCount = layoutManager.numberOfGlyphs
        guard glyphCount > 0 else { return nil }

        let nsString = (textStorage?.string ?? string) as NSString
        let textLength = nsString.length
        let caret = min(max(charLocation, 0), textLength)
        let glyphIndex: Int

        if caret == textLength,
           textLength > 0 {
            let lastCharacter = nsString.character(at: textLength - 1)
            if lastCharacter == 0x0A || lastCharacter == 0x0D {
                let extraLine = layoutManager.extraLineFragmentRect
                if !extraLine.isEmpty {
                    return extraLine
                }
            }
        }

        if caret > 0, nsString.character(at: caret - 1) != 0x0A {
            glyphIndex = layoutManager.glyphIndexForCharacter(at: caret - 1)
        } else if caret < textLength {
            glyphIndex = layoutManager.glyphIndexForCharacter(at: caret)
        } else {
            glyphIndex = glyphCount - 1
        }

        guard glyphIndex != NSNotFound else { return nil }
        return layoutManager.lineFragmentRect(
            forGlyphAt: min(glyphIndex, glyphCount - 1),
            effectiveRange: nil
        )
    }

    private func currentLineHighlightRect() -> NSRect? {
        guard findHighlightRanges.isEmpty else { return nil }
        let ranges = selectedRanges.map(\.rangeValue)
        guard let primary = ranges.first, primary.length == 0 else { return nil }
        let charLocation = min(primary.location, textStorage?.length ?? string.utf16.count)
        guard var lineRect = currentVisualLineRect(forCaretAt: charLocation) else { return nil }
        lineRect.origin.x = 0
        lineRect.size.width = bounds.width
        lineRect.origin.y += textContainerInset.height
        return lineRect
    }

    private func invalidateCurrentLineHighlight(_ rect: NSRect?) {
        guard let rect else { return }
        setNeedsDisplay(rect.insetBy(dx: 0, dy: -1))
    }

    // MARK: - Selection reporting

    override func setSelectedRange(_ charRange: NSRange) {
        let oldHighlight = currentLineHighlightRect()
        super.setSelectedRange(charRange)
        invalidateCurrentLineHighlight(oldHighlight)
        invalidateCurrentLineHighlight(currentLineHighlightRect())
        if isHandlingMouseSelection {
            displayIfNeeded()
        }
        postSelectionInfo()
    }

    override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting: Bool
    ) {
        let oldHighlight = currentLineHighlightRect()
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        invalidateCurrentLineHighlight(oldHighlight)
        invalidateCurrentLineHighlight(currentLineHighlightRect())
        if isHandlingMouseSelection {
            displayIfNeeded()
        }
        postSelectionInfo()
    }

    override func didChangeText() {
        super.didChangeText()
        textChangeCounter &+= 1
        applyThaiFontFallbackAroundSelection()
        needsDisplay = true
        postSelectionInfo()
    }

    // MARK: - Memoised line lookup

    /// Bumped by `didChangeText`. Together with the storage length it stamps the
    /// `TextLineIndex.Cursor` memo below: a different stamp throws the memo away,
    /// so a stale line number cannot outlive an edit.
    private var textChangeCounter = 0
    private var lineIndexCursor = TextLineIndex.Cursor()
    /// The storage the memo was built against. A tab switch can hand this view a
    /// different NSTextStorage of the same length under the same counter, which
    /// would otherwise look like "nothing changed".
    private var lineIndexStorage: ObjectIdentifier?

    private func lineIndexStamp(totalCount: Int) -> Int {
        let identifier = textStorage.map(ObjectIdentifier.init)
        if identifier != lineIndexStorage {
            lineIndexStorage = identifier
            lineIndexCursor.invalidate()
        }
        return textChangeCounter &* 31 &+ totalCount
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawInvisibleCharacters(in: dirtyRect)
    }

    func applyDocumentVisualSettings() {
        if hasMarkedText() {
            textColor = editorForegroundColor
            insertionPointColor = editorForegroundColor
            return
        }
        font = editorFont
        textColor = editorForegroundColor
        insertionPointColor = editorForegroundColor
        selectedTextAttributes = [
            .backgroundColor: NSColor.bestTextSelectionBackground,
            .foregroundColor: editorForegroundColor
        ]
        applyIndentationVisualSettings()
        applyWordWrapSetting()
        needsDisplay = true
    }

    func editorBaseAttributes() -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: editorFont,
            .foregroundColor: editorForegroundColor,
            .paragraphStyle: indentationParagraphStyle(),
            .ligature: editorFont.isFixedPitch ? 0 : 1
        ]
        if editorFont.isFixedPitch {
            attributes[.kern] = 0
        }
        return attributes
    }

    var editorFont: NSFont {
        preferences?.editorFont()
            ?? font
            ?? NSFont.systemFont(ofSize: 13)
    }

    var editorForegroundColor: NSColor {
        preferences?.editorTextColor(for: effectiveAppearance)
            ?? NSColor.bestTextEditorForeground(for: effectiveAppearance)
    }

    /// Thai text needs a Thai face: the editor font usually has no Thai glyphs,
    /// and its kerning/ligature settings mangle the marks that do render.
    ///
    /// Two things make this cheap enough to run on every `didChangeText`:
    ///
    /// 1. **A single `CFStringFindCharacterFromSet` rejects the whole range**
    ///    when it holds no Thai — which is every keystroke in every non-Thai
    ///    document, i.e. almost all of them.
    /// 2. **The scan reads UTF-16 code units through a `CFStringInlineBuffer`.**
    ///    It used to iterate `storage.string.unicodeScalars`, and that string is
    ///    a lazily-bridged NSString, so every step transcoded from UTF-16 —
    ///    measured at ~6x the cost of a native String (8.3 ms vs 1.3 ms over
    ///    542k characters). Thai is entirely inside the BMP (U+0E00…U+0E7F), so
    ///    a code-unit test is exactly equivalent to a scalar test and needs no
    ///    decoding: a surrogate half can never fall in that block.
    func applyThaiFontFallback(in targetRange: NSRange? = nil) {
        guard let storage = textStorage,
              storage.length > 0,
              let thaiFont = thaiFallbackFont()
        else { return }

        let fullRange = NSRange(location: 0, length: storage.length)
        let boundedRange = NSIntersectionRange(targetRange ?? fullRange, fullRange)
        guard boundedRange.length > 0 else { return }

        let cfString = storage.string as CFString
        let searchRange = CFRange(location: boundedRange.location, length: boundedRange.length)

        // Nothing Thai in range: this pass only ever ADDS the Thai font, never
        // removes it, so skipping is exactly equivalent to running the loop.
        var firstThai = CFRange(location: kCFNotFound, length: 0)
        guard CFStringFindCharacterFromSet(
            cfString, Self.thaiCharacterSet, searchRange, [], &firstThai
        ) else { return }

        var buffer = CFStringInlineBuffer()
        CFStringInitInlineBuffer(cfString, &buffer, searchRange)

        let base = boundedRange.location
        var runStart: Int?
        var pendingRuns: [NSRange] = []

        // Start at the first Thai unit the search already found; everything
        // before it is known not to be Thai.
        var index = max(firstThai.location - base, 0)
        while index < boundedRange.length {
            let unit = CFStringGetCharacterFromInlineBuffer(&buffer, index)
            if unit >= 0x0E00 && unit <= 0x0E7F {
                if runStart == nil { runStart = base + index }
            } else if let start = runStart {
                pendingRuns.append(NSRange(location: start, length: base + index - start))
                runStart = nil
            }
            index += 1
        }
        if let start = runStart {
            pendingRuns.append(NSRange(location: start, length: NSMaxRange(boundedRange) - start))
        }
        guard !pendingRuns.isEmpty else { return }

        storage.beginEditing()
        for run in pendingRuns {
            applyThaiFont(thaiFont, range: run, boundedBy: boundedRange)
        }
        storage.endEditing()
    }

    /// U+0E00…U+0E7F — the whole Thai block, and all of it is BMP.
    private static let thaiCharacterSet: CFCharacterSet = {
        let set = CFCharacterSetCreateMutable(kCFAllocatorDefault)!
        CFCharacterSetAddCharactersInRange(set, CFRange(location: 0x0E00, length: 0x80))
        return CFCharacterSetCreateCopy(kCFAllocatorDefault, set)
    }()

    private func applyThaiFontFallbackAroundSelection() {
        guard let storage = textStorage, storage.length > 0 else { return }
        let selected = selectedRange()
        let safeLocation = min(max(selected.location, 0), storage.length)
        let paragraphRange = (storage.string as NSString).paragraphRange(
            for: NSRange(location: safeLocation, length: 0)
        )
        applyThaiFontFallback(in: paragraphRange)
    }

    private func thaiFallbackFont() -> NSFont? {
        let size = editorFont.pointSize
        return NSFont(name: "Thonburi", size: size)
            ?? NSFont(name: "SukhumvitSet-Text", size: size)
            ?? NSFont(name: "HelveticaNeue", size: size)
    }

    private func applyThaiFont(_ font: NSFont, range: NSRange, boundedBy bounds: NSRange) {
        guard let storage = textStorage else { return }
        let range = NSIntersectionRange(range, bounds)
        guard range.length > 0 else { return }

        storage.addAttribute(.font, value: font, range: range)
        storage.removeAttribute(.kern, range: range)
        storage.addAttribute(.ligature, value: 1, range: range)
    }

    private func indentationParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let indentation = document?.indentation ?? .spaces4
        style.defaultTabInterval = spaceWidth * CGFloat(indentation.unitWidth)
        let fixedLineHeight = editorFixedLineHeight
        style.minimumLineHeight = fixedLineHeight
        style.maximumLineHeight = fixedLineHeight
        style.tabStops = []
        return style
    }

    var editorNaturalLineHeight: CGFloat {
        editorFont.ascender - editorFont.descender + editorFont.leading
    }

    var editorFixedLineHeight: CGFloat {
        ceil(editorNaturalLineHeight * 1.3)
    }

    private var spaceWidth: CGFloat {
        max((" " as NSString).size(withAttributes: [.font: editorFont]).width, 1)
    }

    private func applyIndentationVisualSettings() {
        let paragraphStyle = indentationParagraphStyle()
        defaultParagraphStyle = paragraphStyle

        var attributes = typingAttributes
        attributes[.font] = editorFont
        attributes[.foregroundColor] = editorForegroundColor
        attributes[.paragraphStyle] = paragraphStyle
        attributes[.baselineOffset] = nil
        attributes[.kern] = editorFont.isFixedPitch ? 0 : nil
        attributes[.ligature] = editorFont.isFixedPitch ? 0 : 1
        typingAttributes = attributes

        if let storage = textStorage, storage.length > 0 {
            storage.beginEditing()
            storage.addAttribute(
                .paragraphStyle,
                value: paragraphStyle,
                range: NSRange(location: 0, length: storage.length)
            )
            let fullRange = NSRange(location: 0, length: storage.length)
            storage.removeAttribute(.baselineOffset, range: fullRange)
            if editorFont.isFixedPitch {
                storage.addAttribute(.kern, value: 0, range: fullRange)
            } else {
                storage.removeAttribute(.kern, range: fullRange)
            }
            storage.endEditing()
            layoutManager?.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
        }
    }

    func applyWordWrapSetting() {
        guard let scrollView = enclosingScrollView,
              let textContainer
        else { return }

        if document?.wordWrap ?? true {
            scrollView.hasHorizontalScroller = false
            isHorizontallyResizable = false
            autoresizingMask = [.width]
            textContainer.widthTracksTextView = true
            textContainer.containerSize = NSSize(
                width: max(scrollView.contentSize.width, 1),
                height: CGFloat.greatestFiniteMagnitude
            )
            frame.size.width = max(scrollView.contentSize.width, frame.width)
        } else {
            scrollView.hasHorizontalScroller = true
            isHorizontallyResizable = true
            autoresizingMask = []
            textContainer.widthTracksTextView = false
            textContainer.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            frame.size.width = max(frame.width, scrollView.contentSize.width)
        }
        needsLayout = true
    }

    func toggleInvisibleCharacters() {
        guard let document else { return }
        document.showsInvisibleCharacters.toggle()
        needsDisplay = true
    }

    func toggleWordWrap() {
        guard let document else { return }
        document.wordWrap.toggle()
        applyWordWrapSetting()
    }

    func convertLineEndings(to lineEnding: TextLineEnding) {
        guard let storage = textStorage else { return }
        let converted = TextContentTransforms.convertLineEndings(in: storage.string, to: lineEnding)
        replaceAllText(with: converted)
        document?.lineEnding = lineEnding
    }

    func trimTrailingWhitespace(markDirty: Bool = true) {
        guard let storage = textStorage else { return }
        let lineEnding = document?.lineEnding ?? TextLineEnding.detect(in: storage.string)
        let trimmed = TextContentTransforms.trimTrailingWhitespace(in: storage.string, lineEnding: lineEnding)
        guard trimmed != storage.string else { return }
        replaceAllText(with: trimmed, markDirty: markDirty)
    }

    func convertIndentation(to indentation: TextIndentation) {
        guard let storage = textStorage else { return }
        let converted = TextContentTransforms.convertIndentation(in: storage.string, to: indentation)
        guard converted != storage.string else {
            document?.indentation = indentation
            applyDocumentVisualSettings()
            return
        }
        replaceAllText(with: converted)
        document?.indentation = indentation
        applyDocumentVisualSettings()
    }

    func sortSelectedLines() {
        transformSelectedLines(useWholeDocumentWhenSelectionEmpty: true) { text, lineEnding in
            TextContentTransforms.sortLines(in: text, lineEnding: lineEnding)
        }
    }

    func removeDuplicateSelectedLines() {
        transformSelectedLines(useWholeDocumentWhenSelectionEmpty: true) { text, lineEnding in
            TextContentTransforms.removeDuplicateLines(in: text, lineEnding: lineEnding)
        }
    }

    func convertSelectedMACAddressFormat() {
        DispatchQueue.main.async { [weak self] in
            self?.performMACAddressFormatConversion()
        }
    }

    private func performMACAddressFormatConversion() {
        guard let storage = textStorage else { return }
        let range = macAddressTargetRange(in: storage)
        guard range.location != NSNotFound,
              NSMaxRange(range) <= storage.length
        else { return }

        let source = (storage.string as NSString).substring(with: range)
        guard let options = promptMACAddressConversionOptions() else { return }
        let converted = Self.convertMACAddresses(
            in: source,
            format: options.format,
            letterCase: options.letterCase
        )
        guard converted != source,
              shouldChangeText(in: range, replacementString: converted)
        else { return }

        storage.beginEditing()
        storage.replaceCharacters(in: range, with: converted)
        storage.endEditing()

        setSelectedRange(NSRange(location: range.location, length: (converted as NSString).length))
        didChangeText()
    }

    /// ⇧⌘D — duplicate the line under every cursor.
    ///
    /// This is the ONLY implementation. There used to be a second, multi-cursor
    /// one in `keyDown`, but SwiftUI declares ⇧⌘D as a menu key equivalent, and
    /// menu key equivalents are consumed before the event ever reaches a view — so
    /// that copy never ran and multi-cursor duplication silently did nothing.
    func duplicateCurrentLines() {
        guard let storage = textStorage else { return }
        let ns = storage.string as NSString
        let ranges = (selectedRanges as? [NSRange]) ?? []
        // Both terms used to be OR'd, which is always true once !ranges.isEmpty has
        // passed — an empty file duplicated its empty line and gained a blank one.
        guard !ranges.isEmpty, ns.length > 0 else { return }

        let lineEnding = document?.lineEnding.sequence ?? "\n"

        // One insertion per distinct line: two cursors on the same line duplicate
        // it once, not twice.
        var insertions: [(lineStart: Int, at: Int, text: String)] = []
        var seenLineStarts = Set<Int>()
        for range in ranges {
            let clamped = NSRange(location: min(range.location, ns.length),
                                  length: min(range.length, max(0, ns.length - min(range.location, ns.length))))
            let lineRange = ns.lineRange(for: clamped)
            guard NSMaxRange(lineRange) <= ns.length,
                  seenLineStarts.insert(lineRange.location).inserted
            else { continue }
            let lineText = ns.substring(with: lineRange)
            // The last line of a file has no trailing newline; the copy needs one
            // in front of it or the two lines run together.
            //
            // Test the trailing UTF-16 unit, NOT `hasSuffix("\n")`: a CRLF pair is
            // a single Swift Character equal to neither "\n" nor "\r", so the
            // Character-level check answered false for EVERY line of a CRLF file
            // and ⇧⌘D inserted a spurious blank line between original and copy.
            // Same idiom as `realText(from:)` above.
            let endsWithBreak: Bool = {
                guard lineRange.length > 0 else { return false }
                let unit = ns.character(at: NSMaxRange(lineRange) - 1)
                return unit == 10 || unit == 13
            }()
            insertions.append((
                lineStart: lineRange.location,
                at: NSMaxRange(lineRange),
                text: endsWithBreak ? lineText : lineEnding + lineText
            ))
        }
        guard !insertions.isEmpty else { return }
        insertions.sort { $0.at < $1.at }

        // Apply back-to-front so the offsets computed above stay valid, and as
        // ONE storage editing group: without it every line re-ran layout,
        // syntax and the gutter's caches, so ⇧⌘D with N cursors did N full
        // relayouts. `shouldChangeText` stays per range — it is what registers
        // undo and refuses compare-mode filler lines, and one refusal must not
        // take the other lines with it.
        var appliedByLineStart: [Int: Int] = [:]   // lineStart → inserted UTF-16 length
        var didEdit = false
        storage.beginEditing()
        for insertion in insertions.reversed() {
            let target = NSRange(location: insertion.at, length: 0)
            guard shouldChangeText(in: target, replacementString: insertion.text) else { continue }
            storage.replaceCharacters(in: target, with: insertion.text)
            appliedByLineStart[insertion.lineStart] = (insertion.text as NSString).length
            didEdit = true
        }
        storage.endEditing()
        guard didEdit else { return }

        // Move every cursor onto its copy. A cursor shifts by the text inserted
        // for its OWN line (which lands after it) plus everything inserted before
        // it — computing that from the edit list keeps cursors that were skipped
        // by the dedupe or by a filler line, which the old code dropped entirely.
        let newRanges: [NSRange] = ranges.map { range in
            let clamped = min(range.location, ns.length)
            let lineStart = ns.lineRange(for: NSRange(location: clamped, length: 0)).location
            var shift = appliedByLineStart[lineStart] ?? 0
            for insertion in insertions where insertion.at <= clamped {
                shift += appliedByLineStart[insertion.lineStart] ?? 0
            }
            let location = min(range.location + shift, storage.length)
            return NSRange(location: location, length: min(range.length, storage.length - location))
        }
        setSelectedRanges(newRanges as [NSValue], affinity: .downstream, stillSelecting: false)
        didChangeText()
    }

    /// ⇧⌘K — delete the line under every cursor. See `duplicateCurrentLines` for
    /// why this is the only implementation.
    func deleteCurrentLines() {
        guard let storage = textStorage else { return }
        let ns = storage.string as NSString
        let ranges = (selectedRanges as? [NSRange]) ?? []
        guard !ranges.isEmpty, ns.length > 0 else { return }

        // Distinct lines only: two cursors on one line must not delete it twice —
        // the second pass would run against stale coordinates and swallow the
        // following line.
        var lineRanges: [NSRange] = []
        var seenLineStarts = Set<Int>()
        for range in ranges {
            let clamped = NSRange(location: min(range.location, ns.length),
                                  length: min(range.length, max(0, ns.length - min(range.location, ns.length))))
            let lineRange = ns.lineRange(for: clamped)
            guard NSMaxRange(lineRange) <= ns.length,
                  seenLineStarts.insert(lineRange.location).inserted
            else { continue }
            lineRanges.append(lineRange)
        }
        guard !lineRanges.isEmpty else { return }
        lineRanges.sort { $0.location < $1.location }

        // One editing group; see `duplicateCurrentLines` for why the
        // `shouldChangeText` calls stay inside it and stay per range.
        var deletedLengthByStart: [Int: Int] = [:]
        var didEdit = false
        storage.beginEditing()
        for lineRange in lineRanges.reversed() {
            guard shouldChangeText(in: lineRange, replacementString: "") else { continue }
            storage.replaceCharacters(in: lineRange, with: "")
            deletedLengthByStart[lineRange.location] = lineRange.length
            didEdit = true
        }
        storage.endEditing()
        guard didEdit else { return }

        // A cursor per deleted line, each pulled back by everything deleted above it.
        var caretRanges: [NSRange] = []
        var removedSoFar = 0
        for lineRange in lineRanges {
            guard let removed = deletedLengthByStart[lineRange.location] else { continue }
            let location = max(0, min(lineRange.location - removedSoFar, storage.length))
            removedSoFar += removed
            if caretRanges.last?.location != location {
                caretRanges.append(NSRange(location: location, length: 0))
            }
        }
        if caretRanges.isEmpty {
            caretRanges = [NSRange(location: min(lineRanges[0].location, storage.length), length: 0)]
        }
        setSelectedRanges(caretRanges as [NSValue], affinity: .downstream, stillSelecting: false)
        didChangeText()
    }

    func goToLine(_ lineNumber: Int) {
        guard lineNumber > 0 else { return }
        let ns = (textStorage?.string ?? string) as NSString
        var currentLine = 1
        var location = 0

        while currentLine < lineNumber, location < ns.length {
            let range = ns.rangeOfCharacter(
                from: CharacterSet.newlines,
                options: [],
                range: NSRange(location: location, length: ns.length - location)
            )
            guard range.location != NSNotFound else {
                location = ns.length
                break
            }
            location = range.location + range.length
            currentLine += 1
        }

        let caret = min(location, ns.length)
        setSelectedRange(NSRange(location: caret, length: 0))
        scrollRangeToVisible(NSRange(location: caret, length: 0))
        window?.makeFirstResponder(self)
    }

    /// Space / tab / line-ending markers for the visible text.
    ///
    /// Two things used to make this the most expensive part of a frame on an
    /// indented file:
    ///
    /// - the visible range was walked with `NSString.character(at:)`, one
    ///   objc_msgSend per UTF-16 unit — thousands per frame, all of them
    ///   discarded;
    /// - every marker asked the layout manager for `glyphRange(forCharacterRange:)`
    ///   and then `boundingRect(forGlyphRange:in:)`, and a bounding rect is a
    ///   union computed across line fragments.
    ///
    /// Now: one chunked `getCharacters` pass collects the marker positions, then
    /// ONE `enumerateLineFragments` walk places them — the fragment rect comes
    /// from the enumeration and the x offset from `location(forGlyphAt:)`, which
    /// is a lookup inside the fragment rather than a rect computation.
    private func drawInvisibleCharacters(in dirtyRect: NSRect) {
        guard document?.showsInvisibleCharacters == true,
              document?.isLargeFileModeActive != true,
              let storage = textStorage,
              storage.length > 0,
              let layoutManager,
              let textContainer
        else { return }

        let text = storage.string as NSString
        let inset = textContainerInset
        let queryRect = dirtyRect.offsetBy(dx: -inset.width, dy: -inset.height)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: queryRect, in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let start = max(0, charRange.location)
        let end = min(storage.length, NSMaxRange(charRange))
        guard start < end else { return }

        let markers = invisibleMarkerPositions(in: text, from: start, to: end)
        guard !markers.isEmpty else { return }

        let markerFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: markerFont,
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.55)
        ]

        // Shaped once per draw, not once per character. `size(withAttributes:)`
        // and `draw(at:withAttributes:)` each build and lay out a throwaway
        // attributed string; doing that for every space on screen meant thousands
        // of text-shaping calls per frame on an indented file.
        let spaceMarker  = PreparedMarker("·", attributes: attrs)
        let tabMarker    = PreparedMarker("→", attributes: attrs)
        let returnMarker = PreparedMarker("↵", attributes: attrs)

        var next = 0
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
            rect, usedRect, _, lineGlyphRange, stop in
            guard next < markers.count else { stop.pointee = true; return }
            let lineCharRange = layoutManager.characterRange(
                forGlyphRange: lineGlyphRange, actualGlyphRange: nil
            )
            let lineCharEnd = NSMaxRange(lineCharRange)

            // Markers that fell before this fragment (shouldn't happen, but the
            // enumeration and the scan are two different walks) are dropped.
            while next < markers.count, markers[next].location < lineCharRange.location {
                next += 1
            }

            while next < markers.count, markers[next].location < lineCharEnd {
                let marker = markers[next]
                next += 1
                switch marker.kind {
                case .lineEnding:
                    let point = NSPoint(x: usedRect.maxX + inset.width + 4,
                                        y: usedRect.minY + inset.height)
                    returnMarker.string.draw(at: point)
                case .space, .tab:
                    let prepared = marker.kind == .space ? spaceMarker : tabMarker
                    let glyphIndex = layoutManager.glyphIndexForCharacter(at: marker.location)
                    guard glyphIndex != NSNotFound,
                          glyphIndex >= lineGlyphRange.location,
                          glyphIndex < NSMaxRange(lineGlyphRange)
                    else { continue }
                    let leading = layoutManager.location(forGlyphAt: glyphIndex).x
                    let trailing: CGFloat = glyphIndex + 1 < NSMaxRange(lineGlyphRange)
                        ? layoutManager.location(forGlyphAt: glyphIndex + 1).x
                        : usedRect.maxX - rect.minX
                    let centreX = rect.minX + (leading + max(trailing, leading)) / 2
                    let point = NSPoint(
                        x: centreX + inset.width - (prepared.size.width / 2),
                        y: rect.midY + inset.height - (prepared.size.height / 2)
                    )
                    prepared.string.draw(at: point)
                }
            }
        }
    }

    private enum InvisibleMarkerKind {
        case space, tab, lineEnding
    }

    private struct InvisibleMarker {
        let location: Int
        let kind: InvisibleMarkerKind
    }

    /// Chunked scan for the units that get a marker. `getCharacters` pulls 4 KB
    /// at a time and allocates nothing beyond the reusable buffer; the loop this
    /// replaced sent one Objective-C message per visible UTF-16 unit.
    private func invisibleMarkerPositions(
        in text: NSString, from start: Int, to end: Int
    ) -> [InvisibleMarker] {
        var markers: [InvisibleMarker] = []
        let chunkSize = 4096
        var buffer = [unichar](repeating: 0, count: chunkSize)
        var position = start

        while position < end {
            let length = min(chunkSize, end - position)
            let base = position
            buffer.withUnsafeMutableBufferPointer { p in
                text.getCharacters(p.baseAddress!, range: NSRange(location: base, length: length))
                var k = 0
                while k < length {
                    let unit = p[k]
                    // One comparison rejects every printable character.
                    if unit > 32 { k += 1; continue }
                    switch unit {
                    case 32:
                        markers.append(InvisibleMarker(location: base + k, kind: .space))
                    case 9:
                        markers.append(InvisibleMarker(location: base + k, kind: .tab))
                    case 10:
                        markers.append(InvisibleMarker(location: base + k, kind: .lineEnding))
                    case 13:
                        // CRLF gets ONE marker, and it goes on the LF (case 10
                        // above) — same placement as before this rewrite. The
                        // partner is read from the string rather than the chunk
                        // so a pair split across a chunk boundary still resolves.
                        let next = base + k + 1
                        if next >= text.length || text.character(at: next) != 10 {
                            markers.append(InvisibleMarker(location: base + k, kind: .lineEnding))
                        }
                    default:
                        break
                    }
                    k += 1
                }
            }
            position += length
        }
        return markers
    }

    /// A marker glyph with its attributes applied and its size measured once.
    private struct PreparedMarker {
        let string: NSAttributedString
        let size: NSSize

        init(_ marker: String, attributes: [NSAttributedString.Key: Any]) {
            let attributed = NSAttributedString(string: marker, attributes: attributes)
            self.string = attributed
            self.size = attributed.size()
        }
    }

    private func replaceAllText(with replacement: String, markDirty: Bool = true) {
        let fullRange = NSRange(location: 0, length: textStorage?.length ?? 0)
        replaceText(in: fullRange, with: replacement, markDirty: markDirty)
        setSelectedRange(NSRange(location: min(selectedRange().location, (replacement as NSString).length), length: 0))
    }

    private func replaceText(in range: NSRange, with replacement: String, markDirty: Bool = true) {
        guard let storage = textStorage,
              range.location >= 0,
              NSMaxRange(range) <= storage.length,
              shouldChangeText(in: range, replacementString: replacement)
        else { return }

        storage.beginEditing()
        storage.replaceCharacters(in: range, with: replacement)
        storage.endEditing()

        // NO `document?.text = storage.string` here.
        //
        // The storage string is DISPLAY text: in compare mode it carries the
        // filler rows, and with a fold collapsed it carries a U+FFFC
        // placeholder instead of the folded block. `document.text` is derived
        // from it — `realText(from:)` / `FoldingManager.fullText(from:)` — and
        // that derivation lives in the coordinator's `textDidChange`, which
        // `didChangeText()` below reaches. Assigning here put the display text
        // into the model (and into the draft, and onto disk) for the instant
        // before the coordinator corrected it, and permanently for any path
        // where the coordinator bails out early.
        if markDirty {
            document?.isDirty = true
        }
        didChangeText()
    }

    private func transformSelectedLines(
        useWholeDocumentWhenSelectionEmpty: Bool,
        transform: (String, TextLineEnding) -> String
    ) {
        guard let storage = textStorage else { return }
        let range = selectedLineRange(useWholeDocumentWhenSelectionEmpty: useWholeDocumentWhenSelectionEmpty)
        guard range.location != NSNotFound, NSMaxRange(range) <= storage.length else { return }
        let source = (storage.string as NSString).substring(with: range)
        let lineEnding = document?.lineEnding ?? TextLineEnding.detect(in: storage.string)
        let replacement = transform(source, lineEnding)
        replaceText(in: range, with: replacement)
        setSelectedRange(NSRange(location: range.location, length: (replacement as NSString).length))
    }

    private func selectedLineRange(useWholeDocumentWhenSelectionEmpty: Bool) -> NSRange {
        guard let storage = textStorage else { return NSRange(location: NSNotFound, length: 0) }
        let ns = storage.string as NSString
        guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
        let selected = selectedRange()
        if selected.length == 0, useWholeDocumentWhenSelectionEmpty {
            return NSRange(location: 0, length: ns.length)
        }
        let start = min(selected.location, ns.length)
        let length = min(selected.length, ns.length - start)
        return ns.paragraphRange(for: NSRange(location: start, length: length))
    }

    private func macAddressTargetRange(in storage: NSTextStorage) -> NSRange {
        let selected = selectedRange()
        if selected.length > 0 {
            return selected
        }

        let text = storage.string as NSString
        let cursor = min(selected.location, text.length)
        let lineRange = text.lineRange(for: NSRange(location: cursor, length: 0))
        let line = text.substring(with: lineRange) as NSString
        let patterns = [
            #"[0-9A-Fa-f]{2}([:-][0-9A-Fa-f]{2}){5}"#,
            #"[0-9A-Fa-f]{4}(\.[0-9A-Fa-f]{4}){2}"#,
            #"(?<![0-9A-Fa-f])[0-9A-Fa-f]{12}(?![0-9A-Fa-f])"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(in: line as String, range: NSRange(location: 0, length: line.length))
            if let match = matches.first(where: {
                let absolute = NSRange(location: lineRange.location + $0.range.location, length: $0.range.length)
                return cursor >= absolute.location && cursor <= NSMaxRange(absolute)
            }) {
                return NSRange(location: lineRange.location + match.range.location, length: match.range.length)
            }
        }

        return NSRange(location: NSNotFound, length: 0)
    }

    private func promptMACAddressConversionOptions() -> MACAddressConversionOptions? {
        let alert = NSAlert()
        alert.messageText = "Convert MAC Address"
        alert.informativeText = "Choose the output format."
        alert.addButton(withTitle: "Convert")
        alert.addButton(withTitle: "Cancel")

        let formatPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 26), pullsDown: false)
        formatPopup.translatesAutoresizingMaskIntoConstraints = false
        for format in MACAddressFormat.allCases {
            formatPopup.addItem(withTitle: format.displayName)
            formatPopup.lastItem?.representedObject = format.rawValue
        }

        let casePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 26), pullsDown: false)
        casePopup.translatesAutoresizingMaskIntoConstraints = false
        for letterCase in MACAddressLetterCase.allCases {
            casePopup.addItem(withTitle: letterCase.displayName)
            casePopup.lastItem?.representedObject = letterCase.rawValue
        }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.addArrangedSubview(Self.popupRow(label: "Format:", popup: formatPopup))
        stack.addArrangedSubview(Self.popupRow(label: "Case:", popup: casePopup))
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 68)
        NSLayoutConstraint.activate([
            formatPopup.widthAnchor.constraint(equalToConstant: 240),
            casePopup.widthAnchor.constraint(equalToConstant: 240)
        ])
        alert.accessoryView = stack

        guard alert.runModal() == .alertFirstButtonReturn,
              let formatRaw = formatPopup.selectedItem?.representedObject as? String,
              let format = MACAddressFormat(rawValue: formatRaw),
              let caseRaw = casePopup.selectedItem?.representedObject as? String,
              let letterCase = MACAddressLetterCase(rawValue: caseRaw)
        else { return nil }

        return MACAddressConversionOptions(format: format, letterCase: letterCase)
    }

    private static func popupRow(label: String, popup: NSPopUpButton) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let labelView = NSTextField(labelWithString: label)
        labelView.alignment = .right
        labelView.frame.size.width = 54
        row.addArrangedSubview(labelView)
        row.addArrangedSubview(popup)
        return row
    }

    private static func convertMACAddresses(
        in text: String,
        format: MACAddressFormat,
        letterCase: MACAddressLetterCase
    ) -> String {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let pattern = #"[0-9A-Fa-f]{2}([:-][0-9A-Fa-f]{2}){5}|[0-9A-Fa-f]{4}(\.[0-9A-Fa-f]{4}){2}|(?<![0-9A-Fa-f])[0-9A-Fa-f]{12}(?![0-9A-Fa-f])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }

        var result = text
        for match in regex.matches(in: text, range: fullRange).reversed() {
            let source = nsText.substring(with: match.range)
            guard let converted = formatMACAddress(source, as: format, letterCase: letterCase) else { continue }
            let start = result.index(result.startIndex, offsetBy: match.range.location)
            let end = result.index(start, offsetBy: match.range.length)
            result.replaceSubrange(start..<end, with: converted)
        }
        return result
    }

    private static func formatMACAddress(
        _ source: String,
        as format: MACAddressFormat,
        letterCase: MACAddressLetterCase
    ) -> String? {
        let hex = letterCase.apply(to: String(source.filter(\.isHexDigit)))
        guard hex.count == 12 else { return nil }

        let pairs = stride(from: 0, to: hex.count, by: 2).map { offset -> String in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            return String(hex[start..<end])
        }
        let quartets = stride(from: 0, to: hex.count, by: 4).map { offset -> String in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 4)
            return String(hex[start..<end])
        }

        switch format {
        case .colon:
            return pairs.joined(separator: ":")
        case .hyphen:
            return pairs.joined(separator: "-")
        case .dot:
            return quartets.joined(separator: ".")
        case .plain:
            return hex
        }
    }

    private struct MACAddressConversionOptions {
        var format: MACAddressFormat
        var letterCase: MACAddressLetterCase
    }

    private enum MACAddressFormat: String, CaseIterable {
        case colon
        case hyphen
        case dot
        case plain

        var displayName: String {
            switch self {
            case .colon:  "Colon: 00:11:22:33:44:55"
            case .hyphen: "Hyphen: 00-11-22-33-44-55"
            case .dot:    "Dot: 0011.2233.4455"
            case .plain:  "Plain: 001122334455"
            }
        }
    }

    private enum MACAddressLetterCase: String, CaseIterable {
        case lowercase
        case uppercase

        var displayName: String {
            switch self {
            case .lowercase: "Lowercase"
            case .uppercase: "Uppercase"
            }
        }

        func apply(to string: String) -> String {
            switch self {
            case .lowercase: string.lowercased()
            case .uppercase: string.uppercased()
            }
        }
    }

    /// Compute line / column / selected-count / total-count and post them.
    /// Callers on the status-bar side listen to the notification and push
    /// the values into CursorState (which must be touched on main).
    private func postSelectionInfo() {
        let str = (textStorage?.string ?? string) as NSString
        let totalCount = str.length
        let selectedRanges = (self.selectedRanges as? [NSRange]) ?? []
        let primary = selectedRanges.first ?? NSRange(location: 0, length: 0)

        // This runs on every selection change AND on every text change — at
        // least twice per keystroke. It used to walk the prefix one
        // `character(at:)` at a time, which is one ObjC message per UTF-16 unit:
        // with the caret near the end of a 1 MB file that is a million message
        // sends per keystroke, on the main thread.
        //
        // TextLineIndex pulls the text in 4 KB chunks through getCharacters and
        // allocates nothing. It also reports the column in grapheme clusters,
        // which is what Coordinator.push (and therefore the status bar) already
        // reports — the two used to disagree on any line containing a Thai
        // combining mark or an emoji.
        // The scan is O(offset) from the start of the document, and this runs at
        // least twice per keystroke — 4.6 ms each with the caret at the end of a
        // 5 MB file. `TextLineIndex.Cursor` memoises the last result and scans
        // only the delta; the stamp below is what makes an edit drop the memo.
        let loc = min(primary.location, totalCount)
        let stamp = lineIndexStamp(totalCount: totalCount)
        let (line, lineStart) = lineIndexCursor.lineAndStart(in: str, at: loc, stamp: stamp)
        // Column counts grapheme clusters, so Thai combining marks and emoji are
        // one column each — same definition TextLineIndex.lineColumn uses.
        let column = str.substring(with: NSRange(location: lineStart, length: loc - lineStart)).count + 1
        let position = (line: line, column: column)

        let selectedCount = selectedRanges.reduce(0) { $0 + $1.length }

        NotificationCenter.default.post(
            name: Self.selectionDidChange,
            object: self,
            userInfo: [
                "line": position.line,
                "column": position.column,
                "selectedCount": selectedCount,
                "totalCount": totalCount
            ]
        )
    }

    // MARK: - Multi-cursor

    /// ⌘D — add the next occurrence of the currently selected text as a cursor.
    /// If nothing is selected, selects the word under the caret first.
    @objc func addNextMatch() {
        guard let storage = textStorage else { return }
        let fullText = storage.string as NSString
        var ranges = (selectedRanges as? [NSRange]) ?? []
        guard let lastRange = ranges.last else { return }

        // If last selection is empty, select the current word.
        if lastRange.length == 0 {
            let wordRange = fullText.rangeOfWord(around: lastRange.location)
            if wordRange.length > 0 {
                ranges[ranges.count - 1] = wordRange
                setSelectedRanges(ranges as [NSValue], affinity: .downstream, stillSelecting: false)
                return
            }
        }

        let needle = fullText.substring(with: lastRange)
        guard !needle.isEmpty else { return }
        let searchStart = lastRange.location + lastRange.length
        let searchRange = NSRange(location: searchStart, length: fullText.length - searchStart)
        var next = fullText.range(of: needle, options: [], range: searchRange)

        // Wrap around to the beginning if not found.
        if next.location == NSNotFound {
            next = fullText.range(of: needle, options: [], range: NSRange(location: 0, length: lastRange.location))
        }
        guard next.location != NSNotFound else { return }

        ranges.append(next)
        setSelectedRanges(ranges as [NSValue], affinity: .downstream, stillSelecting: false)
        scrollRangeToVisible(next)
    }

    /// ⌘⌃⌥G — add all occurrences.
    @objc func addAllMatches() {
        guard let storage = textStorage else { return }
        let fullText = storage.string as NSString
        let ranges = (selectedRanges as? [NSRange]) ?? []
        guard let lastRange = ranges.last, lastRange.length > 0 else { return }
        let needle = fullText.substring(with: lastRange)

        var found: [NSRange] = []
        var searchFrom = 0
        while searchFrom < fullText.length {
            let r = fullText.range(
                of: needle,
                options: [],
                range: NSRange(location: searchFrom, length: fullText.length - searchFrom)
            )
            if r.location == NSNotFound { break }
            found.append(r)
            searchFrom = r.location + r.length
        }
        if !found.isEmpty {
            setSelectedRanges(found as [NSValue], affinity: .downstream, stillSelecting: false)
        }
    }

    // MARK: - Convert case

    @objc func convertSelectionToUppercase() {
        convertSelection(toUpper: true)
    }

    @objc func convertSelectionToLowercase() {
        convertSelection(toUpper: false)
    }

    @objc func convertSelectionToTitlecase() {
        guard let storage = textStorage else { return }
        let selectedRange = selectedRange()
        guard selectedRange.length > 0,
              NSMaxRange(selectedRange) <= storage.length else { return }
        let nsText = storage.string as NSString
        let selectedText = nsText.substring(with: selectedRange)
        let converted = selectedText.capitalized
        guard converted != selectedText else { return }
        guard shouldChangeText(in: selectedRange, replacementString: converted) else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: selectedRange, with: converted)
        storage.endEditing()
        let convertedLength = (converted as NSString).length
        setSelectedRange(NSRange(location: selectedRange.location, length: convertedLength))
        didChangeText()
    }

    private func convertSelection(toUpper: Bool) {
        guard let storage = textStorage else { return }

        let selectedRange = selectedRange()
        guard selectedRange.length > 0,
              NSMaxRange(selectedRange) <= storage.length else { return }

        let nsText = storage.string as NSString
        let selectedText = nsText.substring(with: selectedRange)
        let converted = toUpper ? selectedText.uppercased() : selectedText.lowercased()
        guard converted != selectedText else { return }
        guard shouldChangeText(in: selectedRange, replacementString: converted) else { return }

        storage.beginEditing()
        storage.replaceCharacters(in: selectedRange, with: converted)
        storage.endEditing()

        let convertedLength = (converted as NSString).length
        setSelectedRange(NSRange(location: selectedRange.location, length: convertedLength))
        didChangeText()
    }

    // MARK: - Copy / Paste (filler-line + fold aware)

    /// Copy every selected range, not just the primary one.
    ///
    /// AppKit's own `copy:` already joins a multi-range selection with newlines,
    /// so the bug only bit once this override took over — i.e. exactly when
    /// there were folds or compare-mode filler lines in play, where it read
    /// `selectedRange()` and silently dropped every cursor but the first.
    override func copy(_ sender: Any?) {
        guard let storage = textStorage else { super.copy(sender); return }

        let ranges = ((selectedRanges as? [NSRange]) ?? [selectedRange()])
            .filter { $0.length > 0 && $0.location != NSNotFound }
            .sorted { $0.location < $1.location }
        guard !ranges.isEmpty else { super.copy(sender); return }

        let hasFolds: Bool = foldingManager?.regions.isEmpty == false
        var hasFillers = false
        for range in ranges where !hasFillers {
            let bounded = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
            guard bounded.length > 0 else { continue }
            storage.enumerateAttribute(.isFillerLine, in: bounded, options: []) { val, _, stop in
                if val != nil { hasFillers = true; stop.pointee = true }
            }
        }
        guard hasFolds || hasFillers else { super.copy(sender); return }

        let text = ranges
            .map { foldAndFillerAwareText(of: $0, in: storage) }
            .joined(separator: "\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// One selection's real text: filler paragraphs skipped, fold placeholders
    /// expanded back to what they stand for.
    private func foldAndFillerAwareText(of range: NSRange, in storage: NSTextStorage) -> String {
        let ns    = storage.string as NSString
        let end   = min(NSMaxRange(range), ns.length)
        var pos   = max(range.location, 0)
        var text  = ""

        let foldRegions = ((foldingManager?.regions ?? [])
            .filter { $0.displayLocation >= pos && $0.displayLocation < end }
            .sorted { $0.displayLocation < $1.displayLocation })
        var foldIdx = 0

        while pos < end {
            let paraRange = ns.paragraphRange(for: NSRange(location: pos, length: 0))
            if storage.attribute(.isFillerLine, at: paraRange.location, effectiveRange: nil) != nil {
                pos = min(NSMaxRange(paraRange), end)
                continue
            }
            let segEnd = min(end, NSMaxRange(paraRange))
            while foldIdx < foldRegions.count && foldRegions[foldIdx].displayLocation < segEnd {
                let region = foldRegions[foldIdx]
                if region.displayLocation > pos {
                    text += ns.substring(with: NSRange(location: pos,
                                                       length: region.displayLocation - pos))
                }
                text += region.originalText
                pos = region.displayLocation + 1
                foldIdx += 1
            }
            if pos < segEnd {
                text += ns.substring(with: NSRange(location: pos, length: segEnd - pos))
            }
            pos = segEnd
        }
        return text
    }

    override func paste(_ sender: Any?) {
        guard let storage = textStorage,
              let text = NSPasteboard.general.string(forType: .string)
        else {
            super.paste(sender)
            return
        }

        let loc = selectedRange().location
        if loc < storage.length,
           storage.attribute(.isFillerLine, at: loc, effectiveRange: nil) != nil {
            // Cursor is on a filler line — advance to the start of the next real line.
            // (This collapses to one caret, which is correct: the paste has
            // nowhere valid to go at the others either.)
            let ns = storage.string as NSString
            let paraRange = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            setSelectedRange(NSRange(location: min(NSMaxRange(paraRange), storage.length), length: 0))
        }

        // NSNotFound, not selectedRange(): an explicit range is the primary
        // cursor only, so a multi-cursor paste used to land in one place and
        // drop the other cursors. `suppressesThaiSanitizer` keeps the
        // combining-mark de-duplication off — pasted text is reproduced
        // verbatim, doubled marks included.
        suppressesThaiSanitizer = true
        defer { suppressesThaiSanitizer = false }
        insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    // MARK: - Fold placeholder click

    override func mouseDown(with event: NSEvent) {
        EditorCommandTarget.register(self)
        let point = convert(event.locationInWindow, from: nil)
        if shouldClampClickToDocumentEnd(at: point) {
            window?.makeFirstResponder(self)
            isHandlingMouseSelection = true
            setSelectedRange(NSRange(location: textStorage?.length ?? string.utf16.count, length: 0))
            isHandlingMouseSelection = false
            return
        }
        if let fm = foldingManager,
           let storage = textStorage,
           let lm = layoutManager,
           let tc = textContainer {
            let glyphIdx = lm.glyphIndex(for: point, in: tc)
            if glyphIdx < lm.numberOfGlyphs {
                let charIdx = lm.characterIndexForGlyph(at: glyphIdx)
                if charIdx < storage.length,
                   storage.attribute(.attachment, at: charIdx, effectiveRange: nil) is FoldPlaceholder {
                    fm.unfold(at: charIdx, in: storage)
                    discardUndoHistory()
                    // See `FoldingManager.armFoldMutationFlag` — only the paths
                    // that emit a change notification arm the handshake.
                    fm.armFoldMutationFlag()
                    didChangeText()
                    return
                }
            }
        }
        let oldHighlight = currentLineHighlightRect()
        isHandlingMouseSelection = true
        super.mouseDown(with: event)
        isHandlingMouseSelection = false
        invalidateCurrentLineHighlight(oldHighlight)
        invalidateCurrentLineHighlight(currentLineHighlightRect())
        displayIfNeeded()
    }

    func shouldClampClickToDocumentEnd(at point: NSPoint) -> Bool {
        guard let layoutManager, textContainer != nil, let storage = textStorage else { return false }
        guard storage.length > 0 else { return false }

        // This used to open with `ensureLayout(for: textContainer)` — glyph
        // generation and layout for the WHOLE document, on the main thread, to
        // answer one mouse click. Layout is invalidated by every edit, so the
        // first click after each keystroke paid for it again: ~1.2 s on a 5 MB
        // file (measured, see PerfHarnessTextViewTests).
        //
        // It is not needed. Layout is lazy but the visible rect is always laid
        // out — drawing forced it — and a mouse click is inside the visible
        // rect. So while there is text still unlaid BELOW what is on screen,
        // the click cannot possibly be past the end of the document. And once
        // `firstUnlaidCharacterIndex` has reached the end, the whole document
        // IS laid out and `extraLineFragmentRect` / `lineFragmentRect` below
        // are valid without asking for anything more.
        guard layoutManager.firstUnlaidCharacterIndex() >= storage.length else { return false }

        let ns = storage.string as NSString
        let lastCharacter = ns.character(at: storage.length - 1)
        let endsWithNewline = lastCharacter == 0x0A || lastCharacter == 0x0D
        let contentY = point.y - textContainerInset.height
        let validContentBottom: CGFloat?

        if endsWithNewline {
            let extraLine = layoutManager.extraLineFragmentRect
            validContentBottom = extraLine.isEmpty ? nil : extraLine.maxY
        } else {
            let lastGlyph = layoutManager.glyphIndexForCharacter(at: storage.length - 1)
            if lastGlyph == NSNotFound || lastGlyph >= layoutManager.numberOfGlyphs {
                validContentBottom = nil
            } else {
                validContentBottom = layoutManager.lineFragmentRect(
                    forGlyphAt: lastGlyph,
                    effectiveRange: nil
                ).maxY
            }
        }

        guard let validContentBottom else { return false }
        return contentY > validContentBottom
    }

    // MARK: - Key handling

    override func keyDown(with event: NSEvent) {
        // Keeps EditorCommandTarget pointing at whichever pane the user is typing
        // in, which is how menu commands and the find bar find their target.
        EditorCommandTarget.register(self)
        super.keyDown(with: event)
    }

    // ⇧⌘D / ⇧⌘K used to be intercepted here and routed to private multi-cursor
    // copies of duplicate/delete line. SwiftUI declares both as menu key
    // equivalents, which AppKit consumes before the event reaches any view, so
    // that code was unreachable. The multi-cursor behaviour now lives in
    // duplicateCurrentLines()/deleteCurrentLines(), which is what the menu and
    // the command palette call.
}

private extension NSString {
    /// Finds the word (`[A-Za-z0-9_]+`) around the given index.
    func rangeOfWord(around index: Int) -> NSRange {
        guard index <= length else { return NSRange(location: index, length: 0) }
        let cs = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        var start = index
        while start > 0 {
            let c = character(at: start - 1)
            if let scalar = Unicode.Scalar(c), cs.contains(scalar) { start -= 1 } else { break }
        }
        var end = index
        while end < length {
            let c = character(at: end)
            if let scalar = Unicode.Scalar(c), cs.contains(scalar) { end += 1 } else { break }
        }
        return NSRange(location: start, length: end - start)
    }
}
