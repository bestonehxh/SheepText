import Foundation

nonisolated struct HashedLine: Equatable, Sendable {
    let lineNumber: Int
    let raw: String
    let normalized: String
    let hash: UInt64
}

nonisolated enum LineHashing {
    /// Splits on the newline *scalar*.
    ///
    /// `split(separator: "\n")` compares Characters, and Swift treats CRLF as a
    /// single extended grapheme cluster — so `"a\r\nb".split(separator: "\n")`
    /// finds no separator at all and returns one element. A CRLF file therefore
    /// arrived here as a single enormous "line", which made the whole file
    /// compare against its LF twin as one changed block and pushed tens of
    /// thousands of characters through `resemblancePercent`.
    ///
    /// Working over the UTF-8 view also avoids grapheme breaking entirely, which
    /// is the expensive part of `split` on a large document. The trailing "\r"
    /// is left on the line; `normalize` strips it, and `raw` needs it because
    /// display offsets are computed from it.
    static func splitLines(_ text: String) -> [String] {
        let utf8 = text.utf8
        var lines: [String] = []
        lines.reserveCapacity(utf8.count / 32 + 1)
        var start = utf8.startIndex
        var idx = utf8.startIndex
        while idx != utf8.endIndex {
            if utf8[idx] == 0x0A {
                lines.append(String(decoding: utf8[start..<idx], as: UTF8.self))
                start = utf8.index(after: idx)
            }
            idx = utf8.index(after: idx)
        }
        lines.append(String(decoding: utf8[start..<utf8.endIndex], as: UTF8.self))
        return lines
    }

    static func extractLines(_ text: String, options: CompareOptions) -> [HashedLine] {
        hashLines(splitLines(text), options: options)
    }

    /// For callers that already split the text — the compare pipeline needs the
    /// raw lines anyway, and splitting a large document twice is pure waste.
    static func hashLines(_ lines: [String], options: CompareOptions) -> [HashedLine] {
        return lines.enumerated().map { idx, raw in
            let normalized = normalize(raw, options: options)
            return HashedLine(
                lineNumber: idx + 1,
                raw: raw,
                normalized: normalized,
                hash: fnv1a64(normalized)
            )
        }
    }

    static func normalize(_ line: String, options: CompareOptions) -> String {
        var value = line
        // Lines come from splitting on "\n" only, so CRLF input leaves a trailing "\r".
        // That's a line-ending artifact, not content — strip it unconditionally so a
        // CRLF file compares equal to its LF twin instead of flagging every line.
        if value.hasSuffix("\r") {
            value.removeLast()
        }
        if options.ignoreChangedSpaces {
            value = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        if options.ignoreCase {
            value = value.lowercased()
        }
        return value
    }

    private static func fnv1a64(_ string: String) -> UInt64 {
        let prime: UInt64 = 1099511628211
        var hash: UInt64 = 1469598103934665603
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }
}
