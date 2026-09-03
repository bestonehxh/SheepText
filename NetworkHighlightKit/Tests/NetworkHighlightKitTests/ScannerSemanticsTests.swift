import Foundation
import XCTest
@testable import NetworkHighlightKit

/// `ScannerEquivalenceTests` proves the two matching paths AGREE. It cannot
/// prove they agree on the RIGHT answer — an empty pack agrees with itself.
/// These assert the tokens a reader of a config is actually looking at, by rule
/// name and whole token.
final class ScannerSemanticsTests: XCTestCase {

    // MARK: - Coverage and shape

    func testEveryVendorHasItsOwnProfile() {
        // A typo in a raw value would silently fall back to `.auto` and colour,
        // say, a Junos config with Aruba's cx-port rule.
        XCTAssertTrue(NetworkHighlightReference.vendorCoverageIsComplete())
        for vendor in Vendor.allCases {
            XCTAssertNotNil(HighlightScanner.profiles[vendor.rawValue], vendor.rawValue)
        }
    }

    func testVendorSlotsAreDenseAndDistinct() {
        let slots = Vendor.allCases.map(\.slot)
        XCTAssertEqual(Set(slots).count, Vendor.allCases.count, "every slot distinct")
        XCTAssertEqual(slots.min(), 0)
        XCTAssertEqual(slots.max(), Vendor.allCases.count - 1)
    }

