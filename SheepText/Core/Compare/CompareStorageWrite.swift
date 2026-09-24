import AppKit

/// The one place a finished compare display is written into an `NSTextStorage`.
///
/// `applyCompareDisplay` used to do this inline. It lives here so a test can
/// drive the REAL write — the bug this file exists for is not in building a
/// display, it is in applying a second one over the first, and the September
/// 2026 tests all passed because they only ever checked a freshly built one.
/// The storage is AppKit's, so the write itself is main-actor work; only the
/// pure arithmetic (`fillerRuns`, `differences`) is `nonisolated`, because the
/// runs are computed with the rest of the snapshot on the background queue.
enum CompareStorageWrite {

    /// Writes `display` into `storage` and makes the `.isFillerLine` attribute
    /// describe `fillerRuns` exactly.
    ///
    /// The text write is incremental — common prefix and suffix are left alone
    /// and only the changed middle is replaced — which is what keeps temporary
    /// attributes on the unchanged head and limits layout invalidation to the
    /// affected region, so typing does not flash. `willReplaceText` runs just
    /// before that replace, for the bookkeeping that has to straddle it.
    ///
    /// Returns the common prefix length (the caller clears temporary attributes
    /// from there on) and whether the text itself moved.
    @discardableResult
    static func perform(
        display: NSAttributedString,
        fillerRuns: [NSRange],
        into storage: NSTextStorage,
        willReplaceText: () -> Void
    ) -> (prefixLength: Int, replacedText: Bool) {
        let oldStr = storage.string as NSString
        let newStr = display.string as NSString
        let oldLen = oldStr.length
        let newLen = newStr.length

        // Chunked rather than one character(at:) per UTF-16 unit: that is an
        // ObjC message per character, on the main thread, over the whole display
        // text on every rebuild.
        let prefixLen = NSString.commonPrefixLength(oldStr, newStr)
        let suffixLen = NSString.commonSuffixLength(oldStr, newStr, notBefore: prefixLen)
        let needsTextReplace = (prefixLen + suffixLen < oldLen) || (prefixLen + suffixLen < newLen)

        if needsTextReplace {
            willReplaceText()
            let oldRange = NSRange(location: prefixLen, length: oldLen - prefixLen - suffixLen)
            let newRange = NSRange(location: prefixLen, length: newLen - prefixLen - suffixLen)
            storage.beginEditing()
            storage.replaceCharacters(in: oldRange, with: display.attributedSubstring(from: newRange))
            storage.endEditing()
        }

        reconcileFillerAttribute(in: storage, desired: fillerRuns)
        return (prefixLen, needsTextReplace)
    }

    /// Make `.isFillerLine` on `storage` describe `desired` and nothing else.
    ///
    /// This has to cover the WHOLE storage, not just the replaced middle, and
    /// that is the bug. Characters in the common prefix and suffix keep the
    /// attributes they already carried, which is right for the base font and
    /// colour — they never change — but filler-ness is POSITIONAL, and a filler
    /// row is an empty line. A filler can therefore swap places with a real
    /// blank line without changing a single character of the display text:
    ///
    ///     L = "a\nb", R = "a\nX\nb"  ->  left pane "a\n" + "\n"(filler) + "b\n"
    ///     L = "a\nb", R = "a\nb\nX"  ->  left pane "a\n" + "b\n" + "\n"(filler)
    ///
    /// Same five characters, filler moved one row down, so the incremental write
    /// replaces `[2,4)` and the trailing "\n" keeps the REAL attributes it had as
    /// the tail of row "b". `EditorTextView.realText(from:)` reads exactly those
    /// flags to decide what goes back into `document.text`, so the left document
    /// silently grew a blank line the user never typed — and
    /// `shouldChangeText` then refused edits on the row that kept a stale flag.
    /// Measured by the auditor over 3.7 M peer-driven rebuilds: 13.4 % of them
    /// produced a `realText` that differs from a clean build.
    ///
    /// The runs are diffed rather than rewritten. Blindly clearing and re-adding
    /// costs 14.5 ms at 200 000 rows / 28 572 fillers on the main thread, and the
    /// overwhelming majority of rebuilds move a handful of rows at most.
    private static func reconcileFillerAttribute(in storage: NSTextStorage, desired: [NSRange]) {
        let length = storage.length
        guard length > 0 else { return }
        var actual: [NSRange] = []
        storage.enumerateAttribute(.isFillerLine, in: NSRange(location: 0, length: length)) { value, range, _ in
            if value != nil { actual.append(range) }
        }
        let work = differences(desired: desired, actual: actual)
        guard !work.add.isEmpty || !work.remove.isEmpty else { return }
        storage.beginEditing()
        for range in work.remove where NSMaxRange(range) <= length {
            storage.removeAttribute(.isFillerLine, range: range)
        }
        for range in work.add where NSMaxRange(range) <= length {
            storage.addAttribute(.isFillerLine, value: true, range: range)
        }
        storage.endEditing()
    }

