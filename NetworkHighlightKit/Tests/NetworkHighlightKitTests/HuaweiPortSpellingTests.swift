import XCTest
@testable import NetworkHighlightKit

/// Huawei port spellings that arrived after the SheepTerm 3.0(3) port:
/// multi-rate `MultiGE` / `MTIGE` and the WLAN service/radio interfaces.
final class HuaweiPortSpellingTests: XCTestCase {

    private let huawei = NetworkHighlighter(vendor: .huawei)

    private func interfaceText(in line: String) -> String? {
        let bytes = Array(line.utf8)
        return huawei.scanLine(line).first { $0.rule == .interface }
            .map { String(decoding: bytes[$0.range], as: UTF8.self) }
    }

    func testMultiRatePortsAreInterfaces() {
        XCTAssertEqual(interfaceText(in: "interface MultiGE0/0/1"), "MultiGE0/0/1")
        XCTAssertEqual(interfaceText(in: "interface MultiGE1/0/48"), "MultiGE1/0/48")
        XCTAssertEqual(interfaceText(in: "interface MTIGE0/0/1"), "MTIGE0/0/1")
        XCTAssertEqual(interfaceText(in: " port link-type trunk"), nil)
    }

    func testWlanInterfacesAreInterfaces() {
        XCTAssertEqual(interfaceText(in: "interface Wlan-Ess1"), "Wlan-Ess1")
        XCTAssertEqual(interfaceText(in: "interface Wlan-Ess 0"), "Wlan-Ess 0")
        XCTAssertEqual(interfaceText(in: "interface Wlan-Radio0/0/0"), "Wlan-Radio0/0/0")
    }

    func testExistingSpellingsStillMatchAndLongestWins() {
        XCTAssertEqual(interfaceText(in: "interface XGigabitEthernet0/0/1"), "XGigabitEthernet0/0/1")
        XCTAssertEqual(interfaceText(in: "interface 10GE1/0/1"), "10GE1/0/1")
        XCTAssertEqual(interfaceText(in: "interface GE1/0/1"), "GE1/0/1")
        // `MultiGE` must not be split as `GE` after an unrelated prefix.
        XCTAssertEqual(interfaceText(in: "interface MultiGE0/0/1")?.hasPrefix("Multi"), true)
    }

    func testNotClaimedByVendorsThatDoNotSpellItThatWay() {
        for vendor in [Vendor.cisco, .arubaCX, .auto] {
            let spans = NetworkHighlighter(vendor: vendor).scanLine("interface MultiGE0/0/1")
            XCTAssertFalse(spans.contains { $0.rule == .interface }, "\(vendor)")
        }
    }
}
