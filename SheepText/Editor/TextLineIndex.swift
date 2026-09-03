//
//  TextLineIndex.swift
//  Line/column lookup for a UTF-16 offset, without copying the text.
//

import Foundation

/// Converts a UTF-16 offset into a 1-based line (and column) number.
///
/// The obvious way to do this — `str.substring(to: loc)` then
/// `.components(separatedBy: "\n").count` — copies the whole document prefix and
/// allocates one String per line. That ran on **every keystroke** (twice, in
/// compare mode) on the main thread: for a cursor near the end of a 2500-line
/// config that is roughly 100 KB copied and 2500 allocations per character typed.
///
/// Only the newline *count* is needed for the line number, and the column only
/// needs the text back to the previous newline — one line, which is short. So
/// this scans the UTF-16 units in place through `getCharacters(_:range:)` and
/// allocates nothing but the small reusable chunk buffer.
///
/// The column is the **Character** (grapheme cluster) count of the current
/// line's prefix plus one — not a UTF-16 count, so Thai combining marks and
/// emoji still count as one column each.
///
/// ## Which characters end a line
///
/// This used to count only `0x0A`, while the gutter numbers its rows by walking
/// `NSString.lineRange`. The two disagree on any file containing a bare CR, a
/// U+2028 / U+2029 separator or a U+0085 NEL: a classic-Mac CR-only file
/// numbered *every* row 1 here while the gutter stepped one row per CR. The
/// break set is now exactly `lineRange`'s — LF, CR (CRLF counted once), U+0085,
/// U+2028, U+2029. Vertical tab and form feed are deliberately NOT breaks,
/// because `lineRange` does not treat them as such (verified, not assumed).
///
/// A CR cannot be resolved until the *next* unit is known — it may be the first
/// half of a CRLF pair — so the scanner carries a pending-CR index across chunk
/// boundaries and across incremental resumptions.
enum TextLineIndex {

    // MARK: - Scanner core
    //
    // One implementation of the break rules, shared by every entry point below.
    // `ScanState` is the RAW position of the scanner: `pendingCR` is set when
    // the last unit consumed was a CR whose partner has not been read, and in
    // that state `line`/`lineStart` still describe the line the CR sits on.
    // `settled(_:in:)` resolves that into the values `NSString.lineRange` would
    // report for the same offset.

    private struct ScanState {
        var line: Int = 1
        var lineStart: Int = 0
        /// Index of a CR whose successor has not been read yet, or -1.
        var pendingCR: Int = -1
        /// Next UTF-16 index to read.
        var position: Int = 0
    }

    private static let chunkSize = 4096

    /// Advances `state` from its current position to `target`
    /// (`state.position <= target <= str.length`).
    private static func advance(_ state: inout ScanState, in str: NSString, to target: Int) {
        guard target > state.position else { return }
        var buffer = [unichar](repeating: 0, count: chunkSize)
        var i = state.position
        var line = state.line
        var lineStart = state.lineStart
        var pendingCR = state.pendingCR

        while i < target {
            let len = min(chunkSize, target - i)
            let base = i
            buffer.withUnsafeMutableBufferPointer { p in
                str.getCharacters(p.baseAddress!, range: NSRange(location: base, length: len))
                // Two loops on purpose. The inner one is the whole document's
                // worth of ordinary characters, and it must stay as tight as the
                // LF-only scan this replaced — `c <= 0x0D || c >= 0x0085` rejects
                // every printable ASCII unit in two comparisons, and only then is
                // the five-way break test worth running. Putting the pending-CR
                // bookkeeping in the outer loop keeps it off that path entirely:
                // it is reached once per line break, not once per character.
                var k = 0
                while k < len {
                    if pendingCR >= 0 {
                        let cr = pendingCR
                        pendingCR = -1
                        if p[k] == 0x0A {
                            // CRLF is one break, and it swallows this LF.
                            line += 1
                            lineStart = base + k + 1
                            k += 1
                            continue
                        }
                        // Lone CR: its break ended immediately after it, and the
                        // unit under `k` still has to be classified below.
                        line += 1
                        lineStart = cr + 1
                    }

                    var j = k
                    while j < len {
                        let c = p[j]
                        if c <= 0x0D || c >= 0x0085 {
                            if c == 0x0A || c == 0x0D || c == 0x0085
                                || c == 0x2028 || c == 0x2029 { break }
                        }
                        j += 1
                    }
                    if j == len { break }

                    let index = base + j
                    if p[j] == 0x0D {
                        pendingCR = index
                    } else {
                        line += 1
                        lineStart = index + 1
                    }
                    k = j + 1
                }
            }
            i += len
        }

        state.line = line
        state.lineStart = lineStart
        state.pendingCR = pendingCR
        state.position = target
    }

