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
/// Semantics are exactly those of the code it replaces: the line is the number
/// of `\n` before `loc` plus one, and the column is the **Character** (grapheme
/// cluster) count of the current line's prefix plus one — not a UTF-16 count, so
/// Thai combining marks and emoji still count as one column each.
enum TextLineIndex {

    /// 1-based line number containing `loc`, and the UTF-16 offset that line starts at.
    static func lineAndStart(in str: NSString, at loc: Int) -> (line: Int, lineStart: Int) {
        let end = max(0, min(loc, str.length))
        var line = 1
        var lineStart = 0

        let chunkSize = 4096
        var buffer = [unichar](repeating: 0, count: chunkSize)
        var i = 0
        while i < end {
            let len = min(chunkSize, end - i)
            let base = i
            buffer.withUnsafeMutableBufferPointer { p in
                str.getCharacters(p.baseAddress!, range: NSRange(location: base, length: len))
                for k in 0..<len where p[k] == 0x0A {
                    line += 1
                    lineStart = base + k + 1
                }
            }
            i += len
        }
        return (line, lineStart)
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

        let chunkSize = 4096
        var buffer = [unichar](repeating: 0, count: chunkSize)
        var line = 1
        var scanned = 0                 // UTF-16 units already counted
        var next = 0                    // index into `order`

        while next < offsets.count {
            let target = max(0, min(offsets[order[next]], str.length))
            while scanned < target {
                let len = min(chunkSize, target - scanned)
                let base = scanned
                buffer.withUnsafeMutableBufferPointer { p in
                    str.getCharacters(p.baseAddress!, range: NSRange(location: base, length: len))
                    for k in 0..<len where p[k] == 0x0A { line += 1 }
                }
                scanned += len
            }
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

        let chunkSize = 4096
        var buffer = [unichar](repeating: 0, count: chunkSize)
        var seen = 1
        var base = 0

        while base < str.length {
            let len = min(chunkSize, str.length - base)
            let chunkStart = base
            var found = -1
            buffer.withUnsafeMutableBufferPointer { p in
                str.getCharacters(p.baseAddress!, range: NSRange(location: chunkStart, length: len))
                for k in 0..<len where p[k] == 0x0A {
                    seen += 1
                    if seen == line {
                        found = chunkStart + k + 1
                        break
                    }
                }
            }
            if found >= 0 { return found }
            base += len
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
