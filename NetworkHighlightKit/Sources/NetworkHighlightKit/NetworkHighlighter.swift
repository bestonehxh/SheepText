import Foundation

/// A rule name. The host app maps this onto its own token colour; the package
/// deliberately carries no colours of its own (see `NetworkHighlightDefaults`
/// for SheepTerm's palette as reference data).
public typealias NetworkRule = HighlightScanner.BuiltIn

/// One highlighted range and the rule that claimed it.
///
/// `range` is measured in whichever unit the producing call documents: UTF-8
/// byte offsets from `scanLine`/`scanUTF8`, UTF-16 offsets (the NSString world
/// an `NSTextStorage` lives in) from `spans(in:)`.
public struct NetworkSpan: Equatable, Hashable, Sendable {
    public let range: Range<Int>
    public let rule: NetworkRule

    public init(range: Range<Int>, rule: NetworkRule) {
        self.range = range
        self.rule = rule
    }
}

/// The network-device highlighter, as a line-oriented editor wants it.
///
/// ```swift
/// let hl = NetworkHighlighter(vendor: .cisco)
/// for span in hl.spans(in: document.text) {          // UTF-16 offsets
///     storage.addAttribute(.foregroundColor,
///                          value: color(for: span.rule),
///                          range: NSRange(span.range))
/// }
/// ```
///
/// Every rule is LINE-LOCAL: no match can span a `\n`, so re-scanning only the
/// lines an edit touched gives exactly the result a whole-document scan would
/// (asserted by `testPerLineEqualsWholeText`). That is the property the
/// incremental path in an editor is built on.
///
/// The value is immutable and `Sendable`; the profile it holds is shared, so
/// copying one is free and calling it from a background queue is fine.
public struct NetworkHighlighter: Sendable {
    public let vendor: Vendor
    /// The keyword tables for this vendor. Shared, immutable.
    public let profile: HighlightScanner.Profile
    /// The rules this vendor uses at all, in priority order.
    public let rules: [NetworkRule]
    private let enabledMask: UInt16

    public init(vendor: Vendor) {
        self.vendor = vendor
        let profile = HighlightScanner.profile(for: vendor)
        self.profile = profile
        rules = NetworkRule.allCases.filter { profile.rules & HighlightScanner.bit(of: $0) != 0 }
        enabledMask = profile.rules
    }

    // MARK: - Line scanning (UTF-8 byte offsets)

    /// Spans for ONE line, as UTF-8 byte offsets inside that line.
    ///
    /// The buffer should not contain a newline: nothing breaks if it does (no
    /// rule can cross one), but the offsets are then relative to the whole
    /// buffer rather than to a line.
    public func scanLine(_ utf8: HighlightScanner.Bytes) -> [NetworkSpan] {
        let scratch = HighlightScanner.Scratch()
        scanLine(utf8, into: scratch)
        return scratch.claimed
    }

    /// `scanLine` with the caller's workspace, leaving the spans in
    /// `scratch.claimed` instead of returning a fresh array.
    ///
    /// This is the form the whole-text paths use: one `Scratch` for the whole
    /// document, reset per line, so a 20 000-line config allocates the buckets
    /// once rather than ~440 000 times. Reading the result out of the scratch
    /// rather than returning it is the other half — returning it would leave a
    /// second reference on the buffer and the next `reset()` would copy it.
    func scanLine(_ utf8: HighlightScanner.Bytes, into scratch: HighlightScanner.Scratch) {
        scratch.reset()
        HighlightScanner.scan(utf8, enabledMask: enabledMask, profile: profile, scratch: scratch)
        Self.claim(into: scratch, rules: rules)
    }

    public func scanLine(_ utf8: [UInt8]) -> [NetworkSpan] {
        utf8.withUnsafeBufferPointer { scanLine($0) }
    }

    public func scanLine(_ utf8: Substring.UTF8View) -> [NetworkSpan] {
        if let spans = utf8.withContiguousStorageIfAvailable({ scanLine($0) }) {
            return spans
        }
        return scanLine(Array(utf8))
    }