    /// The (line, lineStart) `NSString.lineRange` reports for `state.position`.
    ///
    /// An offset between the CR and the LF of a CRLF pair sits *inside* the
    /// break, and `lineRange` keeps it on the line the CR ends — so a pending CR
    /// only becomes a break here when the unit at the position is not an LF.
    private static func settled(_ state: ScanState, in str: NSString) -> (line: Int, lineStart: Int) {
        guard state.pendingCR >= 0 else { return (state.line, state.lineStart) }
        if state.position < str.length, str.character(at: state.position) == 0x0A {
            return (state.line, state.lineStart)
        }
        return (state.line + 1, state.pendingCR + 1)
    }

    private static func isBreakUnit(_ c: unichar) -> Bool {
        c == 0x0A || c == 0x0D || c == 0x0085 || c == 0x2028 || c == 0x2029
    }

    /// Start of the line containing `loc`, found by walking backwards. Bounded
    /// by the length of one line, so it is the cheap half of a `Cursor` rewind.
    private static func lineStartScanningBackwards(in str: NSString, from loc: Int) -> Int {
        guard loc > 0 else { return 0 }
        var j = loc - 1
        // An offset inside a CRLF pair belongs to the line the CR ends, so the
        // CR immediately before it is not the break that starts this line.
        if str.character(at: j) == 0x0D, loc < str.length, str.character(at: loc) == 0x0A {
            if j == 0 { return 0 }
            j -= 1
        }
        while j >= 0 {
            if isBreakUnit(str.character(at: j)) { return j + 1 }
            j -= 1
        }
        return 0
    }

    // MARK: - Static lookups

    /// 1-based line number containing `loc`, and the UTF-16 offset that line starts at.
    static func lineAndStart(in str: NSString, at loc: Int) -> (line: Int, lineStart: Int) {
        let end = max(0, min(loc, str.length))
        var state = ScanState()
        advance(&state, in: str, to: end)
        return settled(state, in: str)
    }

    /// 1-based line number containing `loc`.
    static func lineNumber(in str: NSString, at loc: Int) -> Int {
        lineAndStart(in: str, at: loc).line
    }

    /// 1-based line numbers for many offsets, in a single pass over the text.
    ///
    /// Callers that need a line number per fold region used to call the single
    /// lookup in a loop, which is O(regions x length) — and `foldableLines` runs
    /// on every gutter redraw, so a 3000-line file with 300 foldable blocks
    /// copied tens of megabytes per frame. Offsets need not be sorted; the
    /// result is parallel to the input.
    static func lineNumbers(in str: NSString, at offsets: [Int]) -> [Int] {
        guard !offsets.isEmpty else { return [] }
        let order = offsets.indices.sorted { offsets[$0] < offsets[$1] }
        var result = [Int](repeating: 1, count: offsets.count)

        var state = ScanState()
        var next = 0

        while next < offsets.count {
            let target = max(0, min(offsets[order[next]], str.length))
            advance(&state, in: str, to: target)
            let line = settled(state, in: str).line
            // Every offset at this same position shares the count.
            while next < offsets.count,
                  max(0, min(offsets[order[next]], str.length)) == target {
                result[order[next]] = line
                next += 1
            }
        }
        return result
    }

