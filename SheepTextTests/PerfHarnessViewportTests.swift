//
//  PerfHarnessViewportTests.swift
//  Before/after workloads for the viewport apply.
//
//  The audit measured the *engine* at ~11 ms for an incremental pass on 100 KB
//  and the *apply* at 65 ms on 542 KB — the apply being the whole-document
//  `setAttributes` + `enumerateAttributes` walk, on the main thread, run on tab
//  switch, appearance change and every dropped completion. This class measures
//  the two shapes against the same 540 KB fixture and the same run list:
//
//    apply_full_storage_540k_swift        ← what the apply used to do
//    apply_viewport_540k_swift            ← what it does now: one screenful
//    apply_scroll_540k_swift              ← 20 scroll steps, each a thin strip
//    apply_appearance_change_540k_swift   ← a theme flip: scrub + repaint
//
//  Written against public API only — a real TextKit 1 stack, the engine's
//  `runsImmediately`, and `NSLayoutManager`'s temporary attributes — so it
//  compiles and runs in Release as well as Debug, with no DEBUG-only seam.
//

import AppKit
import XCTest
@testable import SheepText

@MainActor
final class PerfHarnessViewportTests: XCTestCase {

    // MARK: - Fixtures

    /// ~540 KB of Swift: the size the 65 ms apply was measured at.
    private static let source: String = {
        let line = "func value(_ input: Int) -> Int { let result = input * 2; return result } // probe 0\n"
        return String(repeating: line, count: 540_000 / (line as NSString).length)
    }()

    /// 60 lines' worth of characters — a full screen on a large display.
    private static let visibleLength = 60 * 85

    private struct Stack {
        let storage: NSTextStorage
        let layoutManager: NSLayoutManager
        let container: NSTextContainer
        let baseAttributes: [NSAttributedString.Key: Any]
    }

