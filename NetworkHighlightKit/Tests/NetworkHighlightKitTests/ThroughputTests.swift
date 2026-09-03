import Foundation
import XCTest
@testable import NetworkHighlightKit

/// The scanner exists because eleven ICU passes over a multi-megabyte config
/// were too slow to run on a keystroke. This measures that it still is fast, and
/// prints the number so a regression is visible in the log rather than only in a
/// pass/fail.
///
/// Run it in RELEASE (`swift test -c release`) for a number worth quoting —
/// a debug build is bounds-checked and ~5x slower, so the floor is only
/// asserted when optimisations are on.
final class ThroughputTests: XCTestCase {

    /// Cisco-shaped, which is the honest comparison: it exercises the interface
    /// keywords, the address rules, dotted MACs and vlan lists all at once.
    private func makeDump(lines: Int) -> String {
        var s = ""
        s.reserveCapacity(lines * 110)
        for i in 0..<lines {
            s += "interface GigabitEthernet1/0/\(i % 48)\n"
            s += " ip address 10.0.\(i % 255).\(i % 200) 255.255.255.0\n"
            s += " mac-address aabb.ccdd.ee\(String(format: "%02x", i % 256))\n"
            s += " switchport trunk allowed vlan \(i % 4094),\((i + 7) % 4094)\n"
            s += " no shutdown\n"
            if i % 7 == 0 {
                s += "%LINK-3-UPDOWN: Interface Te1/1/\(i % 8), changed state to down\n"
            }
        }
        return s
    }

    private func measureMBs(_ label: String, bytes: Int, _ body: () -> Int) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        let produced = body()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        let mbps = Double(bytes) / elapsed / 1_048_576
        let padded = label.padding(toLength: max(label.count, 34), withPad: " ", startingAt: 0)
        print(String(format: "  %@ %8.3f s  %8.2f MB/s  (%d spans)", padded, elapsed, mbps, produced))
        return mbps
    }

    func testScannerThroughputOnAFourMegabyteDump() throws {
        var dump = makeDump(lines: 26_000)
        while dump.utf8.count < 4 * 1_048_576 { dump += dump.prefix(dump.count / 4) }
        let byteCount = dump.utf8.count
        print("NetworkHighlightKit throughput — dump \(byteCount / 1024) KB")

        let hl = NetworkHighlighter(vendor: .cisco)
        // Warm up: first call pays for the profile's tables and the string's
        // UTF-8 contiguity check.
        _ = hl.spans(in: String(dump.prefix(1000)))

        var mbps = 0.0
        for _ in 0..<3 {
            mbps = max(mbps, measureMBs("scan + UTF-16 mapping", bytes: byteCount) {
                hl.spans(in: dump).count
            })
        }

        // The regex oracle on a slice, for the ratio. A whole 4 MB pass through
        // eleven ICU regexes takes seconds and proves nothing extra.
        let slice = String(dump.prefix(256 * 1024))
        let sliceBytes = slice.utf8.count
        let regexMBs = measureMBs("regex oracle (256 KB slice)", bytes: sliceBytes) {
            NetworkHighlightReference.referenceSpans(in: slice, vendor: .cisco).count
        }
        print(String(format: "  scanner is %.1fx the regex path", mbps / regexMBs))

        #if DEBUG
        // Bounds checks are on; the number is printed but not policed.
        XCTAssertGreaterThan(mbps, 1.0, "even a debug build should clear 1 MB/s")
        #else
        XCTAssertGreaterThan(mbps, 30.0, "release throughput floor")
        #endif
    }

    /// The shape that used to make the regex path hang: near-misses that force
    /// maximal backtracking. The scanner walks forward once, so its time depends
    /// only on the size of the input.
    func testAdversarialInputIsNotSlowerThanOrdinaryText() {
        let hl = NetworkHighlighter(vendor: .cisco)
        let cases = [
            ("ipv6 near-miss", "1:2:3:4:5:6:7:8:9 "),
            ("mac near-miss", "00:11:22:33:44:5g "),
            ("ipv4 near-miss", "999.999.999.9999 "),
            ("interface near-miss", "GigabitEthernet9999999999/ "),
            ("digit run", "9"),
        ]
        for (label, atom) in cases {
            let text = String(repeating: atom, count: 1_048_576 / max(1, atom.utf8.count))
            let bytes = text.utf8.count
            let mbps = measureMBs(label, bytes: bytes) { hl.spans(in: text).count }
            #if !DEBUG
            XCTAssertGreaterThan(mbps, 10.0, "\(label) must not collapse")
            #else
            XCTAssertGreaterThan(mbps, 0.5, label)
            #endif
        }
    }
}