    /// UTF-16 offset at which the given 1-based `line` starts. Returns the end of
    /// the string when the text has fewer lines than that.
    static func lineStart(of line: Int, in str: NSString) -> Int {
        guard line > 1 else { return 0 }

        var buffer = [unichar](repeating: 0, count: chunkSize)
        var seen = 1
        var pendingCR = -1
        var found = -1
        var base = 0

        while base < str.length && found < 0 {
            let len = min(chunkSize, str.length - base)
            let chunkStart = base
            buffer.withUnsafeMutableBufferPointer { p in
                str.getCharacters(p.baseAddress!, range: NSRange(location: chunkStart, length: len))
                for k in 0..<len {
                    let c = p[k]
                    let index = chunkStart + k
                    if pendingCR >= 0 {
                        let cr = pendingCR
                        pendingCR = -1
                        if c == 0x0A {
                            seen += 1
                            if seen == line { found = index + 1 }
                            if found >= 0 { break }
                            continue
                        }
                        seen += 1
                        if seen == line { found = cr + 1; break }
                    }
                    switch c {
                    case 0x0D:
                        pendingCR = index
                    case 0x0A, 0x0085, 0x2028, 0x2029:
                        seen += 1
                        if seen == line { found = index + 1 }
                    default:
                        break
                    }
                    if found >= 0 { break }
                }
            }
            base += len
        }

        if found >= 0 { return found }
        // A lone CR at the very end of the text still starts a (final, empty) line.
        if pendingCR >= 0 {
            seen += 1
            if seen == line { return pendingCR + 1 }
        }
        return str.length
    }

    /// 1-based line and column for `loc`. Column counts grapheme clusters.
    static func lineColumn(in str: NSString, at loc: Int) -> (line: Int, column: Int) {
        let end = max(0, min(loc, str.length))
        let (line, lineStart) = lineAndStart(in: str, at: end)
        let currentLinePrefix = str.substring(with: NSRange(location: lineStart, length: end - lineStart))
        return (line, currentLinePrefix.count + 1)
    }

    // MARK: - Cursor

    /// A memo of the last lookup, so consecutive lookups scan only the delta.
    ///
    /// `lineAndStart` is O(offset): 4.6 ms with the caret at the end of a 5 MB
    /// file. It runs four to five times per keystroke — twice from
    /// `postSelectionInfo`, once from the coordinator's status-bar push, once
    /// from the gutter's first-visible-row lookup, once more in compare mode —
    /// and again on every scroll frame, so a caret near the end of a large file
    /// spent ~20 ms per typed character recounting the same newlines.
    ///
    /// Hold one of these beside whatever counter already tracks "the text
    /// changed" and pass that as `stamp`: a different stamp throws the memo
    /// away, so a stale line number can never outlive an edit. Within one stamp
    /// the scan either walks forward from the previous offset, or rewinds to the
    /// start of the target's line and walks in from there — both bounded by the
    /// distance moved rather than by the distance from the start of the file.
    ///
    /// This is a value type on purpose: no shared mutable state, and a caller
    /// that forgets to keep it simply gets the cold cost back.
    struct Cursor {
        private var stamp: Int = .min
        private var state = ScanState()
        private var valid = false

        init() {}

        /// Throw the memo away. For callers whose stamp cannot express a change.
        mutating func invalidate() {
            valid = false
        }

