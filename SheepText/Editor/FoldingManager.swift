//
//  FoldingManager.swift
//  Manages code-folding state for one editor instance.
//
//  Design:
//  - A fold replaces a multi-line brace block in NSTextStorage with a 1-char
//    NSTextAttachment placeholder (FoldPlaceholder).
//  - Each FoldRegion remembers the original text so it can be restored.
//  - `isMutating` lets the coordinator skip document-text sync during fold ops.
//  - `fullText(from:)` reconstructs the real (unfolded) text for saving.
//

import AppKit

nonisolated private struct FoldMainActorNotification: @unchecked Sendable {
    let value: Notification
}

/// Explicitly `@MainActor` rather than relying on the target's default
/// isolation: `isolated deinit` (which removes the edit observer) needs the
/// isolation stated on the type, and without it a whole-module Release build
/// rejects it while an incremental Debug build accepts it. The setting already
/// put this class on the main actor — this only says so out loud.
@MainActor
final class FoldingManager {

    /// The attachment character a collapsed fold stands behind.
    private static let placeholderUnit: unichar = 0xFFFC

    // MARK: - Types

    struct FoldRegion {
        var displayLocation: Int     // index of the attachment char in textStorage
        let originalText: String     // the text the attachment stands for
        let originalAttributedText: NSAttributedString

        var displayRange: NSRange { NSRange(location: displayLocation, length: 1) }

        /// Length of `originalText` in UTF-16 units — the unit `displayLocation`
        /// and every NSRange here is measured in.
        ///
        /// `originalText.count` is a grapheme-cluster count and is NOT the same
        /// number: "\r\n" is one Character but two UTF-16 units, and so is any
        /// emoji or Thai base+combining pair. Using it to shift `displayLocation`
        /// silently misplaced every fold after the first one in such a file, so
        /// unfolding restored the text at the wrong offset. Computed once at
        /// construction because both call sites are in shifting loops.
        let originalUTF16Length: Int

        /// How many line breaks this region swallows.
        ///
        /// Same trap as `originalUTF16Length`, one level up: counting with
        /// `originalText.reduce { $0 == "\n" }` walks Characters, and CRLF is a
        /// single Character that does not equal "\n" — so on a CRLF file the
        /// count came out 0 and `LineNumberRulerView.foldLineSpans` dropped every
        /// fold from its map, putting the modified-since-save bars on the wrong
        /// rows. Counted over UTF-8 so a line break is a byte, not a grapheme.
        let hiddenLineCount: Int

        init(displayLocation: Int, originalText: String, originalAttributedText: NSAttributedString) {
            self.displayLocation = displayLocation
            self.originalText = originalText
            self.originalAttributedText = originalAttributedText
            self.originalUTF16Length = (originalText as NSString).length
            self.hiddenLineCount = originalText.utf8.reduce(into: 0) { count, byte in
                if byte == 0x0A { count += 1 }
            }
        }
    }

    // MARK: - State

    private(set) var regions: [FoldRegion] = []
    private(set) var isMutating = false
    private var didFoldMutation = false

    // MARK: - Keeping regions aligned with user edits
    //
    // A `FoldRegion` is an offset into the *displayed* text. `fold` and `unfold`
    // shift every other region when they mutate the storage themselves — but for
    // years nothing shifted them when the USER edited. Type one character above a
    // collapsed fold and every region below it pointed one unit short: the
    // reconstruction in `fullText(from:)` then spliced the folded block in at the
    // wrong offset, dropping a character and leaving the U+FFFC attachment char in
    // the string that becomes `document.text` — and therefore the draft, and the
    // file on ⌘S. Clicking the placeholder unfolded the wrong range, or nothing.
    //
    // The fix mirrors `DiffLayoutManager.processEditing`, which solves the same
    // problem for compare-mode highlight ranges. It installs itself: no call site
    // has to remember to drive it, because forgetting is exactly how the bug
    // survived so long. The subscription exists only while there are folds.

    private var editObserver: NSObjectProtocol?
    private weak var observedStorage: NSTextStorage?

