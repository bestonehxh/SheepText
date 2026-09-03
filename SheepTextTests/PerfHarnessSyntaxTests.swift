//
//  PerfHarnessSyntaxTests.swift
//  Syntax-engine half of the before/after performance harness (audit 2026-09,
//  findings S6 / S7 / S11).
//
//  Deliberately written against the API that already exists on the pre-fix
//  commit — `highlightImmediately(text:language:isDark:documentID:)` and
//  nothing else — so the orchestrator can run this class on both sides of the
//  fix and diff the medians.
//
//  Each workload prints one `PERF {...}` JSON line. Checksums must match across
//  runs: a faster number with a different checksum is a behaviour change, not
//  an optimisation. Every "keystroke" workload replaces a single character at a
//  fixed offset, so the document length — and therefore the checksum — is
//  constant across iterations.
//

import AppKit
import XCTest
@testable import SheepText

@MainActor
final class PerfHarnessSyntaxTests: XCTestCase {

    // MARK: - Fixtures

    /// ~20 000 lines / ~600k characters of Cisco IOS, comfortably inside the
    /// range `LargeFilePolicy` still highlights (100k lines / 1M chars).
    private func ciscoConfig(lines: Int) -> String {
        var out: [String] = []
        out.reserveCapacity(lines)
        for i in 0..<lines {
            switch i % 6 {
            case 0: out.append("interface GigabitEthernet1/0/\(i % 48 + 1)")
            case 1: out.append(" description user-port-\(String(format: "%06d", i))")
            case 2: out.append(" switchport access vlan \(i % 4094 + 1)")
            case 3: out.append(" switchport trunk allowed vlan 10,20,30-40,\(i % 4094 + 1)")
            case 4: out.append(" spanning-tree mode rapid-pvst")
            default: out.append("!")
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// Aruba CX exercises all 12 ordered regex rules: interface names, VLAN
    /// lists, IPv4, MAC, IPv6, state words and comments.
    private func arubaConfig(lines: Int) -> String {
        var out: [String] = []
        out.reserveCapacity(lines)
        for i in 0..<lines {
            switch i % 8 {
            case 0: out.append("interface 1/1/\(i % 48 + 1)")
            case 1: out.append("    description uplink-\(String(format: "%06d", i))")
            case 2: out.append("    vlan trunk allowed 10,20-30,\(i % 4000 + 1)")
            case 3: out.append("    ip address 10.\(i % 250).\(i % 200).\(i % 240)/24")
            case 4: out.append("    mac-address aabb.ccdd.\(String(format: "%04x", i % 65535))")
            case 5: out.append("    state connected up enabled")
            case 6: out.append("    last error down err-disabled warning")
            default: out.append("! section \(i)")
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    private func swiftSource(chars: Int) -> String {
        let line = "func value(_ input: Int) -> Int { let result = input * 2; return result } // probe 0\n"
        return String(repeating: line, count: chars / (line as NSString).length)
    }

    /// One HTML document whose `<script>` element holds 2000 lines of
    /// JavaScript — the injection site finding S11 is about.
    private func htmlWithScript(scriptLines: Int) -> String {
        var js: [String] = []
        js.reserveCapacity(scriptLines)
        for i in 0..<scriptLines {
            js.append("  const value\(i) = compute(\(i), \"label-\(String(format: "%05d", i))\");")
        }
        return """
        <!doctype html>
        <html>
        <head><title>probe</title></head>
        <body>
        <div id="root">hello</div>
        <script>
        function compute(n, label) { return n * 2 + label.length; }
        \(js.joined(separator: "\n"))
        </script>
        </body>
        </html>
        """
    }

    /// Ten equal-length variants of `base`, differing only in the single
    /// character at `offset`. Precomputed so the measured body does no string
    /// building of its own.
    private func keystrokeVariants(of base: String, at offset: Int) -> [String] {
        let digits = Array("0123456789")
        return digits.map { digit -> String in
            let mutable = NSMutableString(string: base)
            mutable.replaceCharacters(in: NSRange(location: offset, length: 1), with: String(digit))
            return mutable as String
        }
    }

    // MARK: - Full (non-incremental) passes

    /// S7: the same shape as `PerfHarnessTests.syntax_clean_swift_100k`, under
    /// its own name so both classes can be run and compared side by side.
    func testPerfSyntaxFullSwift100kV2() {
        let text = swiftSource(chars: 100_000)
        PerfHarness.measure("syntax_full_swift_100k_v2", samples: 5) {
            SyntaxEngine.shared.highlightImmediately(text: text, language: "swift", isDark: true)?.length ?? -1
        }
    }

    func testPerfSyntaxFullCisco20k() {
        let text = ciscoConfig(lines: 20_000)
        PerfHarness.measure("syntax_cisco_full_20k", samples: 5) {
            SyntaxEngine.shared.highlightImmediately(text: text, language: "cisco_ios", isDark: true)?.length ?? -1
        }
    }

    func testPerfSyntaxFullAruba20k() {
        let text = arubaConfig(lines: 20_000)
        PerfHarness.measure("syntax_aruba_full_20k", samples: 5) {
            SyntaxEngine.shared.highlightImmediately(text: text, language: "aruba_cx", isDark: true)?.length ?? -1
        }
    }

    // MARK: - Keystroke (incremental) passes

    func testPerfSyntaxCiscoIncremental20kKeystroke() {
        let base = ciscoConfig(lines: 20_000)
        let offset = (base as NSString).length / 2
        let variants = keystrokeVariants(of: base, at: offset)
        let id = UUID()
        _ = SyntaxEngine.shared.highlightImmediately(
            text: base, language: "cisco_ios", isDark: true, documentID: id
        )
        var counter = 0
        PerfHarness.measure("syntax_cisco_incremental_20k_keystroke", samples: 11) {
            counter += 1
            return SyntaxEngine.shared.highlightImmediately(
                text: variants[counter % variants.count],
                language: "cisco_ios", isDark: true, documentID: id
            )?.length ?? -1
        }
        SyntaxEngine.shared.discardSession(for: id)
    }

    func testPerfSyntaxArubaIncremental20kKeystroke() {
        let base = arubaConfig(lines: 20_000)
        let offset = (base as NSString).length / 2
        let variants = keystrokeVariants(of: base, at: offset)
        let id = UUID()
        _ = SyntaxEngine.shared.highlightImmediately(
            text: base, language: "aruba_cx", isDark: true, documentID: id
        )
        var counter = 0
        PerfHarness.measure("syntax_aruba_incremental_20k_keystroke", samples: 11) {
            counter += 1
            return SyntaxEngine.shared.highlightImmediately(
                text: variants[counter % variants.count],
                language: "aruba_cx", isDark: true, documentID: id
            )?.length ?? -1
        }
        SyntaxEngine.shared.discardSession(for: id)
    }

    /// S11: an edit inside a 2000-line `<script>` block. The injected region is
    /// re-parsed once per changed range, so this is the workload that shows
    /// whether the ranges were unioned before the injection pass ran.
    func testPerfSyntaxHTMLInjectionKeystroke() {
        let base = htmlWithScript(scriptLines: 2000)
        let ns = base as NSString
        let anchor = ns.range(of: "label-01000")
        let offset = anchor.location == NSNotFound ? ns.length / 2 : anchor.location + 6
        let variants = keystrokeVariants(of: base, at: offset)
        let id = UUID()
        _ = SyntaxEngine.shared.highlightImmediately(
            text: base, language: "html", isDark: true, documentID: id
        )
        var counter = 0
        PerfHarness.measure("syntax_html_injection_2000_script_keystroke", samples: 7) {
            counter += 1
            return SyntaxEngine.shared.highlightImmediately(
                text: variants[counter % variants.count],
                language: "html", isDark: true, documentID: id
            )?.length ?? -1
        }
        SyntaxEngine.shared.discardSession(for: id)
    }

    func testPerfSyntaxHTMLInjectionFull() {
        let text = htmlWithScript(scriptLines: 2000)
        PerfHarness.measure("syntax_html_injection_2000_script_full", samples: 5) {
            SyntaxEngine.shared.highlightImmediately(text: text, language: "html", isDark: true)?.length ?? -1
        }
    }
}