        mutating func lineAndStart(in str: NSString, at loc: Int, stamp: Int)
            -> (line: Int, lineStart: Int) {
            let target = max(0, min(loc, str.length))

            if !valid || stamp != self.stamp || state.position > str.length {
                self.stamp = stamp
                state = ScanState()
                valid = true
            }

            if target < state.position {
                let settledNow = TextLineIndex.settled(state, in: str)
                let targetLineStart = TextLineIndex.lineStartScanningBackwards(in: str, from: target)
                if targetLineStart == settledNow.lineStart {
                    // Same line — just walk in from its start.
                    state = ScanState(line: settledNow.line, lineStart: targetLineStart,
                                      pendingCR: -1, position: targetLineStart)
                } else {
                    // Count the breaks between the two line starts. Both ends are
                    // line starts, so no CRLF pair straddles either boundary.
                    var counter = ScanState(line: 1, lineStart: targetLineStart,
                                            pendingCR: -1, position: targetLineStart)
                    TextLineIndex.advance(&counter, in: str, to: settledNow.lineStart)
                    let crossed = TextLineIndex.settled(counter, in: str).line - 1
                    state = ScanState(line: settledNow.line - crossed, lineStart: targetLineStart,
                                      pendingCR: -1, position: targetLineStart)
                }
            }

            TextLineIndex.advance(&state, in: str, to: target)
            return TextLineIndex.settled(state, in: str)
        }

        mutating func lineNumber(in str: NSString, at loc: Int, stamp: Int) -> Int {
            lineAndStart(in: str, at: loc, stamp: stamp).line
        }
    }
}

extension NSString {

    /// Number of leading UTF-16 units two strings share.
    ///
    /// `character(at:)` in a loop is one ObjC message per unit; the compare
    /// display diffs its old and new text this way on the main thread on every
    /// rebuild, so on a large document that is hundreds of thousands of message
    /// sends. This pulls both sides in 4 KB chunks instead.
    static func commonPrefixLength(_ a: NSString, _ b: NSString) -> Int {
        let limit = min(a.length, b.length)
        guard limit > 0 else { return 0 }

        let chunkSize = 4096
        var bufA = [unichar](repeating: 0, count: chunkSize)
        var bufB = [unichar](repeating: 0, count: chunkSize)
        var matchedTotal = 0

        while matchedTotal < limit {
            let len = min(chunkSize, limit - matchedTotal)
            let base = matchedTotal
            var matched = 0
            bufA.withUnsafeMutableBufferPointer { pa in
                bufB.withUnsafeMutableBufferPointer { pb in
                    a.getCharacters(pa.baseAddress!, range: NSRange(location: base, length: len))
                    b.getCharacters(pb.baseAddress!, range: NSRange(location: base, length: len))
                    while matched < len && pa[matched] == pb[matched] { matched += 1 }
                }
            }
            matchedTotal += matched
            if matched < len { break }
        }
        return matchedTotal
    }

    /// Number of trailing UTF-16 units two strings share, never reaching back
    /// into the `notBefore` units already claimed by the common prefix.
    static func commonSuffixLength(_ a: NSString, _ b: NSString, notBefore prefixLength: Int) -> Int {
        let limit = min(a.length - prefixLength, b.length - prefixLength)
        guard limit > 0 else { return 0 }

        let chunkSize = 4096
        var bufA = [unichar](repeating: 0, count: chunkSize)
        var bufB = [unichar](repeating: 0, count: chunkSize)
        var matchedTotal = 0

        while matchedTotal < limit {
            let len = min(chunkSize, limit - matchedTotal)
            let aStart = a.length - matchedTotal - len
            let bStart = b.length - matchedTotal - len
            var matched = 0
            bufA.withUnsafeMutableBufferPointer { pa in
                bufB.withUnsafeMutableBufferPointer { pb in
                    a.getCharacters(pa.baseAddress!, range: NSRange(location: aStart, length: len))
                    b.getCharacters(pb.baseAddress!, range: NSRange(location: bStart, length: len))
                    var k = len - 1
                    while k >= 0 && pa[k] == pb[k] { k -= 1; matched += 1 }
                }
            }
            matchedTotal += matched
            if matched < len { break }
        }
        return matchedTotal
    }
}