    /// Subscribe to `textStorage`'s edits, once per storage.
    ///
    /// `NSTextStorage.didProcessEditingNotification` is posted from inside
    /// `processEditing`, synchronously on the editing thread, while
    /// `editedRange` / `changeInLength` still describe the edit — and, for a
    /// `beginEditing`/`endEditing` group, describe the whole group coalesced
    /// into one range. Delivered with `queue: nil` so it lands before the
    /// `textDidChange` that reads `fullText`.
    private func observeEdits(of textStorage: NSTextStorage) {
        guard observedStorage !== textStorage else { return }
        stopObservingEdits()
        observedStorage = textStorage
        editObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: textStorage,
            queue: nil
        ) { [weak self] note in
            let payload = FoldMainActorNotification(value: note)
            MainActor.assumeIsolated {
                guard let self, let storage = payload.value.object as? NSTextStorage else { return }
                self.storageDidProcessEditing(storage)
            }
        }
    }

    private func stopObservingEdits() {
        if let editObserver {
            NotificationCenter.default.removeObserver(editObserver)
        }
        editObserver = nil
        observedStorage = nil
    }

    /// Drop the subscription once the last fold is gone; `fold` reinstalls it.
    private func stopObservingIfIdle() {
        if regions.isEmpty { stopObservingEdits() }
    }

    private func storageDidProcessEditing(_ textStorage: NSTextStorage) {
        // fold/unfold/unfoldAll shift the regions themselves.
        guard !isMutating, !regions.isEmpty else { return }
        guard textStorage.editedMask.contains(.editedCharacters) else { return }
        adjustRegions(editedRange: textStorage.editedRange,
                      changeInLength: textStorage.changeInLength)
        stopObservingIfIdle()
    }

    /// Re-point every region for one text edit.
    ///
    /// `editedRange` is in NEW coordinates and `changeInLength` is the delta, so
    /// the span the edit replaced was `[start, start + length - delta)` in the
    /// old ones — the same arithmetic `DiffLayoutManager.processEditing` does.
    /// A placeholder that lay inside the replaced span no longer exists, so its
    /// region is dropped rather than moved: keeping it would splice a folded
    /// block back into text the user deleted.
    ///
    /// Runs for zero-delta edits too. Typing over a one-character selection that
    /// happens to be the placeholder changes no length at all, and a fix that
    /// only reacted to length changes would leave a region pointing at a
    /// character that is no longer an attachment.
    func adjustRegions(editedRange: NSRange, changeInLength delta: Int) {
        guard !regions.isEmpty else { return }
        let editStart = editedRange.location
        let oldEditEnd = editStart + (editedRange.length - delta)

        regions = regions.compactMap { region in
            var region = region
            let loc = region.displayLocation
            if loc + 1 <= editStart {
                return region                    // entirely before the edit
            } else if loc >= oldEditEnd {
                region.displayLocation = loc + delta
                return region                    // entirely after the replaced span
            } else {
                return nil                       // the placeholder was replaced
            }
        }
    }

    /// Arm the one-shot "the next `textDidChange` came from folding, not the
    /// user" handshake.
    ///
    /// This is deliberately NOT done by `fold`/`unfold`/`unfoldAll` themselves.
    /// Those mutate the storage directly, which posts no
    /// `NSText.didChangeNotification` on its own — the notification exists only
    /// because the INTERACTIVE call sites (the gutter chevron, and clicking a
    /// fold placeholder) call `didChangeText()` right afterwards. Every other
    /// caller is programmatic — restoring folds when a view is built, expanding
    /// them across a tab switch, collapsing them on the way into compare mode —
    /// and emits no notification at all.
    ///
    /// While the mutators armed the flag themselves, those programmatic paths
    /// left it armed with nothing coming to consume it, so the user's next REAL
    /// edit ate it: `textDidChange` saw `isFoldMutation == true` and skipped
    /// both `isDirty` and the safety saves. One text view serves every tab, so
    /// that meant the first edit after every tab switch went unmarked and
    /// unsaved while the status bar still read "Saved".
    ///
    /// So the mutators stay silent and the two sites that actually emit a
    /// notification arm it explicitly: a path that emits nothing can no longer
    /// leave anything armed.
    func armFoldMutationFlag() {
        didFoldMutation = true
    }

    func consumeFoldMutationFlag() -> Bool {
        defer { didFoldMutation = false }
        return didFoldMutation
    }

    // MARK: - Per-document fold persistence

    private struct SavedFold {
        let rangeInFullText: NSRange  // position in the unfolded source text
        let originalText: String
    }
    private static var savedStates: [String: [SavedFold]] = [:]

    /// Save current folds for `documentID` before switching away.
    func saveFolds(for documentID: String) {
        var accumulated = 0
        let saved = regions.map { region -> SavedFold in
            let fullLoc = region.displayLocation + accumulated
            // UTF-16 units, not Characters — see FoldRegion.originalUTF16Length.
            accumulated += region.originalUTF16Length - 1
            return SavedFold(
                rangeInFullText: NSRange(location: fullLoc, length: region.originalUTF16Length),
                originalText: region.originalText
            )
        }
        Self.savedStates[documentID] = saved
    }

    /// Forget the folds saved for `documentID`.
    ///
    /// `savedStates` is static so folds survive the view being torn down and
    /// rebuilt on a tab switch. Nothing used to remove entries, so every fold's
    /// original text — potentially the bulk of a file — stayed resident for the
    /// life of the process even after its tab was closed.
    static func discardSavedFolds(for documentID: String) {
        savedStates.removeValue(forKey: documentID)
    }

    /// Restore folds saved for `documentID` into the (fully-unfolded) text storage.
    func restoreFolds(for documentID: String, in textStorage: NSTextStorage) {
        guard let saved = Self.savedStates[documentID] else { return }
        // Apply from last to first so earlier positions stay valid.
        for s in saved.sorted(by: { $0.rangeInFullText.location > $1.rangeInFullText.location }) {
            guard NSMaxRange(s.rangeInFullText) <= textStorage.length else { continue }
            let actual = (textStorage.string as NSString).substring(with: s.rangeInFullText)
            guard actual == s.originalText else { continue }
            fold(range: s.rangeInFullText, in: textStorage)
        }
    }

    // MARK: - Detection

    /// All multi-line brace blocks in `text` that can be folded.
    /// Skips NSTextAttachment chars (U+FFFC) so existing folds don't confuse
    /// the brace matcher.
    /// - Note: The gutter calls this (via `foldableLines`) on every redraw, so it
    ///   is on the scroll and typing hot path. Two things used to make it far more
    ///   expensive than the single pass it looks like:
    ///
    ///   1. `text.character(at:)` in the loop is one ObjC message per UTF-16 unit
    ///      — hundreds of thousands per frame on a large source file. The text is
    ///      now pulled in 4 KB chunks through `getCharacters`, the same trick
    ///      `TextLineIndex` uses.
    ///   2. `text.substring(with: r).contains("\n")` COPIED the whole candidate
    ///      range for every matched brace pair, so nested blocks made the scan
    ///      quadratic. Tracking the most recent newline position answers the same
    ///      question in O(1): a range (openPos, i) contains a newline exactly when
    ///      the last newline seen so far lies after `openPos` — `openPos` holds a
    ///      brace, so it can never be the newline itself.
    ///
    ///   Callers that redraw repeatedly should still cache the result; see
    ///   `LineNumberRulerView.foldMarkers(...)`.
    func foldableRanges(in text: NSString) -> [NSRange] {
        let length = text.length
        guard length > 0 else { return [] }

        var result: [NSRange] = []
        var stack: [(open: unichar, pos: Int)] = []
        let pairs: [unichar: unichar] = [125: 123, 93: 91, 41: 40] // close→open
        var lastNewline = -1

        let chunkSize = 4096
        var buffer = [unichar](repeating: 0, count: chunkSize)
        var base = 0
        while base < length {
            let len = min(chunkSize, length - base)
            let chunkStart = base
            buffer.withUnsafeMutableBufferPointer { p in
                text.getCharacters(p.baseAddress!, range: NSRange(location: chunkStart, length: len))
                for k in 0..<len {
                    let c = p[k]
                    let i = chunkStart + k
                    switch c {
                    case 0xFFFC:                    // fold placeholder attachment
                        continue
                    case 0x0A:
                        lastNewline = i
                    case 123, 91, 40:               // { [ (
                        stack.append((c, i))
                    case 125, 93, 41:               // } ] )
                        guard let matchOpen = pairs[c],
                              let idx = stack.lastIndex(where: { $0.open == matchOpen })
                        else { continue }
                        let openPos = stack[idx].pos
                        stack.removeSubrange(idx...)
                        if lastNewline > openPos {
                            result.append(NSRange(location: openPos, length: i - openPos + 1))
                        }
                    default:
                        continue
                    }
                }
            }
            base += len
        }
        return result
    }

    /// 1-based line numbers that start a foldable block in the displayed text.
    func foldableLines(displayText: NSString) -> Set<Int> {
        // One pass for all the ranges. Copying the prefix per range made this
        // O(ranges x length), and the gutter calls it on every redraw.
        let starts = foldableRanges(in: displayText).map(\.location)
        return Set(TextLineIndex.lineNumbers(in: displayText, at: starts))
    }

    /// 1-based line numbers that currently show a fold placeholder.
    func foldedLines(displayText: NSString) -> Set<Int> {
        let starts = regions
            .filter { $0.displayLocation >= 0 && $0.displayLocation < displayText.length }
            .map(\.displayLocation)
        return Set(TextLineIndex.lineNumbers(in: displayText, at: starts))
    }

    /// The foldable range that starts on `line` (1-based) in the displayed text.
    func foldableRange(onLine line: Int, displayText: NSString) -> NSRange? {
        let ranges = foldableRanges(in: displayText)
        let lines = TextLineIndex.lineNumbers(in: displayText, at: ranges.map(\.location))
        guard let idx = lines.firstIndex(of: line) else { return nil }
        return ranges[idx]
    }

    // MARK: - Fold

    func fold(range: NSRange, in textStorage: NSTextStorage) {
        guard NSMaxRange(range) <= textStorage.length, range.length > 1 else { return }
        let original = (textStorage.string as NSString).substring(with: range)
        // Not `original.contains("\n")`. That compares Characters, so CRLF — one
        // Character that does not equal "\n" — reads as having no line break.
        // It happens to return true today only because this string is bridged
        // from NSTextStorage and Foundation searches it as UTF-16; the same
        // literal in a native Swift String answers false. Scalars are the level
        // that is actually being asked about.
        let lineCount = original.utf8.reduce(into: 0) { count, byte in
            if byte == 0x0A { count += 1 }
        }
        guard lineCount > 0 else { return }
        let originalAttributed = textStorage.attributedSubstring(from: range)
        let preview   = "{ \(lineCount) line\(lineCount == 1 ? "" : "s") }"
        let attachment = FoldPlaceholder(preview: preview, originalText: original)

        let attrStr = NSMutableAttributedString(attachment: attachment)
        attrStr.addAttributes([
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.bestTextEditorForeground
        ], range: NSRange(location: 0, length: 1))

        // Install (once per storage) before the mutation, so a manager that
        // gains its first fold is already tracking edits.
        observeEdits(of: textStorage)

        isMutating = true
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: range, with: attrStr)
        textStorage.endEditing()
        isMutating = false

        let delta = 1 - range.length
        for i in regions.indices where regions[i].displayLocation >= NSMaxRange(range) {
            regions[i].displayLocation += delta
        }
        regions.append(FoldRegion(
            displayLocation: range.location,
            originalText: original,
            originalAttributedText: originalAttributed
        ))
        regions.sort { $0.displayLocation < $1.displayLocation }
    }

    // MARK: - Unfold

    func unfold(at location: Int, in textStorage: NSTextStorage) {
        guard let idx = regions.firstIndex(where: {
            $0.displayLocation == location
        }) else { return }
        let region = regions[idx]
        // Belt and braces: the region must still be pointing at its own
        // attachment character. If an edit moved or ate it and the adjustment
        // above somehow missed, restoring here would splice the folded block
        // into arbitrary text — so treat a mismatch as "this region is gone".
        guard region.displayLocation >= 0,
              NSMaxRange(region.displayRange) <= textStorage.length,
              (textStorage.string as NSString).character(at: region.displayLocation) == Self.placeholderUnit
        else {
            regions.remove(at: idx)
            stopObservingIfIdle()
            return
        }

        let restored = region.originalAttributedText

        isMutating = true
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: region.displayRange, with: restored)
        textStorage.endEditing()
        isMutating = false

        // UTF-16 units, not Characters — see FoldRegion.originalUTF16Length.
        let delta = region.originalUTF16Length - 1
        regions.remove(at: idx)
        for i in regions.indices where regions[i].displayLocation > region.displayLocation {
            regions[i].displayLocation += delta
        }
        stopObservingIfIdle()
    }

    /// Forget every fold region WITHOUT touching the text storage.
    ///
    /// For callers that are about to replace the storage's entire contents with
    /// the document's full text: unfolding first would be wasted work, and
    /// leaving the regions behind is actively harmful — `fullText(from:)` would
    /// splice each region's original text back into a document that already
    /// contains it, duplicating every folded block in the file.
    func discardRegions() {
        regions.removeAll()
        stopObservingEdits()
    }

    func unfoldAll(in textStorage: NSTextStorage) {
        isMutating = true
        for region in regions.sorted(by: { $0.displayLocation > $1.displayLocation }) {
            let restored = NSAttributedString(string: region.originalText, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.bestTextEditorForeground
            ])
            textStorage.beginEditing()
            textStorage.replaceCharacters(in: region.displayRange, with: restored)
            textStorage.endEditing()
        }
        regions.removeAll()
        isMutating = false
        stopObservingEdits()
    }

    isolated deinit {
        stopObservingEdits()
    }

    // MARK: - Full text reconstruction

    /// Reconstructs the full unfolded text — use this for document.text so
    /// the saved file never contains attachment characters.
    func fullText(from textStorage: NSTextStorage) -> String {
        if regions.isEmpty { return textStorage.string }
        let ns = textStorage.string as NSString
        var result = ""
        var pos    = 0
        for region in regions {
            let loc = region.displayLocation
            // Only splice where the region's own attachment character actually
            // is. This text becomes `document.text`, the recovery draft and the
            // bytes written on ⌘S: a region that has drifted must cost the user
            // a stale fold, never a corrupted file. `regions` is kept sorted, so
            // `loc >= pos` also rejects any pair that has crossed over.
            guard loc >= pos, loc < ns.length,
                  ns.character(at: loc) == Self.placeholderUnit
            else { continue }
            if loc > pos {
                result += ns.substring(with: NSRange(location: pos, length: loc - pos))
            }
            result += region.originalText
            pos = loc + 1
        }
        if pos < ns.length { result += ns.substring(from: pos) }
        return result
    }
}
