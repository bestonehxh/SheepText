//
//  PerfHarnessNetworkTests.swift
//  Workloads for the `network_config` language — the NetworkHighlightKit
//  scanner plus the editor's vendor layer.
//
//  The two Cisco workloads deliberately ask for the language id `cisco_ios`,
//  which is the ALIAS for `network_config` + vendor `.cisco`. That is what makes
//  a before/after comparison possible on one machine: run this class on the
//  commit before the integration and it measures the old regex-only path; run
//  it after and it measures the package path, on byte-identical input.
//
//  Everything here goes through `runsImmediately`, not `highlightImmediately`:
//  the latter materialises a document-sized `NSAttributedString`, which is not
//  something the editor does and would bury the pass being measured.
//

import XCTest
import NetworkHighlightKit
@testable import SheepText

@MainActor
final class PerfHarnessNetworkTests: XCTestCase {

    // MARK: - Fixtures

    /// ~20 000 lines of Cisco IOS. Same generator as `PerfHarnessSyntaxTests`
    /// and `PerfHarnessViewportTests` use, so the numbers line up with the
    /// existing `syntax_cisco_*` series.
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

    /// Huawei VRP `display current-configuration` output. Exercises the rules
    /// the Cisco profile does not have — `vlan batch … to …`, dash-grouped
    /// MACs and the digit-led `10GE1/0/1` port spelling.
    private func huaweiConfig(lines: Int) -> String {
        var out: [String] = []
        out.reserveCapacity(lines)
        for i in 0..<lines {
            switch i % 7 {
            case 0: out.append("interface 10GE1/0/\(i % 48 + 1)")
            case 1: out.append(" description To_Access_Switch_\(String(format: "%06d", i))")
            case 2: out.append(" port link-type trunk")
            case 3: out.append(" port trunk allow-pass vlan batch \(i % 4000 + 1) to \(i % 4000 + 4)")
            case 4: out.append(" ip address 10.\(i % 250).\(i % 200).\(i % 240) 255.255.255.0")
            case 5: out.append(" mac-address 00e0-fc12-\(String(format: "%04x", i % 65535))")
            default: out.append("#")
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: - Full passes

    func testPerfNetworkCiscoFull20k() {
        let text = ciscoConfig(lines: 20_000)
        PerfHarness.measure("network_cisco_full_20k", samples: 5) {
            SyntaxEngine.shared.runsImmediately(text: text, language: "cisco_ios")?.runs.count ?? -1
        }
    }

    func testPerfNetworkHuaweiFull20k() {
        let text = huaweiConfig(lines: 20_000)
        PerfHarness.measure("network_huawei_full_20k", samples: 5) {
            SyntaxEngine.shared.runsImmediately(
                text: text, language: "network_config:huawei"
            )?.runs.count ?? -1
        }
    }

    // MARK: - One keystroke through the session path

    func testPerfNetworkCiscoIncremental20kKeystroke() {
        let base = ciscoConfig(lines: 20_000)
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
        PerfHarness.measure("network_cisco_incremental_20k_keystroke", samples: 11) {
            let text = variants[index % variants.count]
            index += 1
            return SyntaxEngine.shared.runsImmediately(
                text: text, language: "cisco_ios", documentID: id
            )?.runs.count ?? -1
        }
        SyntaxEngine.shared.discardSession(for: id)
    }

    // MARK: - Vendor fingerprint

    /// The open-time cost: one pass over the first 64 KB. The fixture is a
    /// Huawei config, so the scan really does run every earlier vendor's
    /// signature list over the whole budget before Huawei's `vlan batch` hits —
    /// which is the shape of the worst realistic case.
    func testPerfNetworkFingerprint64k() {
        let text = huaweiConfig(lines: 4_000)
        XCTAssertGreaterThan(text.utf8.count, 64 * 1024)
        PerfHarness.measure("network_fingerprint_64k", samples: 7) {
            let bytes = Array(text.utf8.prefix(VendorFingerprint.budget))
            return VendorFingerprint.detect(inUTF8: bytes).map(\.slot) ?? -1
        }
    }
}