    /// The minimal edit that turns `actual` into `desired`. Both lists must be
    /// sorted and non-overlapping, which is what the builder's row ranges and
    /// `enumerateAttribute`'s runs both are.
    ///
    /// Internal rather than private so the sweep can be tested on its own — it
    /// is the part with the off-by-one in it.
    nonisolated static func differences(
        desired: [NSRange], actual: [NSRange]
    ) -> (add: [NSRange], remove: [NSRange]) {
        // Sweep the union of both lists' boundaries. Between two consecutive
        // boundaries membership of each list is constant, so every segment is
        // agreed, missing (add) or spurious (remove).
        var boundaries: [Int] = []
        boundaries.reserveCapacity((desired.count + actual.count) * 2)
        for range in desired { boundaries.append(range.location); boundaries.append(NSMaxRange(range)) }
        for range in actual  { boundaries.append(range.location); boundaries.append(NSMaxRange(range)) }
        boundaries.sort()

        var add: [NSRange] = []
        var remove: [NSRange] = []
        var desiredCursor = 0
        var actualCursor = 0
        var index = 0
        while index < boundaries.count {
            let start = boundaries[index]
            // Skip duplicates; the next distinct boundary closes this segment.
            var next = index + 1
            while next < boundaries.count && boundaries[next] == start { next += 1 }
            guard next < boundaries.count else { break }
            let end = boundaries[next]
            index = next

            while desiredCursor < desired.count && NSMaxRange(desired[desiredCursor]) <= start {
                desiredCursor += 1
            }
            while actualCursor < actual.count && NSMaxRange(actual[actualCursor]) <= start {
                actualCursor += 1
            }
            let inDesired = desiredCursor < desired.count && desired[desiredCursor].location <= start
            let inActual  = actualCursor  < actual.count  && actual[actualCursor].location  <= start
            if inDesired && !inActual { appendMerging(&add, start: start, end: end) }
            if inActual && !inDesired { appendMerging(&remove, start: start, end: end) }
        }
        return (add, remove)
    }

    nonisolated private static func appendMerging(_ list: inout [NSRange], start: Int, end: Int) {
        guard end > start else { return }
        if let last = list.last, NSMaxRange(last) == start {
            list[list.count - 1] = NSRange(location: last.location, length: end - last.location)
        } else {
            list.append(NSRange(location: start, length: end - start))
        }
    }

    /// The filler rows of a built display, merged into runs — adjacent fillers
    /// are one range, which is what `enumerateAttribute` hands back for them.
    nonisolated static func fillerRuns(rowRanges: [NSRange], isFiller: [Bool]) -> [NSRange] {
        var runs: [NSRange] = []
        for (index, range) in rowRanges.enumerated() where index < isFiller.count && isFiller[index] {
            appendMerging(&runs, start: range.location, end: NSMaxRange(range))
        }
        return runs
    }
}
