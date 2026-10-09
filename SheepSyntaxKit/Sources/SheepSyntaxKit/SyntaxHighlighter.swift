import NetworkHighlightKit

/// The result of one pass.
public struct SyntaxUpdate: Sendable {
    /// Sorted, non-overlapping, over the full text, in UTF-16 units. No run
    /// crosses a line break.
    public let runs: [SyntaxRun]
    /// Where `runs` can differ from the previous pass's runs once those are
    /// shifted across the edit. nil means "anything may have changed" (the
    /// first pass); an empty array means nothing did.
    public let changedRanges: [Range<Int>]?
}

/// One document's highlighting session. Not thread-safe: keep one per
/// document and call it from one queue.
///
/// Holds the text of the last pass, where its lines are, the state each line
/// starts in, and the finished run list. `update` finds the edit as the
/// common prefix and suffix of the old and new text, re-lexes from the line
/// above the edit, and stops at the first line past it whose outgoing state
/// matches what the old text had there — every line below is then provably
/// the same as before, so its runs are shifted, not recomputed.
///
/// The result is therefore EXACTLY what a clean pass over the new text would
/// produce; there is no approximation to drift. `testIncrementalEqualsClean`
/// holds that down for every language with randomised edits.
public final class SyntaxHighlighter {
    public let grammar: SyntaxGrammar

    private var units: [UInt16] = []
    private var lineStarts: [Int] = []
    private var lineEnds: [Int] = []
    /// `states[i]` is the state line i starts in; one extra entry at the end
    /// holds the state the last line leaves.
    private var states: [LexState] = []
    public private(set) var runs: [SyntaxRun] = []
    private var hasPass = false

    public init(grammar: SyntaxGrammar) {
        self.grammar = grammar
    }

    public convenience init(language: SyntaxLanguage) {
        self.init(grammar: .language(language))
    }

    /// `network_config` for one device family (`.auto` when none was detected).
    public convenience init(networkVendor: Vendor) {
        self.init(grammar: .networkConfig(networkVendor))
    }

    /// One-shot highlight with no session.
    public static func runs(for text: String, language: SyntaxLanguage) -> [SyntaxRun] {
        SyntaxHighlighter(language: language).update(Array(text.utf16)).runs
    }

    public static func runs(for text: String, networkVendor: Vendor) -> [SyntaxRun] {
        SyntaxHighlighter(networkVendor: networkVendor).update(Array(text.utf16)).runs
    }

    public func update(_ text: String) -> SyntaxUpdate {
        update(Array(text.utf16))
    }

    public func update(_ newUnits: [UInt16]) -> SyntaxUpdate {
        guard hasPass else {
            fullPass(newUnits)
            return SyntaxUpdate(runs: runs, changedRanges: nil)
        }
        if newUnits.count == units.count, Self.commonAffixes(units, newUnits).0 == units.count {
            return SyntaxUpdate(runs: runs, changedRanges: [])
        }
        let changed = incrementalPass(newUnits)
        return SyntaxUpdate(runs: runs, changedRanges: [changed])
    }

    /// Forget everything; the next update is a clean pass.
    public func reset() {
        units = []
        lineStarts = []
        lineEnds = []
        states = []
        runs = []
        hasPass = false
    }

    // MARK: - Passes

    private func fullPass(_ newUnits: [UInt16]) {
        units = newUnits
        (lineStarts, lineEnds) = Self.scanLines(newUnits, from: 0, lineStart: 0)
        states = [LexState()]
        states.reserveCapacity(lineStarts.count + 1)
        runs = []
        hasPass = true
        let language = self.grammar
        units.withUnsafeBufferPointer { buffer in
            var ctx = LexContext(text: buffer)
            ctx.sink.runs.reserveCapacity(buffer.count / 6)
            var state = LexState()
            for line in 0..<lineStarts.count {
                lexLine(line, starts: lineStarts, ends: lineEnds, ctx: &ctx, state: &state, language: language)
                states.append(state)
            }
            runs = ctx.sink.runs
        }
    }

