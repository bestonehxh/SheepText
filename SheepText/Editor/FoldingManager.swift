//
//  FoldingManager.swift
//  Manages code-folding state for one editor instance.
//
//  Design:
//  - A fold replaces a multi-line brace block in NSTextStorage with a 1-char
//    NSTextAttachment placeholder (FoldPlaceholder).
//  - The placeholder character carries `.foldRegionID`, a number unique to this
//    manager. THAT attribute — not an offset — is what identifies a fold.
//  - Each FoldRegion remembers the original text so it can be restored.
//  - `isMutating` lets the coordinator skip document-text sync during fold ops.
//  - `fullText(from:)` reconstructs the real (unfolded) text for saving.
//
//  WHY THE IDENTITY ATTRIBUTE. Until September 2026 a region's position was
//  maintained purely by offset arithmetic against `editedRange`/`changeInLength`,
//  and a region whose placeholder appeared to fall inside the replaced span was
//  destroyed. That is right for a single edit and wrong for every grouped one:
//  `NSTextStorage` coalesces a `beginEditing`/`endEditing` group into ONE
//  notification whose range spans from the first sub-edit to the last, so
//  Replace All, multi-cursor typing, ⇧⌘D and ⇧⌘K each looked like one enormous
//  replacement that swallowed every fold between their first and last cursor.
//  The regions were dropped, the U+FFFC attachment characters stayed in the
//  storage, and `fullText(from:)` copied them straight into `document.text` —
//  the draft, the auto save and the bytes written on ⌘S. The folded blocks were
//  simply gone.
//
//  So the arithmetic is now only a HINT. After every edit each region's guess is
//  verified against the attribute actually sitting in the storage, and a single
//  mismatch re-derives every position by enumerating `.foldRegionID` over the
//  storage. A region whose placeholder really has gone is RETIRED rather than
//  destroyed, because an undo can bring the character — attribute included —
//  straight back.
//

import AppKit

