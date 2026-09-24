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
    /// Lines are counted by splitting on the newline scalar for `.lf` and `.crlf`,
    /// which is the boundary `LineHashing.splitLines` uses and therefore the array
    /// the pipeline's `realLineNumber` indexes (a CRLF document's elements then
    /// still carry the trailing `\r`). `.cr` splits on the carriage return instead
    /// and is correct as a function, but **the app never reaches it**: the pipeline
    /// sees a CR-only document as a single row, so the two halves disagree about
    /// what line 1 is, and `Coordinator.compareTransfersAreSupported` withholds the
    /// arrows for such a document rather than transfer the whole file.
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

        if lineEnding == .crlf {
            // A CRLF document's LF-split elements all carry a trailing "\r" except the
            // LAST one, which has no terminator at all — that is the whole reason the
            // join below can be a bare "\n". Splicing can change WHICH element is last,
            // so both ends of that invariant have to be restored:
            //
            // * the element the block was inserted AFTER used to be last (no "\r") and
            //   is now interior. That is the append-at-the-end case, which is exactly
            //   what `CompareTransferGeometry.replaceRange` returns for an all-filler
            //   block at the bottom of the file — the common "the other pane has extra
            //   lines down here" transfer — and it wrote a bare LF into the document;
            // * the element that ENDS UP last must shed the "\r" the incoming lines
            //   were given (or the one it carried while it was interior).
            //
            // Only those two positions are touched. A stray LF anywhere else in the
            // document is content the user put there, not ours to rewrite.
            if replaceStart > 0, replaceStart - 1 < docLines.count - 1,
               !docLines[replaceStart - 1].hasSuffix("\r") {
                docLines[replaceStart - 1] += "\r"
            }
            if let last = docLines.last, last.hasSuffix("\r") {
                docLines[docLines.count - 1] = String(last.dropLast())
            }
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