    private func makeStack() -> Stack {
        let storage = NSTextStorage(string: Self.source)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: NSSize(width: 900, height: CGFloat.greatestFiniteMagnitude)
        )
        layoutManager.addTextContainer(container)
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let base: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: NSParagraphStyle.default,
            .ligature: 0
        ]
        storage.setAttributes(base, range: NSRange(location: 0, length: storage.length))
        return Stack(storage: storage, layoutManager: layoutManager,
                     container: container, baseAttributes: base)
    }

    private func runs() -> [HighlightRun] {
        SyntaxEngine.shared.runsImmediately(text: Self.source, language: "swift")?.runs ?? []
    }

    private func palette() -> [[NSAttributedString.Key: Any]] {
        HighlightStyleTable.styles.indices.map {
            HighlightStyleTable.attributes(HighlightStyleID($0), isDark: true)
        }
    }

    // MARK: - The old shape

    /// What every apply used to cost: wipe the whole storage back to base
    /// attributes, then walk the engine's document-sized attributed string and
    /// copy every run in. Independent of what is on screen.
    func testPerfApplyFullStorage() {
        let stack = makeStack()
        let highlighted = HighlightRunList.attributedString(
            text: Self.source, runs: runs(), isDark: true
        )
        let full = NSRange(location: 0, length: stack.storage.length)
        PerfHarness.measure("apply_full_storage_540k_swift", samples: 5) {
            stack.storage.beginEditing()
            stack.storage.setAttributes(stack.baseAttributes, range: full)
            var count = 0
            highlighted.enumerateAttributes(in: full, options: []) { attrs, range, _ in
                guard !attrs.isEmpty else { return }
                stack.storage.addAttributes(attrs, range: range)
                count += 1
            }
            stack.storage.endEditing()
            return count
        }
    }

    // MARK: - The new shape

    /// One screenful painted from the run list: find the runs that intersect
    /// the visible range and hand each to `addTemporaryAttributes`.
    func testPerfApplyViewport() {
        let stack = makeStack()
        let runs = runs()
        let palette = palette()
        var offset = 0
        PerfHarness.measure("apply_viewport_540k_swift", samples: 7) {
            // Walk the document a screen at a time so no sample is measuring a
            // range the previous one left painted.
            let visible = NSRange(
                location: offset % max(1, stack.storage.length - Self.visibleLength),
                length: Self.visibleLength
            )
            offset += Self.visibleLength
            return Self.paint(visible, runs: runs, palette: palette, in: stack)
        }
    }

    /// Twenty scroll steps, each exposing a fifth of a screen — the strip the
    /// paint actually has to cover when the user drags the scroller.
    func testPerfApplyScroll() {
        let stack = makeStack()
        let runs = runs()
        let palette = palette()
        let step = Self.visibleLength / 5
        PerfHarness.measure("apply_scroll_540k_swift", samples: 5) {
            var count = 0
            for index in 0..<20 {
                let strip = NSRange(location: index * step, length: step)
                count &+= Self.paint(strip, runs: runs, palette: palette, in: stack)
            }
            return count
        }
    }

    /// A theme change: the palette moves, so everything painted is scrubbed and
    /// the viewport is painted again. No parse, no query, no storage write —
    /// this used to be a whole-document re-highlight per open pane.
    func testPerfApplyAppearanceChange() {
        let stack = makeStack()
        let runs = runs()
        let dark = palette()
        let light = HighlightStyleTable.styles.indices.map {
            HighlightStyleTable.attributes(HighlightStyleID($0), isDark: false)
        }
        let visible = NSRange(location: 200_000, length: Self.visibleLength)
        var isDark = true
        PerfHarness.measure("apply_appearance_change_540k_swift", samples: 7) {
            for key in HighlightStyleTable.ownedAttributeKeys {
                stack.layoutManager.removeTemporaryAttribute(
                    key, forCharacterRange: NSRange(location: 0, length: stack.storage.length)
                )
            }
            isDark.toggle()
            return Self.paint(visible, runs: runs, palette: isDark ? dark : light, in: stack)
        }
    }

    // MARK: - The engine, without the attributed-string shim
    //
    // `PerfHarnessSyntaxTests`' `syntax_*_keystroke` workloads call
    // `highlightImmediately`, which now materialises an `NSAttributedString`
    // from the run list — one `addAttributes` per token — purely so the tests
    // can compare two passes attribute for attribute. **The app never does
    // that.** These two workloads are the same edits through the path the app
    // actually takes, so the engine's own cost can be read without the shim's.

    func testPerfSyntaxRunsIncrementalSwift100k() {
        let base = String(
            repeating: "func value(_ input: Int) -> Int { let result = input * 2; return result } // probe 0\n",
            count: 100_000 / 85
        )
        let offset = (base as NSString).length - 20
        let variants = (0..<10).map { digit -> String in
            let mutable = NSMutableString(string: base)
            mutable.replaceCharacters(in: NSRange(location: offset, length: 1),
                                      with: String(digit))
            return mutable as String
        }
        let id = UUID()
        _ = SyntaxEngine.shared.runsImmediately(text: base, language: "swift", documentID: id)
        var index = 0
        PerfHarness.measure("syntax_runs_incremental_swift_100k_keystroke", samples: 11) {
            let text = variants[index % variants.count]
            index += 1
            return SyntaxEngine.shared.runsImmediately(
                text: text, language: "swift", documentID: id
            )?.runs.count ?? -1
        }
        SyntaxEngine.shared.discardSession(for: id)
    }

    func testPerfSyntaxRunsIncrementalCisco20k() {
        var lines: [String] = []
        for i in 0..<20_000 {
            switch i % 6 {
            case 0: lines.append("interface GigabitEthernet1/0/\(i % 48 + 1)")
            case 1: lines.append(" description user-port-\(String(format: "%06d", i))")
            case 2: lines.append(" switchport access vlan \(i % 4094 + 1)")
            case 3: lines.append(" switchport trunk allowed vlan 10,20,30-40,\(i % 4094 + 1)")
            case 4: lines.append(" spanning-tree mode rapid-pvst")
            default: lines.append("!")
            }
        }
        let base = lines.joined(separator: "\n") + "\n"
        let offset = (base as NSString).length / 2
        let variants = (0..<10).map { digit -> String in
            let mutable = NSMutableString(string: base)
            mutable.replaceCharacters(in: NSRange(location: offset, length: 1),
                                      with: String(digit))
            return mutable as String
        }
        let id = UUID()
        _ = SyntaxEngine.shared.runsImmediately(text: base, language: "cisco_ios", documentID: id)
        var index = 0
        PerfHarness.measure("syntax_runs_incremental_cisco_20k_keystroke", samples: 11) {
            let text = variants[index % variants.count]
            index += 1
            return SyntaxEngine.shared.runsImmediately(
                text: text, language: "cisco_ios", documentID: id
            )?.runs.count ?? -1
        }
        SyntaxEngine.shared.discardSession(for: id)
    }

    // MARK: - The paint itself

    /// Exactly what `Coordinator.paint(displayRange:…)` does, minus the fold
    /// translation (nothing is folded here).
    private static func paint(
        _ range: NSRange,
        runs: [HighlightRun],
        palette: [[NSAttributedString.Key: Any]],
        in stack: Stack
    ) -> Int {
        let bounded = NSIntersectionRange(range, NSRange(location: 0, length: stack.storage.length))
        guard bounded.length > 0 else { return 0 }
        stack.layoutManager.removeTemporaryAttribute(.obliqueness, forCharacterRange: bounded)
        stack.layoutManager.removeTemporaryAttribute(.strokeWidth, forCharacterRange: bounded)
        stack.layoutManager.addTemporaryAttributes(
            [.foregroundColor: NSColor.textColor], forCharacterRange: bounded
        )
        var count = 0
        HighlightRunList.forEach(runs, intersecting: bounded) { runRange, style in
            let attributes = palette[Int(style)]
            guard !attributes.isEmpty else { return }
            stack.layoutManager.addTemporaryAttributes(attributes, forCharacterRange: runRange)
            count += 1
        }
        return count
    }
}
