import Foundation

/// Line-ending–correct splicing for compare-mode block transfer.
///
/// Both panes address lines by the index the compare pipeline produced, which comes
/// from splitting on the newline SCALAR (`LineHashing.splitLines`) — so on a CRLF
/// document every line but the last still carries a trailing `\r`. The transfer
/// payload, on the other hand, is line-ending neutral: the sending pane strips the
/// `\r`, and the receiving pane re-terminates for its own document. Without that
/// round trip a CRLF file receiving lines from an LF file silently became mixed.
nonisolated enum CompareBlockSplice {

    /// Strip the terminator artefact so a transferred block carries no line ending
    /// of its own.
    static func neutralize(_ line: String) -> String {
        line.hasSuffix("\r") ? String(line.dropLast()) : line
    }

    /// Replace `replaceCount` lines starting at `replaceStart` (0-based) with
    /// `replacementLines`, which must be line-ending neutral.
    ///
    /// Lines are counted by splitting on the document's own separator: the newline
    /// scalar for `.lf` and `.crlf` (a CRLF document's lines then still carry the
    /// trailing `\r`, which is what the compare pipeline's line numbers assume), and
    /// the carriage-return scalar for `.cr`. Splitting a CR-only document on `\n`
    /// used to make the whole file one element, so every `replaceStart` but 0 was
    /// rejected and the one that was accepted rewrote the entire document.
    ///
    /// Returns nil when the range does not address the text, or when the edit would be
    /// a no-op (replacing nothing with nothing).
    static func apply(
        text: String,
        replaceStart: Int,
        replaceCount: Int,
        replacementLines: [String],
        lineEnding: TextLineEnding
    ) -> String? {
        // components(separatedBy:) splits on the scalar, so "\r" and "\n" are both safe
        // here — unlike a Character-level split, which sees CRLF as one cluster.
        let separator = lineEnding == .cr ? "\r" : "\n"
        var docLines = text.components(separatedBy: separator)
        guard replaceStart >= 0,
              replaceCount >= 0,
              replaceStart + replaceCount <= docLines.count
        else { return nil }
        guard replaceCount > 0 || !replacementLines.isEmpty else { return nil }

        var incoming = replacementLines
        if lineEnding == .crlf {
            incoming = incoming.map { $0 + "\r" }
        }
        docLines.replaceSubrange(replaceStart ..< (replaceStart + replaceCount), with: incoming)

        if lineEnding == .crlf, let last = docLines.last, last.hasSuffix("\r") {
            // Nothing follows the final line, so it carries no terminator. (A file that
            // does end with a newline has "" as its last element, which never matches.)
            docLines[docLines.count - 1] = String(last.dropLast())
        }

        var result = docLines.joined(separator: separator)
        if lineEnding == .cr {
            // Belt and braces: the join above already uses CR separators, so this only
            // catches a stray LF that was inside the document (or inside a transferred
            // line) before the splice. It must never be possible to end up with an LF
            // in a CR-only document.
            result = TextContentTransforms.convertLineEndings(in: result, to: .cr)
        }
        return result
    }
}