    func testUnknownVendorRawValueDecodesAsAuto() throws {
        struct Box: Codable { var vendor: Vendor }
        let data = Data(#"{"vendor":"someFutureSwitch"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(Box.self, from: data).vendor, .auto)
        let ok = Data(#"{"vendor":"arubaCX"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(Box.self, from: ok).vendor, .arubaCX)
    }

    func testCatalogueCarriesEveryRuleName() {
        let catalogue = NetworkHighlightReference.canonicalConfigs
        XCTAssertEqual(catalogue.count, NetworkRule.allCases.count)
        XCTAssertEqual(Set(catalogue.map(\.rule)), Set(NetworkRule.allCases))
    }

    func testEveryRuleHasDefaultPresentation() {
        for rule in NetworkRule.allCases {
            XCTAssertNotNil(NetworkHighlightDefaults.presentation[rule], rule.rawValue)
            XCTAssertNotNil(NetworkHighlightDefaults.suggestedTokenNames[rule], rule.rawValue)
        }
    }

    /// `.auto` is the neutral core, not a union: it never guesses a port name.
    func testAutoOmitsInterfaceAndCXPortButKeepsTheCore() {
        let auto = NetworkHighlighter(vendor: .auto)
        XCTAssertFalse(auto.rules.contains(.interface))
        XCTAssertFalse(auto.rules.contains(.cxPort))
        XCTAssertTrue(auto.rules.contains(.ipv4))
        XCTAssertTrue(auto.rules.contains(.mac))
        XCTAssertTrue(auto.rules.contains(.vlan))
        // and it means it: a Junos port name stays plain rather than being torn
        // in half by cx-port.
        XCTAssertEqual(auto.spans(in: "ge-0/0/0 is up").filter { $0.rule != .stateGood }, [])
    }

    /// Only Aruba CX has `cx-port` — every other pack omits it, which is what
    /// keeps `ge-0/0/0`, `Gi1/0/1` and `100GE1/2/3` whole.
    func testOnlyArubaCXAndArubaOSCarryCXPort() {
        let withCXPort = Vendor.allCases.filter {
            NetworkHighlighter(vendor: $0).rules.contains(.cxPort)
        }
        XCTAssertEqual(Set(withCXPort), [.arubaCX, .arubaOS])
    }

    // MARK: - Priority / claim order

    /// vlan must beat interface, or "interface" claims the `vlan 10` head and
    /// the comma list loses its tail.
    func testVLANOutranksInterface() {
        let text = "vlan 10,20,30-40 allowed"
        assertClaims(.cisco, text, "vlan 10,20,30-40", .vlan)
    }

    /// mac must beat ipv6, or a colon MAC is read as an address.
    func testMACOutranksIPv6() {
        let text = "MAC 00:11:22:33:44:55 seen"
        assertClaims(.auto, text, "00:11:22:33:44:55", .mac)
        assertDoesNotClaim(.auto, text, "00:11:22:33:44:55", [.ipv6])
    }

    /// A prefix length follows an ADDRESS. `Gi1/0/1` is a port, not `/0` `/1`.
    func testCIDRFollowsAnAddressNotAPortNumber() {
        assertClaims(.auto, "route 10.0.0.1/24 via", "/24", .cidr)
        assertClaims(.auto, "route fe80::1/64 via", "/64", .cidr)
        assertDoesNotClaim(.cisco, "interface Gi1/0/1", "/0", [.cidr])
        assertDoesNotClaim(.cisco, "interface Gi1/0/1", "/1", [.cidr])
    }

    /// The claim pass never emits an overlapping or out-of-order span.
    func testClaimedSpansAreSortedAndDisjoint() {
        for vendor in Vendor.allCases {
            let hl = NetworkHighlighter(vendor: vendor)
            for text in neutralCorpus + vendorCorpus {
                var end = 0
                for span in hl.spans(in: text) {
                    XCTAssertGreaterThanOrEqual(span.range.lowerBound, end,
                                                "[\(vendor.rawValue)] \(text.debugDescription)")
                    XCTAssertLessThan(span.range.lowerBound, span.range.upperBound)
                    end = span.range.upperBound
                }
            }
        }
    }

    // MARK: - Aruba CX pack (the tokens it promises to colour)

    func testArubaCXPack() {
        let cx = Vendor.arubaCX
        // show vlan — Reason column
        assertClaims(cx, "1     DEFAULT_VLAN_1  up  ok  default", "ok", .stateGood)
        assertClaims(cx, "100   VLAN100  down  admin_down  static", "admin_down", .stateBad)
        // ...and the bare `down` in the Status column is still its own span, so
        // the admin_down assertion above is not passing by accident.
        assertClaims(cx, "100   VLAN100  down  admin_down  static", "down", .stateBad)

        // show environment
        assertClaims(cx, "Fan 1/1 fan-tray-1 normal", "normal", .stateGood)
        assertClaims(cx, "Power supply PSU1 fault", "fault", .stateBad)
        assertClaims(cx, "PSU2 faulty", "faulty", .stateBad)
        assertClaims(cx, "Status OK", "OK", .stateGood)
        assertClaims(cx, "Status: Normal", "Normal", .stateGood)

        // show events — severity column
        let events = "LOG_WARN LOG_ERR LOG_CRIT LOG_ALERT LOG_EMER LOG_INFO LOG_DEBUG"
        assertClaims(cx, events, "LOG_WARN", .stateWarn)
        assertClaims(cx, events, "LOG_ERR", .stateBad)
        assertClaims(cx, events, "LOG_CRIT", .stateBad)
        assertClaims(cx, events, "LOG_ALERT", .stateBad)
        assertClaims(cx, events, "LOG_EMER", .stateBad)
        // the routine severities stay plain — colouring them is how the column
        // stops meaning anything
        assertDoesNotClaim(cx, events, "LOG_INFO", stateRules)
        assertDoesNotClaim(cx, events, "LOG_DEBUG", stateRules)

        // show system — chassis base MAC, six-dash-six
        assertClaims(cx, "Base MAC Address : 3810f0-7ade00", "3810f0-7ade00", .mac)
        assertClaims(cx, "MAC 38:10:f0:7a:de:00", "38:10:f0:7a:de:00", .mac)
        assertClaims(cx, "MAC 3810.f07a.de00", "3810.f07a.de00", .mac)

        // VSX / NTP sync words — whole token, `sync` inside must not be split off
        assertClaims(cx, "ISL channel : In-Sync", "In-Sync", .stateGood)
        assertClaims(cx, "Config Sync Status : Out-Of-Sync", "Out-Of-Sync", .stateBad)
        let ntp = "NTP Status : Synchronized / Unsynchronized"
        assertClaims(cx, ntp, "Synchronized", .stateGood)
        assertClaims(cx, ntp, "Unsynchronized", .stateBad)

        // ---- negatives: none of this leaks into another family's pack ----
        let base = "Base MAC Address : 3810f0-7ade00"
        for vendor in [Vendor.cisco, .huawei, .auto] {
            assertDoesNotClaim(vendor, base, "3810f0-7ade00", [.mac])
        }
        assertDoesNotClaim(.cisco, events, "LOG_ERR", stateRules)
        assertDoesNotClaim(.cisco, "100 VLAN100 down admin_down static", "admin_down", stateRules)
        assertDoesNotClaim(.cisco, "Config Sync Status : Out-Of-Sync", "Out-Of-Sync", stateRules)
    }

    // MARK: - ipv6 must not colour the clock

    /// "2-7 colons, 0-4 hex per group" is also exactly what a timestamp looks
    /// like. A run is an address only if it is compressed (`::` anywhere) or
    /// written out in full (8 non-empty groups) — a property of the SHARED rule,
    /// so it is asserted per pack.
    func testIPv6IsNotAClock() {
        let cxEvent = "2026-09-02T14:37:24.123456+07:00 CX6300M hpe-portd[2345]:"
            + " Event|401|LOG_INFO|AMM|1/1|Link status for port 1/1/21 is up"
        let ciscoLog = "*Sep  2 14:37:24.123: %LINK-3-UPDOWN: Interface Gi1/0/1, changed state to down"
        let uptime = "Link state: up for 2 weeks (since Wed Aug 19 07:00:00 +07 2026)"
        let runs = "1:2:3 a:b:c:d 12:34:56:78 1:2:3:4:5:6:7: :1:2"
        let notAddresses = [(cxEvent, "14:37:24"), (ciscoLog, "14:37:24"), (uptime, "07:00:00"),
                            (runs, "1:2:3"), (runs, "a:b:c:d"), (runs, "12:34:56:78"),
                            (runs, "1:2:3:4:5:6:7:"), (runs, ":1:2")]
        let addresses = ["2001:db8::1", "::1", "fe80::1", "1::", "::",
                         "2001:0db8:85a3:0000:0000:8a2e:0370:7334", "2001:db8:1:2:3:4:5:6"]

        for vendor in [Vendor.auto, .arubaCX, .cisco] {
            for (text, token) in notAddresses {
                assertDoesNotClaim(vendor, text, token, [.ipv6])
            }
            for address in addresses {
                assertClaims(vendor, "ping \(address) ok", address, .ipv6)
            }
            assertClaims(vendor, "route fe80::1/64 via", "fe80::1", .ipv6)
        }
    }

    // MARK: - Interface names

    func testJunosPortNamesStayWhole() {
        assertClaims(.juniper, "Physical interface: ge-0/0/0, Enabled", "ge-0/0/0", .interface)
        assertClaims(.juniper, "irb.100 is up", "irb.100", .interface)
    }

    func testFortiGatePortIsAnInterfaceAndCiscoPortIsNot() {
        // The whole reason a document needs a vendor: `port1` is mandatory on
        // FortiOS and poison everywhere else, where `port 443` is a service.
        assertClaims(.fortios, "edit port1", "port1", .interface)
        assertDoesNotClaim(.cisco, "service port 443", "port", [.interface])
    }

    func testHuaweiDigitLedSpeedPorts() {
        assertClaims(.huawei, "100GE1/2/3 down down", "100GE1/2/3", .interface)
        assertClaims(.huawei, "10GE1/1/17 up up", "10GE1/1/17", .interface)
        assertClaims(.huawei, "vlan batch 1010 1034 1038 to 1039",
                     "vlan batch 1010 1034 1038 to 1039", .vlan)
    }
}
