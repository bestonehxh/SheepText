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

final class FoldingManager {

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

        isMutating = true
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: range, with: attrStr)
        textStorage.endEditing()
        isMutating = false
        didFoldMutation = true

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
        guard region.displayLocation >= 0,
              NSMaxRange(region.displayRange) <= textStorage.length
        else {
            regions.remove(at: idx)
            return
        }

        let restored = region.originalAttributedText

        isMutating = true
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: region.displayRange, with: restored)
        textStorage.endEditing()
        isMutating = false
        didFoldMutation = true

        // UTF-16 units, not Characters — see FoldRegion.originalUTF16Length.
        let delta = region.originalUTF16Length - 1
        regions.remove(at: idx)
        for i in regions.indices where regions[i].displayLocation > region.displayLocation {
            regions[i].displayLocation += delta
        }
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
        didFoldMutation = true
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
            if region.displayLocation > pos {
                result += ns.substring(with: NSRange(location: pos,
                                                     length: region.displayLocation - pos))
            }
            result += region.originalText
            pos = region.displayLocation + 1
        }
        if pos < ns.length { result += ns.substring(from: pos) }
        return result
    }
}