extension NSAttributedString.Key {
    /// Identity of the fold a placeholder character stands for, as an `Int`
    /// unique within one `FoldingManager`.
    ///
    /// It rides on the character, so it survives everything that moves the
    /// character: grouped edits, undo, redo, a paste of a copied attributed
    /// run. `NSTextView.font =` and the base-attribute passes in
    /// `EditorTextView` use `addAttribute`/`setFont:range:`, which merge rather
    /// than replace, so they leave it (and the `.attachment` next to it) alone —
    /// the same exposure the placeholder attachment has always had.
    nonisolated static let foldRegionID = NSAttributedString.Key("sheeptext.foldRegionID")
}

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
    private static let placeholderSet = CharacterSet(charactersIn: "\u{FFFC}")

    // MARK: - Types

    struct FoldRegion {
        /// Identity, mirrored onto the placeholder character as `.foldRegionID`.
        let id: Int
        var displayLocation: Int     // index of the attachment char in textStorage
        let originalText: String     // the text the attachment stands for

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

        init(id: Int, displayLocation: Int, originalText: String) {
            self.id = id
            self.displayLocation = displayLocation
            self.originalText = originalText
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

    private var nextRegionID = 1

    /// Folds whose placeholder is no longer in the storage, kept by id so an
    /// undo that brings the character back can bring the fold back with it.
    ///
    /// Deleting a fold chip and pressing ⌘Z used to leave a U+FFFC in
    /// `document.text` that no region claimed, and the block's text — which only
    /// ever lived in the dropped region — was gone for good. The undo re-inserts
    /// the character with its attributes (verified against a real
    /// `NSTextView`/`UndoManager`), so the identity is right there to be matched.
    ///
    /// Bounded: a region holds the whole folded block, and nothing else would
    /// ever evict one. Oldest first — an undo that is going to resurrect a fold
    /// follows the delete closely.
    private var retired: [Int: FoldRegion] = [:]
    private var retiredOrder: [Int] = []
    private static let retiredLimit = 32

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

    /// Drop the subscription once nothing is left to track; `fold` reinstalls it.
    ///
    /// A retired region counts: it is the thing an undo resurrects, and an
    /// unsubscribed manager would never see that undo arrive.
    private func stopObservingIfIdle() {
        if regions.isEmpty && retired.isEmpty { stopObservingEdits() }
    }

    private func storageDidProcessEditing(_ textStorage: NSTextStorage) {
        // fold/unfold/unfoldAll shift the regions themselves.
        guard !isMutating, !regions.isEmpty || !retired.isEmpty else { return }
        guard textStorage.editedMask.contains(.editedCharacters) else { return }
        reseatRegions(in: textStorage,
                      editedRange: textStorage.editedRange,
                      changeInLength: textStorage.changeInLength)
        stopObservingIfIdle()
    }

    /// Where offset arithmetic alone thinks `location` ended up, or nil when the
    /// edit replaced the span it sat in.
    ///
    /// `editedRange` is in NEW coordinates and `changeInLength` is the delta, so
    /// the span the edit replaced was `[start, start + length - delta)` in the
    /// old ones — the same arithmetic `DiffLayoutManager.processEditing` does.
    /// For a SINGLE edit this is exact. For a coalesced group it is a guess that
    /// is wrong in exactly one direction: it reports "replaced" for placeholders
    /// that merely lie between two sub-edits. That is why every answer is
    /// checked against the storage below.
    private static func shiftedLocation(_ location: Int,
                                        editedRange: NSRange,
                                        changeInLength delta: Int) -> Int? {
        let editStart = editedRange.location
        let oldEditEnd = editStart + (editedRange.length - delta)
        if location + 1 <= editStart { return location }
        if location >= oldEditEnd { return location + delta }
        return nil
    }

    /// Re-point every region after one text edit, and resurrect any fold the
    /// edit brought back.
    ///
    /// Fast path: take the arithmetic's guess and verify it against the
    /// `.foldRegionID` actually in the storage — N attribute reads, no scan. One
    /// disagreement (a grouped edit, a whole-storage replacement, a genuinely
    /// deleted chip) drops into a single enumeration of the attribute over the
    /// whole storage, which is authoritative by construction.
    ///
    /// Runs for zero-delta edits too. Typing over a one-character selection that
    /// happens to be the placeholder changes no length at all, and a fix that
    /// only reacted to length changes would leave a region pointing at a
    /// character that is no longer an attachment.
    func reseatRegions(in textStorage: NSTextStorage, editedRange: NSRange, changeInLength delta: Int) {
        guard !regions.isEmpty || !retired.isEmpty else { return }

        var candidates: [Int] = []
        candidates.reserveCapacity(regions.count)
        var agreed = true
        for region in regions {
            guard let candidate = Self.shiftedLocation(region.displayLocation,
                                                       editedRange: editedRange,
                                                       changeInLength: delta),
                  Self.placeholderMatches(region, at: candidate, in: textStorage)
            else { agreed = false; break }
            candidates.append(candidate)
        }

        guard agreed else {
            rederiveRegions(in: textStorage)
            return
        }

        for (index, candidate) in candidates.enumerated() {
            regions[index].displayLocation = candidate
        }
        // Regions stay sorted: every survivor moved by the same delta or not at all.
        if !retired.isEmpty {
            resurrectRegions(in: textStorage, searching: editedRange)
        }
    }

    /// Whether the character at `location` is a placeholder this region may
    /// still claim.
    ///
    /// An identity that matches is proof. A placeholder carrying NO identity is
    /// accepted too, because a whole-storage `setAttributes` replaces the
    /// dictionary rather than merging into it — and if one ever runs without
    /// putting the fold attributes back (the one that exists today,
    /// `Coordinator.resetHighlightAttributes`, does), falling back to the plain
    /// offset arithmetic is exactly the behaviour this code had before, which is
    /// right for a single edit. What is never accepted is a placeholder wearing
    /// somebody else's identity.
    private static func placeholderMatches(_ region: FoldRegion,
                                           at location: Int,
                                           in textStorage: NSTextStorage) -> Bool {
        guard location >= 0, location < textStorage.length,
              (textStorage.string as NSString).character(at: location) == placeholderUnit
        else { return false }
        guard let id = textStorage.attribute(.foldRegionID, at: location, effectiveRange: nil) as? Int
        else { return true }
        return id == region.id
    }

    /// Rebuild every position from the storage itself.
    ///
    /// The attribute is the truth: a region is where its id is, a region whose
    /// id is nowhere is retired, and a retired id that has reappeared is live
    /// again. Nothing here depends on what the edit claimed to do, which is the
    /// whole point — a coalesced group claims far more than it did.
    private func rederiveRegions(in textStorage: NSTextStorage) {
        var found: [Int: Int] = [:]   // id → location
        let fullRange = NSRange(location: 0, length: textStorage.length)
        let ns = textStorage.string as NSString
        if textStorage.length > 0 {
            textStorage.enumerateAttribute(.foldRegionID, in: fullRange, options: []) { value, range, _ in
                guard let id = value as? Int else { return }
                // The attribute can outlive its character only through a bug, but
                // a run longer than one unit means someone typed inside it — take
                // the placeholder, not the run.
                for offset in 0..<range.length {
                    let location = range.location + offset
                    guard ns.character(at: location) == Self.placeholderUnit else { continue }
                    if found[id] == nil { found[id] = location }
                    break
                }
            }
        }

        var live: [FoldRegion] = []
        live.reserveCapacity(regions.count)
        var unmatched: [FoldRegion] = []
        for region in regions {
            if let location = found[region.id] {
                var moved = region
                moved.displayLocation = location
                live.append(moved)
                found.removeValue(forKey: region.id)
            } else {
                unmatched.append(region)
            }
        }

        // Fallback for a placeholder whose identity was stripped rather than
        // deleted. `setAttributes` over a range REPLACES the dictionary, so any
        // future whole-storage attribute pass that forgets to put the fold
        // attributes back (the one that exists today,
        // `Coordinator.resetHighlightAttributes`, does put them back) would
        // leave the character in place with nothing on it. Pair what is left in
        // order, and only when the counts agree — a mismatch means something
        // really was deleted, and guessing there would splice a block into the
        // wrong place.
        if !unmatched.isEmpty {
            let anonymous = Self.unclaimedFoldPlaceholders(in: textStorage,
                                                           excluding: Set(found.values)
                                                               .union(live.map(\.displayLocation)))
            if anonymous.count == unmatched.count {
                for (region, location) in zip(unmatched, anonymous) {
                    var moved = region
                    moved.displayLocation = location
                    live.append(moved)
                }
                unmatched.removeAll()
            }
        }
        for region in unmatched { retire(region) }
        // Whatever ids are left are folds the storage has and this manager had
        // written off — an undo, or a redo of an undone delete.
        for (id, location) in found {
            guard var region = retired[id] else { continue }
            region.displayLocation = location
            live.append(region)
            dropRetired(id)
        }
        regions = live.sorted { $0.displayLocation < $1.displayLocation }
    }

    /// Placeholder characters that carry no fold identity and are not already
    /// spoken for, in document order. A U+FFFC with no `.foldRegionID` and no
    /// `FoldPlaceholder` attachment is the user's own content, not a fold.
    private static func unclaimedFoldPlaceholders(in textStorage: NSTextStorage,
                                                  excluding claimed: Set<Int>) -> [Int] {
        let ns = textStorage.string as NSString
        var result: [Int] = []
        var search = NSRange(location: 0, length: ns.length)
        while search.length > 0 {
            let hit = ns.rangeOfCharacter(from: placeholderSet, options: [], range: search)
            guard hit.location != NSNotFound else { break }
            if !claimed.contains(hit.location),
               textStorage.attribute(.foldRegionID, at: hit.location, effectiveRange: nil) == nil,
               textStorage.attribute(.attachment, at: hit.location, effectiveRange: nil) is FoldPlaceholder {
                result.append(hit.location)
            }
            let next = NSMaxRange(hit)
            search = NSRange(location: next, length: ns.length - next)
        }
        return result
    }

    /// Look for retired folds inside the text an edit just inserted.
    ///
    /// Bounded by the edit, so the common "one retired fold, user keeps typing"
    /// case costs one attribute enumeration over the typed characters rather
    /// than a pass over the document.
    private func resurrectRegions(in textStorage: NSTextStorage, searching editedRange: NSRange) {
        let bounded = NSIntersectionRange(editedRange,
                                          NSRange(location: 0, length: textStorage.length))
        guard bounded.length > 0 else { return }
        let ns = textStorage.string as NSString
        var revived: [FoldRegion] = []
        textStorage.enumerateAttribute(.foldRegionID, in: bounded, options: []) { value, range, _ in
            guard let id = value as? Int, var region = self.retired[id] else { return }
            for offset in 0..<range.length where ns.character(at: range.location + offset) == Self.placeholderUnit {
                region.displayLocation = range.location + offset
                revived.append(region)
                break
            }
        }
        guard !revived.isEmpty else { return }
        for region in revived { dropRetired(region.id) }
        regions.append(contentsOf: revived)
        regions.sort { $0.displayLocation < $1.displayLocation }
    }

    private func retire(_ region: FoldRegion) {
        if retired[region.id] == nil {
            retiredOrder.append(region.id)
        }
        retired[region.id] = region
        while retiredOrder.count > Self.retiredLimit {
            retired.removeValue(forKey: retiredOrder.removeFirst())
        }
    }

    private func dropRetired(_ id: Int) {
        retired.removeValue(forKey: id)
        if let index = retiredOrder.firstIndex(of: id) { retiredOrder.remove(at: index) }
    }

    private func clearRetired() {
        retired.removeAll()
        retiredOrder.removeAll()
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
        // Folding OVER a collapsed fold dissolves it: the outer block's text is
        // taken with the inner one expanded, and the inner region goes away. It
        // used to capture the display substring, U+FFFC and all — so the outer
        // region's `originalText` carried an attachment character that
        // `fullText` spliced straight into `document.text` and onto disk, and
        // the inner block was lost. Nesting is reachable from the gutter:
        // `foldableRanges` skips placeholders when matching braces, so an outer
        // block stays foldable while an inner one is collapsed.
        let inner = regions.enumerated().filter {
            $0.element.displayLocation >= range.location
                && $0.element.displayLocation < NSMaxRange(range)
        }
        let original = inner.isEmpty
            ? (textStorage.string as NSString).substring(with: range)
            : expandedText(of: range, in: textStorage)
        for index in inner.map(\.offset).sorted(by: >) {
            regions.remove(at: index)
        }
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
        let preview   = "{ \(lineCount) line\(lineCount == 1 ? "" : "s") }"
        let attachment = FoldPlaceholder(preview: preview, originalText: original)
        let id = nextRegionID
        nextRegionID += 1

        let attrStr = NSMutableAttributedString(attachment: attachment)
        var placeholderAttributes = Self.rowAttributes(in: textStorage, at: range.location)
        placeholderAttributes[.foldRegionID] = id
        attrStr.addAttributes(placeholderAttributes, range: NSRange(location: 0, length: 1))

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
        regions.append(FoldRegion(id: id, displayLocation: range.location, originalText: original))
        regions.sort { $0.displayLocation < $1.displayLocation }
    }

    /// `range` of the display text with every collapsed fold inside it expanded.
    private func expandedText(of range: NSRange, in textStorage: NSTextStorage) -> String {
        let ns = textStorage.string as NSString
        var result = ""
        var pos = range.location
        let end = NSMaxRange(range)
        for region in regions where region.displayLocation >= pos && region.displayLocation < end {
            let loc = region.displayLocation
            guard ns.character(at: loc) == Self.placeholderUnit else { continue }
            if loc > pos { result += ns.substring(with: NSRange(location: pos, length: loc - pos)) }
            result += region.originalText
            pos = loc + 1
        }
        if pos < end { result += ns.substring(with: NSRange(location: pos, length: end - pos)) }
        return result
    }

    /// Font / colour / paragraph style as the storage has them at `location`.
    ///
    /// The chip used to hard-code `monospacedSystemFont(ofSize: 13)`, so its row
    /// kept 13 pt metrics at any editor size. Reading the row it replaces gives
    /// the right size for free and needs no reference to the text view — which
    /// `restoreFolds` does not have.
    private static func rowAttributes(in textStorage: NSTextStorage,
                                      at location: Int) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [:]
        if location >= 0, location < textStorage.length {
            let existing = textStorage.attributes(at: location, effectiveRange: nil)
            for key in [NSAttributedString.Key.font, .foregroundColor, .paragraphStyle] {
                if let value = existing[key] { attributes[key] = value }
            }
        }
        if attributes[.font] == nil {
            attributes[.font] = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        }
        if attributes[.foregroundColor] == nil {
            attributes[.foregroundColor] = NSColor.bestTextEditorForeground
        }
        return attributes
    }

    // MARK: - Unfold

    /// Expand the fold whose placeholder sits at `location`, and return the range
    /// the restored text now occupies.
    ///
    /// `baseAttributes` is what the restored characters get. The block used to be
    /// spliced back as the attributed string captured at fold time, and font,
    /// kern and paragraph style are STORAGE attributes that
    /// `applyDocumentVisualSettings` rewrites over the storage — which does not
    /// contain folded text. Fold at 13 pt, zoom to 24 pt, expand, and the block
    /// came back at 13 pt with 13 pt line heights. Passing nil reads the
    /// attributes off the placeholder's own row, which is the best a caller
    /// without a text view can do.
    @discardableResult
    func unfold(at location: Int,
                in textStorage: NSTextStorage,
                baseAttributes: [NSAttributedString.Key: Any]? = nil) -> NSRange? {
        guard let idx = regions.firstIndex(where: {
            $0.displayLocation == location
        }) else { return nil }
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
            retire(region)
            stopObservingIfIdle()
            return nil
        }

        let attributes = baseAttributes ?? Self.rowAttributes(in: textStorage, at: region.displayLocation)
        let restored = NSAttributedString(string: region.originalText, attributes: attributes)

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
        // Deliberately NOT retired: the block is back in the storage as real
        // text, so there is nothing left for an undo to resurrect.
        dropRetired(region.id)
        stopObservingIfIdle()
        return NSRange(location: region.displayLocation, length: region.originalUTF16Length)
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
        clearRetired()
        stopObservingEdits()
    }

    /// Expand every fold. `baseAttributes` as in `unfold(at:in:baseAttributes:)`;
    /// nil takes each placeholder's own row, which is the editor font at the
    /// current size rather than the hard-coded 13 pt this used to write.
    func unfoldAll(in textStorage: NSTextStorage,
                   baseAttributes: [NSAttributedString.Key: Any]? = nil) {
        isMutating = true
        for region in regions.sorted(by: { $0.displayLocation > $1.displayLocation }) {
            guard NSMaxRange(region.displayRange) <= textStorage.length else { continue }
            let attributes = baseAttributes
                ?? Self.rowAttributes(in: textStorage, at: region.displayLocation)
            let restored = NSAttributedString(string: region.originalText, attributes: attributes)
            textStorage.beginEditing()
            textStorage.replaceCharacters(in: region.displayRange, with: restored)
            textStorage.endEditing()
        }
        regions.removeAll()
        clearRetired()
        isMutating = false
        stopObservingEdits()
    }

    isolated deinit {
        stopObservingEdits()
    }

    // MARK: - Full text reconstruction

    /// Reconstructs the full unfolded text — use this for document.text so
    /// the saved file never contains attachment characters.
    ///
    /// The last line of defence for the whole subsystem. Whatever goes wrong
    /// upstream, what comes out of here is what lands in `document.text`, the
    /// recovery draft and the file on ⌘S, so it never returns a fold placeholder
    /// it could have resolved: a U+FFFC left in the result sends it back through
    /// the slow, storage-driven walk, which resolves by identity, then by
    /// retired region, then by the attachment object's own `originalText`.
    func fullText(from textStorage: NSTextStorage) -> String {
        if regions.isEmpty {
            let text = textStorage.string
            guard !retired.isEmpty,
                  (text as NSString).rangeOfCharacter(from: Self.placeholderSet).location != NSNotFound
            else { return text }
            return resolvingEveryPlaceholder(in: textStorage)
        }
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

        guard (result as NSString).rangeOfCharacter(from: Self.placeholderSet).location != NSNotFound
        else { return result }
        return resolvingEveryPlaceholder(in: textStorage)
    }

    /// Rebuild the text placeholder by placeholder, resolving each one from
    /// whatever still knows what it stood for.
    ///
    /// Reaching this is a bug somewhere above, so it logs — but it logs instead
    /// of losing the user's text. A U+FFFC that carries no fold identity and no
    /// fold attachment is left alone: it is an object-replacement character the
    /// user's own content brought with it, not a fold.
    private func resolvingEveryPlaceholder(in textStorage: NSTextStorage) -> String {
        let ns = textStorage.string as NSString
        let byLocation = Dictionary(regions.map { ($0.displayLocation, $0) },
                                    uniquingKeysWith: { first, _ in first })
        var result = ""
        var pos = 0
        var unresolved = 0
        var recovered = 0

        var search = NSRange(location: 0, length: ns.length)
        while search.length > 0 {
            let hit = ns.rangeOfCharacter(from: Self.placeholderSet, options: [], range: search)
            guard hit.location != NSNotFound else { break }
            if hit.location > pos {
                result += ns.substring(with: NSRange(location: pos, length: hit.location - pos))
            }
            if let region = byLocation[hit.location] {
                result += region.originalText
            } else if let id = textStorage.attribute(.foldRegionID, at: hit.location, effectiveRange: nil) as? Int,
                      let region = retired[id] {
                result += region.originalText
                recovered += 1
            } else if let placeholder = textStorage.attribute(.attachment, at: hit.location, effectiveRange: nil)
                        as? FoldPlaceholder, !placeholder.originalText.isEmpty {
                result += placeholder.originalText
                recovered += 1
            } else if textStorage.attribute(.attachment, at: hit.location, effectiveRange: nil) is FoldPlaceholder {
                // Ours, but it cannot say what it stood for (a decoded
                // attachment loses `originalText`). Emitting the character would
                // write U+FFFC into the file; dropping it is the lesser loss.
                unresolved += 1
            } else {
                result += ns.substring(with: hit)   // not a fold — the user's own character
            }
            pos = NSMaxRange(hit)
            search = NSRange(location: pos, length: ns.length - pos)
        }
        if pos < ns.length { result += ns.substring(from: pos) }

        if recovered > 0 || unresolved > 0 {
            NSLog("SheepText: fold placeholder had no live region (recovered %d, unresolved %d)",
                  recovered, unresolved)
        }
        return result
    }
}
