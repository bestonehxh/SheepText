//
//  PerfHarnessAudit2SyntaxTests.swift
//  Workloads for the 2026-09-17 audit's syntax findings.
//
//  Everything here goes through `runsImmediately`, which is what the editor
//  calls. The existing `syntax_html_injection_2000_script_*` pair goes through
//  `highlightImmediately`, the compatibility shim that materialises a
//  document-sized `NSAttributedString` — on a 2000-line script that
//  materialisation is most of the number, so it hides the thing the engine
//  actually costs and it hides any change to it. These re-measure the same
//  fixtures without it.
//
//  Every workload compiles against the PRE-fix API, so the orchestrator can run
//  this class on the commit before the fixes and get a like-for-like number.
//
//  A checksum here is `runs.count`. It moves when classification moves — which
//  the network commits do on purpose (more tokens validated) and the perf
//  commits must not.
//

import XCTest
import NetworkHighlightKit
@testable import SheepText

@MainActor
final class PerfHarnessAudit2SyntaxTests: XCTestCase {

    // MARK: - Fixtures

    /// Same generator as `PerfHarnessSyntaxTests.htmlWithScript`, so the two
    /// series are comparable.
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

    private func keystrokeVariants(of base: String, at offset: Int) -> [String] {
        Array("0123456789").map { digit -> String in
            let mutable = NSMutableString(string: base)
            mutable.replaceCharacters(in: NSRange(location: offset, length: 1), with: String(digit))
            return mutable as String
        }
    }

    /// ~20 000 lines of Junos `set` statements. `.juniper` is one of the five
    /// families whose editor table has no commands and no sub-keywords at all,
    /// so every `String` the keyword path used to build for it was built to look
    /// nothing up — this is where SP1's whole win is.
    private func juniperConfig(lines: Int) -> String {
        var out: [String] = []
        out.reserveCapacity(lines)
        for i in 0..<lines {
            switch i % 5 {
            case 0: out.append("set interfaces ge-0/0/\(i % 48) unit 0 description Uplink-\(i)")
            case 1: out.append("set interfaces ge-0/0/\(i % 48) unit 0 family inet address 10.\(i % 250).\(i % 200).1/24")
            case 2: out.append("set protocols lldp interface ge-0/0/\(i % 48)")
            case 3: out.append("set routing-instances VRF-\(i % 32) interface ge-0/0/\(i % 48).0")
            default: out.append("# section \(i)")
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// The same Cisco corpus `PerfHarnessNetworkTests` uses, in CRLF. The line
    /// split is the thing SP2 replaces, and a Windows file is where a line-split
    /// regression shows up first.
    private func ciscoConfig(lines: Int, newline: String) -> String {
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
        return out.joined(separator: newline) + newline
    }

    // MARK: - S2: what an HTML injection keystroke really costs

    func testPerfHTMLInjectionKeystrokeRuns() {
        let base = htmlWithScript(scriptLines: 2000)
        let ns = base as NSString
        let anchor = ns.range(of: "label-01000")
        let offset = anchor.location == NSNotFound ? ns.length / 2 : anchor.location + 6
        let variants = keystrokeVariants(of: base, at: offset)
        let id = UUID()
        _ = SyntaxEngine.shared.runsImmediately(text: base, language: "html", documentID: id)
        var counter = 0
        PerfHarness.measure("syntax_html_injection_2000_keystroke_runs", samples: 7) {
            counter += 1
            return SyntaxEngine.shared.runsImmediately(
                text: variants[counter % variants.count], language: "html", documentID: id
            )?.runs.count ?? -1
        }
        SyntaxEngine.shared.discardSession(for: id)
    }

    func testPerfHTMLInjectionFullRuns() {
        let text = htmlWithScript(scriptLines: 2000)
        PerfHarness.measure("syntax_html_injection_2000_full_runs", samples: 5) {
            SyntaxEngine.shared.runsImmediately(text: text, language: "html")?.runs.count ?? -1
        }
    }

    // MARK: - SP1 / SP2: the network-config pass

    func testPerfNetworkJuniperFull20k() {
        let text = juniperConfig(lines: 20_000)
        PerfHarness.measure("network_juniper_full_20k", samples: 5) {
            SyntaxEngine.shared.runsImmediately(
                text: text, language: "network_config:juniper"
            )?.runs.count ?? -1
        }
    }

    func testPerfNetworkCiscoFull20kCRLF() {
        let text = ciscoConfig(lines: 20_000, newline: "\r\n")
        PerfHarness.measure("network_cisco_full_20k_crlf", samples: 5) {
            SyntaxEngine.shared.runsImmediately(text: text, language: "cisco_ios")?.runs.count ?? -1
        }
    }

    // MARK: - SP3: the synchronous precompute behind a busy queue

    /// `runsImmediately` is a main-actor `queue.sync` onto the one serial syntax
    /// queue every document shares. `DocumentStore.precomputeInitialHighlight`
    /// caps its OWN input at 40k UTF-16 units, but nothing caps the pass it may
    /// be queued behind: a document only escapes the engine at 1 000 000
    /// characters. Opening a small file while a big one's first pass is running
    /// blocked the main thread for that pass.
    ///
    /// The number this prints is the small file's precompute, measured from the
    /// main actor with a large pass already handed to the engine through the
    /// editor's own async entry point — which is exactly the shape of "open a
    /// big file, then open a second one".
    ///
    /// This is the one workload whose CHECKSUM is expected to move with the
    /// fix: giving up on a busy queue means returning nil (`-1` here) instead
    /// of blocking until the answer arrives. That is the behaviour change.
    func testPerfPrecomputeWhileTheQueueIsBusy() {
        var big: [String] = []
        for i in 0..<4_000 {
            big.append("## Section \(i)")
            big.append("Prose with **bold** and `code` and a [link](https://example.com/\(i)).")
            big.append("")
            big.append("```swift")
            big.append("let value\(i) = compute(\(i))")
            big.append("```")
            big.append("")
        }
        let bigText = big.joined(separator: "\n")
        let small = (0..<200).map { "let small\($0) = \($0)" }.joined(separator: "\n") + "\n"
        XCTAssertGreaterThan((bigText as NSString).length, 400_000)

        var busyIDs: [UUID] = []
        PerfHarness.measure("syntax_precompute_while_queue_busy", samples: 5) {
            let busy = UUID()
            busyIDs.append(busy)
            // The editor's own path, so the pass is really on the queue before
            // the next line runs rather than whenever a global queue gets to it.
            SyntaxEngine.shared.highlightRuns(
                text: bigText, language: "markdown", documentID: busy
            ) { _ in }
            return SyntaxEngine.shared.runsImmediately(
                text: small, language: "swift"
            )?.runs.count ?? -1
        }

        // Drain before leaving: the queue is serial and FIFO, so a completion
        // enqueued now fires only after every pass above has finished. Leaving
        // one in flight would make the NEXT test class's `runsImmediately` give
        // up, which is the fix working and would read as a failure.
        let drained = expectation(description: "the syntax queue drains")
        let sentinel = UUID()
        SyntaxEngine.shared.highlightRuns(
            text: "let x = 1\n", language: "swift", documentID: sentinel
        ) { _ in drained.fulfill() }
        wait(for: [drained], timeout: 600)
        for id in busyIDs + [sentinel] { SyntaxEngine.shared.discardSession(for: id) }
    }
}