    public func scanLine(_ line: String) -> [NetworkSpan] {
        var copy = line
        return copy.withUTF8 { scanLine($0) }
    }

    /// Spans for a whole UTF-8 buffer, as byte offsets. Identical to scanning
    /// each line separately and shifting by the line's start — the rules are
    /// line-local — so use whichever is convenient.
    public func scanUTF8(_ utf8: HighlightScanner.Bytes) -> [NetworkSpan] {
        scanLine(utf8)
    }

    public func scanUTF8(_ utf8: [UInt8]) -> [NetworkSpan] {
        utf8.withUnsafeBufferPointer { scanLine($0) }
    }

    // MARK: - Whole text (UTF-16 offsets)

    /// Spans over a whole string, with ranges in UTF-16 offsets — what
    /// `NSTextStorage`, `NSRange` and `NSLayoutManager` count in.
    ///
    /// ASCII fast path: when the document has no byte >= 0x80 the two counts
    /// coincide and no mapping work happens at all. Otherwise the mapping is
    /// done per line, walking only the lines that actually contain a non-ASCII
    /// byte: one UTF-8 lead byte is one UTF-16 unit, except a 4-byte sequence
    /// (U+10000 and up — emoji), which is a surrogate PAIR and therefore two.
    public func spans(in text: String) -> [NetworkSpan] {
        var copy = text
        return copy.withUTF8 { buffer in spansUTF16(in: buffer) }
    }

    /// The buffer form of `spans(in:)`, for a caller that already holds UTF-8.
    public func spansUTF16(in buffer: HighlightScanner.Bytes) -> [NetworkSpan] {
        var out: [NetworkSpan] = []
        // ONE workspace for the whole document — see `HighlightScanner.Scratch`.
        let scratch = HighlightScanner.Scratch()
        var lineStart = 0
        var utf16LineStart = 0
        let n = buffer.count
        var i = 0
        while lineStart <= n {
            // Find the end of this line (the 0x0A scalar; a CR before it is
            // just another byte and no rule matches one), and note on the SAME
            // walk whether it is all ASCII. That answer used to come from a
            // second pass (`isASCII`) and the UTF-16 length from a third
            // (`utf16Length`) — on an ASCII document, which is what a config
            // almost always is, that was two extra passes over every byte for a
            // count `line.count` already gives.
            i = lineStart
            var lineIsASCII = true
            while i < n {
                let byte = buffer[i]
                if byte == 0x0A { break }
                if byte >= 0x80 { lineIsASCII = false }
                i += 1
            }
            let lineEnd = i

            if lineEnd > lineStart {
                let line = HighlightScanner.Bytes(
                    rebasing: buffer[lineStart..<lineEnd]
                )
                scanLine(line, into: scratch)
                if lineIsASCII {
                    // Byte offset == UTF-16 offset on this line.
                    for span in scratch.claimed {
                        out.append(NetworkSpan(
                            range: (utf16LineStart + span.range.lowerBound)
                                ..< (utf16LineStart + span.range.upperBound),
                            rule: span.rule
                        ))
                    }
                    utf16LineStart += line.count
                } else {
                    // Appends nothing when the line matched nothing, so the
                    // empty case needs no branch of its own.
                    Self.appendMapped(
                        scratch.claimed, of: line, base: utf16LineStart, into: &out
                    )
                    utf16LineStart += Self.utf16Length(of: line)
                }
            }

            if lineEnd == n { break }
            utf16LineStart += 1          // the \n itself
            lineStart = lineEnd + 1
        }
        return out
    }

    // MARK: - UTF-8 -> UTF-16 offset mapping

    /// Not used by `spansUTF16` any more — it learns the same thing for free on
    /// the walk that finds the line's end. Kept because it is the readable
    /// statement of what that flag means, and the tests assert against it.
    @inline(__always)
    static func isASCII(_ b: HighlightScanner.Bytes) -> Bool {
        for byte in b where byte >= 0x80 { return false }
        return true
    }

