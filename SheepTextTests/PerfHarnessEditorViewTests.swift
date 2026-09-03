//
//  PerfHarnessEditorViewTests.swift
//  Before/after workloads for the EditorView coordinator findings (U8, U19,
//  U20, U23).
//
//  Written against the API as it exists BEFORE the fixes, because the
//  orchestrator runs this class on the pre-fix commit too. Nothing here calls a
//  symbol a fix introduced — so each finding is measured as a PAIR of workloads
//  over the same fixture: the shape the code had, and the shape it has now.
//  Read them together:
//
//    editorview_updatensview_fulltext_compare_128KB  → what U19's shortcut skips
//    statusbar_total_count_graphemes_128KB           → statusbar_total_count_utf16_128KB
//    compare_header_text_equality_128KB              → what U20's onChange did per keystroke
//    editorview_lineindex_cold_400_moves_128KB       → editorview_lineindex_cursor_400_moves_128KB
//
//  Fixture size is 128 KB so a Debug (-Onone) run of the class stays quick; the
//  shapes being measured are size-independent (all four are O(document) per
//  call, and the fixes make them O(1) or O(delta)).
//

import AppKit
import XCTest
@testable import SheepText

@MainActor
final class PerfHarnessEditorViewTests: XCTestCase {

    // MARK: - Fixtures

    /// ~128 KB, 16 UTF-16 units per line.
    static let source: String = String(repeating: "0123456789abcde\n", count: 128 * 1024 / 16)

    /// The same content in a separate buffer, so `==` cannot take the
    /// same-storage fast path — which is exactly the situation SwiftUI's
    /// `onChange(of: document.text)` is in after a keystroke is typed and undone,
    /// and the situation `updateNSView`'s comparison is in on every update.
    static let sourceCopy: String = String(Array(source))

    /// Thai, where the UTF-16 length and the grapheme count differ, so neither
    /// counting shortcut applies. ~120 KB.
    static let thaiSource: String = String(repeating: "กิน\u{0E48}ข้าวแล้วหรือยัง\n", count: 4000)

    private static func storage(_ text: String) -> NSTextStorage {
        NSTextStorage(string: text)
    }

    // MARK: - U19: what updateNSView did on every SwiftUI update

    /// `folding.fullText(from: storage)` plus the whole-string comparison
    /// against `document.text` — per SwiftUI update, on the main thread. The fix
    /// answers the same question from `Document.revision` plus a length check,
    /// so this whole workload is what it now skips.
    func testUpdateNSViewFullTextCompare() {
        let folding = FoldingManager()
        let store = Self.storage(Self.source)
        let documentText = Self.sourceCopy
        PerfHarness.measure("editorview_updatensview_fulltext_compare_128KB",
                            samples: 5, iterations: 5) {
            let viewText = folding.fullText(from: store)
            return viewText != documentText ? 1 : 0
        }
    }

    // MARK: - U8: the status bar's "N chars"

    /// `refresh` counted grapheme clusters — an O(document) grapheme-breaking
    /// pass on the main thread, on every tab switch.
    func testStatusTotalCountByGrapheme() {
        let store = Self.storage(Self.thaiSource)
        PerfHarness.measure("statusbar_total_count_graphemes_128KB", samples: 5, iterations: 5) {
            store.string.count
        }
    }

    /// What both paths do now: a stored field on the bridged NSString.
    func testStatusTotalCountByUTF16() {
        let store = Self.storage(Self.thaiSource)
        PerfHarness.measure("statusbar_total_count_utf16_128KB", samples: 5, iterations: 5) {
            (store.string as NSString).length
        }
    }

    // MARK: - U20: the compare header's per-keystroke string comparison

    /// `.onChange(of: left.text)` made SwiftUI compare the whole old and new
    /// document on every keystroke, and re-evaluate the header body with it. The
    /// fix listens for `.compareDocumentsDidChange`, which carries a document id
    /// and nothing else.
    func testCompareHeaderTextEquality() {
        let a = Self.source
        let b = Self.sourceCopy
        PerfHarness.measure("compare_header_text_equality_128KB", samples: 5, iterations: 20) {
            a == b ? 1 : 0
        }
    }

    // MARK: - U23 / T7: line + column per selection change

    /// 400 caret moves, each counted from offset 0 — what `push` did on every
    /// selection change (and once more per keystroke in compare mode).
    func testLineColumnColdLookups() {
        let ns = Self.source as NSString
        let offsets = Self.moveOffsets(length: ns.length)
        PerfHarness.measure("editorview_lineindex_cold_400_moves_128KB", samples: 5) {
            var checksum = 0
            for offset in offsets {
                checksum &+= TextLineIndex.lineColumn(in: ns, at: offset).line
            }
            return checksum
        }
    }

    /// The same 400 moves through the memo `push` now holds, stamped on the edit
    /// counter — each lookup walks the delta from the previous caret position.
    func testLineColumnCursorLookups() {
        let ns = Self.source as NSString
        let offsets = Self.moveOffsets(length: ns.length)
        PerfHarness.measure("editorview_lineindex_cursor_400_moves_128KB", samples: 5) {
            var cursor = TextLineIndex.Cursor()
            var checksum = 0
            for offset in offsets {
                // One stamp: no edits, only caret movement — the case this
                // measures. An edit changes the stamp and costs a cold scan.
                checksum &+= cursor.lineAndStart(in: ns, at: offset, stamp: 1).line
            }
            return checksum
        }
    }

    /// A caret wandering near the end of a large file: mostly small forward and
    /// backward steps, with a few longer jumps.
    private static func moveOffsets(length: Int) -> [Int] {
        var offsets: [Int] = []
        var position = length * 3 / 4
        var step = 7
        for i in 0..<400 {
            position += (i % 5 == 4) ? -step * 13 : step
            if i % 97 == 96 { position = length / 3 }
            position = max(0, min(position, length))
            offsets.append(position)
            step = step % 23 + 3
        }
        return offsets
    }
}