    private func incrementalPass(_ newUnits: [UInt16]) -> Range<Int> {
        let (prefix, suffix) = Self.commonAffixes(units, newUnits)
        let newEditEnd = newUnits.count - suffix
        let shift = newUnits.count - units.count

        // Back up to the line holding the unit BEFORE the edit (a CR that
        // becomes half of a CRLF changes the line above) — and, for a
        // language that reads ahead, over every line above whose lookahead
        // could reach it: up to `lookaheadLines`, never past a blank line,
        // the same two limits `LexContext.forEachFollowingLine` obeys.
        let anchor = Self.lineIndex(containing: max(0, prefix - 1), starts: lineStarts)
        var firstLine = anchor
        let lookahead = grammar.lookaheadLines
        while firstLine > 0, anchor - firstLine < lookahead, !isBlankLine(firstLine - 1) {
            firstLine -= 1
        }
        if lookahead > 0, firstLine > 0, anchor - firstLine < lookahead {
            // The blank line itself: harmless to re-lex, and it keeps the
            // restart point on a line whose state is certainly unaffected.
            firstLine -= 1
        }
        let restartAt = lineStarts[firstLine]

        var midStarts: [Int] = []
        var midEnds: [Int] = []
        var midStates: [LexState] = []   // outgoing state of each re-lexed line
        var state = states[firstLine]
        var freshRuns: [SyntaxRun] = []
        var rejoinOldLine: Int? = nil
        var changedEnd = newUnits.count
        let language = self.grammar
        let oldStarts = lineStarts
        let oldStates = states

        newUnits.withUnsafeBufferPointer { buffer in
            var ctx = LexContext(text: buffer)
            var position = restartAt
            while true {
                let (contentEnd, nextStart) = Self.lineBounds(buffer, from: position)
                midStarts.append(position)
                midEnds.append(contentEnd)
                lexLine(
                    firstLine + midStarts.count - 1, start: position, end: contentEnd,
                    ctx: &ctx, state: &state, language: language
                )
                midStates.append(state)

                guard let next = nextStart else {
                    changedEnd = buffer.count
                    break
                }
                // Every line from `next` on is old text, shifted: stop as soon
                // as the state entering it is the state the old text had.
                if next > newEditEnd {
                    let oldStart = next - shift
                    let oldLine = Self.lineIndex(containing: oldStart, starts: oldStarts)
                    if oldStarts[oldLine] == oldStart, oldStates[oldLine] == state {
                        rejoinOldLine = oldLine
                        changedEnd = next
                        break
                    }
                }
                position = next
            }
            freshRuns = ctx.sink.runs
        }

        // Splice in place: [0, firstLine) is untouched, the middle is new, and
        // the tail from the rejoin line on is old, shifted by `shift`.
        let oldLineEnd = rejoinOldLine ?? lineStarts.count
        let runsStart = Self.firstRun(atOrAfter: restartAt, in: runs)
        let runsEnd = rejoinOldLine.map { Self.firstRun(atOrAfter: lineStarts[$0], in: runs) } ?? runs.count

        lineStarts.replaceSubrange(firstLine..<oldLineEnd, with: midStarts)
        lineEnds.replaceSubrange(firstLine..<oldLineEnd, with: midEnds)
        // states[i] is the state entering line i; the rejoin line keeps its own.
        if rejoinOldLine != nil { midStates.removeLast() }
        states.replaceSubrange((firstLine + 1)..<(oldLineEnd + (rejoinOldLine == nil ? 1 : 0)), with: midStates)
        runs.replaceSubrange(runsStart..<runsEnd, with: freshRuns)

        if shift != 0, rejoinOldLine != nil {
            let tailLines = (firstLine + midStarts.count)..<lineStarts.count
            for index in tailLines {
                lineStarts[index] += shift
                lineEnds[index] += shift
            }
            for index in (runsStart + freshRuns.count)..<runs.count {
                runs[index].location += shift
            }
        }
        units = newUnits
        return restartAt..<changedEnd
    }

    private func lexLine(
        _ line: Int,
        starts: [Int],
        ends: [Int],
        ctx: inout LexContext,
        state: inout LexState,
        language: SyntaxGrammar
    ) {
        lexLine(line, start: starts[line], end: ends[line], ctx: &ctx, state: &state, language: language)
    }

    private func isBlankLine(_ line: Int) -> Bool {
        var index = lineStarts[line]
        let end = lineEnds[line]
        while index < end, isSpace(units[index]) { index += 1 }
        return index == end
    }

    private func lexLine(
        _ line: Int,
        start: Int,
        end: Int,
        ctx: inout LexContext,
        state: inout LexState,
        language: SyntaxGrammar
    ) {
        ctx.lineStart = start
        ctx.lineEnd = end
        ctx.lookaheadLines = language.lookaheadLines
        ctx.isFirstLine = line == 0
        ctx.sink.lineFloor = start
        ctx.sink.lineCeiling = end
        language.lex(&ctx, start, end, &state)
        language.finishLine(&state)
    }

    // MARK: - Lines

    /// Lines end at LF, CR or CRLF. The segment after the last terminator is
    /// a line too, so a text ending in a newline has an empty last line.
    static func scanLines(_ text: [UInt16], from: Int, lineStart: Int) -> ([Int], [Int]) {
        var starts: [Int] = []
        var ends: [Int] = []
        text.withUnsafeBufferPointer { buffer in
            var position = from
            while true {
                let (contentEnd, next) = lineBounds(buffer, from: position)
                starts.append(position)
                ends.append(contentEnd)
                guard let next else { break }
                position = next
            }
        }
        return (starts, ends)
    }

    @inline(__always)
    static func lineBounds(_ buffer: UnsafeBufferPointer<UInt16>, from: Int) -> (contentEnd: Int, next: Int?) {
        var index = from
        let count = buffer.count
        while index < count {
            let unit = buffer[index]
            if unit == 0x0A { return (index, index + 1) }
            if unit == 0x0D {
                if index + 1 < count, buffer[index + 1] == 0x0A { return (index, index + 2) }
                return (index, index + 1)
            }
            index += 1
        }
        return (count, nil)
    }

    static func lineIndex(containing position: Int, starts: [Int]) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= position { low = mid } else { high = mid - 1 }
        }
        return low
    }

    static func firstRun(atOrAfter location: Int, in runs: [SyntaxRun]) -> Int {
        var low = 0
        var high = runs.count
        while low < high {
            let mid = (low + high) / 2
            if runs[mid].location < location { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Common prefix and suffix lengths, never overlapping and never splitting
    /// a surrogate pair.
    static func commonAffixes(_ old: [UInt16], _ new: [UInt16]) -> (Int, Int) {
        old.withUnsafeBufferPointer { a in
            new.withUnsafeBufferPointer { b in
                let limit = min(a.count, b.count)
                var prefix = 0
                while prefix < limit, a[prefix] == b[prefix] { prefix += 1 }
                if prefix > 0, prefix < limit, (0xD800...0xDBFF).contains(a[prefix - 1]) { prefix -= 1 }
                var suffix = 0
                while suffix < a.count - prefix, suffix < b.count - prefix,
                      a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
                    suffix += 1
                }
                if suffix > 0, suffix < a.count, (0xDC00...0xDFFF).contains(a[a.count - suffix]) { suffix -= 1 }
                return (prefix, suffix)
            }
        }
    }
}