    /// UTF-16 length of a UTF-8 buffer: continuation bytes contribute nothing,
    /// a 4-byte lead contributes two (surrogate pair), everything else one.
    /// Malformed bytes are counted as one so the walk can never desynchronise.
    @inline(__always)
    static func utf16Length(of b: HighlightScanner.Bytes) -> Int {
        var units = 0
        for byte in b {
            if byte & 0xC0 == 0x80 { continue }      // continuation
            units += (byte >= 0xF0) ? 2 : 1
        }
        return units
    }

    /// Walk the line once, converting every span endpoint from a byte offset to
    /// a UTF-16 offset. The endpoints are sorted and non-overlapping (the claim
    /// pass guarantees it), so one pass suffices.
    static func appendMapped(
        _ spans: [NetworkSpan], of line: HighlightScanner.Bytes,
        base: Int, into out: inout [NetworkSpan]
    ) {
        var byteOffset = 0
        var utf16Offset = 0
        var cursor = 0                                // index into `spans`
        var pendingLower: Int?

        @inline(__always) func advance(to target: Int) {
            while byteOffset < target, byteOffset < line.count {
                let byte = line[byteOffset]
                byteOffset += 1
                if byte & 0xC0 == 0x80 { continue }
                utf16Offset += (byte >= 0xF0) ? 2 : 1
            }
        }

        while cursor < spans.count {
            let span = spans[cursor]
            if pendingLower == nil {
                advance(to: span.range.lowerBound)
                pendingLower = utf16Offset
            }
            advance(to: span.range.upperBound)
            out.append(NetworkSpan(
                range: (base + pendingLower!) ..< (base + utf16Offset),
                rule: span.rule
            ))
            pendingLower = nil
            cursor += 1
        }
    }

    // MARK: - Priority claiming

    /// Merge per-rule matches into one non-overlapping, position-sorted list.
    ///
    /// Rule order IS priority: an earlier rule claims its ranges first and a
    /// later rule's match is dropped whole if it overlaps anything already
    /// claimed. That is SheepTerm's `claimedSpans` two-finger merge, unchanged
    /// in behaviour — claimed spans stay sorted and disjoint, and each rule's
    /// matches arrive sorted, so each rule merges in one linear pass with no
    /// mid-array insertions.
    static func claim(_ perRule: [[Range<Int>]], rules: [NetworkRule]) -> [NetworkSpan] {
        let scratch = HighlightScanner.Scratch()
        scratch.perRule = perRule
        claim(into: scratch, rules: rules)
        return scratch.claimed
    }

    /// The same merge, out of a `Scratch`: it reads `scratch.perRule` and
    /// leaves the result in `scratch.claimed`, swapping the two span buffers
    /// instead of building a new `merged` array per rule. Across the lines of a
    /// document that is one allocation for the widest line rather than one per
    /// rule per line.
    static func claim(into scratch: HighlightScanner.Scratch, rules: [NetworkRule]) {
        // Same take-and-put-back as `HighlightScanner.scan`: mutating these
        // through the object would re-check exclusivity on every append, and
        // holding `perRule` by value here keeps the buckets alive for the loop
        // without the object's own reference blocking their reuse afterwards.
        var claimed = scratch.claimed
        var merged = scratch.merged
        scratch.claimed = []
        scratch.merged = []
        claimed.removeAll(keepingCapacity: true)
        let perRule = scratch.perRule
        for rule in rules {
            let matches = perRule[HighlightScanner.ordinal(of: rule)]
            if matches.isEmpty { continue }
            merged.removeAll(keepingCapacity: true)
            merged.reserveCapacity(claimed.count + matches.count)
            var ci = 0
            for match in matches where !match.isEmpty {
                while ci < claimed.count, claimed[ci].range.upperBound <= match.lowerBound {
                    merged.append(claimed[ci])
                    ci += 1
                }
                // Overlaps a claimed span — drop this match, keep `ci`.
                if ci < claimed.count, claimed[ci].range.lowerBound < match.upperBound { continue }
                merged.append(NetworkSpan(range: match, rule: rule))
            }
            while ci < claimed.count {   // remaining spans start past the last match
                merged.append(claimed[ci])
                ci += 1
            }
            swap(&claimed, &merged)
        }
        scratch.claimed = claimed
        scratch.merged = merged
    }
}
