//
//  NetworkConfigCfgFallbackTests.swift
//  A `.cfg` / `.ios` / `.cisco` file with no vendor signature opens as Cisco,
//  the way it did when those extensions meant `cisco_ios`. `.conf` and `.txt`
//  still open on `.auto`. A real signature or a manual pick always wins.
//

import XCTest
import NetworkHighlightKit
@testable import SheepText

@MainActor
final class NetworkConfigCfgFallbackTests: XCTestCase {

    /// Interface blocks only: none of the package's Cisco signatures
    /// (`boot-start-marker`, `current configuration :`, `cisco ios software`).
    private let bareCiscoFragment = """
    hostname CORE-SW1
    !
    interface GigabitEthernet1/0/2
     description port 1
     switchport access vlan 11
     spanning-tree portfast
    !
    vlan 10,20,306s
    """

    private func document(_ name: String, _ text: String) -> Document {
        Document(url: URL(fileURLWithPath: "/tmp/\(name)"), initialText: text,
                 encoding: .utf8, hasBOM: false)
    }

    func testFragmentCarriesNoSignature() {
        XCTAssertNil(NetworkConfigLanguage.detectVendor(in: bareCiscoFragment))
    }

    func testCfgIosAndCiscoFallBackToCisco() {
        for ext in ["cfg", "ios", "cisco", "CFG"] {
            let doc = document("switch.\(ext)", bareCiscoFragment)
            XCTAssertEqual(doc.language, NetworkConfigLanguage.id, ext)
            XCTAssertEqual(doc.networkVendor, .cisco, ext)
            XCTAssertFalse(doc.networkVendorIsManual, "fallback is detected, not pinned (\(ext))")
            XCTAssertEqual(doc.syntaxLanguage, "network_config:cisco", ext)
        }
    }

    func testConfAndTxtStayOnAuto() {
        for ext in ["conf", "txt"] {
            XCTAssertEqual(document("switch.\(ext)", bareCiscoFragment).networkVendor, .auto, ext)
        }
    }

    func testARealSignatureBeatsTheFallback() {
        let huawei = "sysname CORE\n#\nvlan batch 10 20\n#\ninterface Eth-Trunk1\n port link-type trunk\n"
        XCTAssertEqual(document("core.cfg", huawei).networkVendor, .huawei)
    }

    func testManualPickBeatsTheFallbackAndAutoDetectRestoresIt() {
        let doc = document("switch.cfg", bareCiscoFragment)
        doc.networkVendorIsManual = true
        doc.networkVendor = .juniper
        doc.refreshDetectedNetworkVendor()
        XCTAssertEqual(doc.networkVendor, .juniper)
        doc.networkVendorIsManual = false
        doc.refreshDetectedNetworkVendor()
        XCTAssertEqual(doc.networkVendor, .cisco)
    }

    func testLeavingNetworkConfigClearsTheFallback() {
        let doc = document("switch.cfg", bareCiscoFragment)
        XCTAssertEqual(doc.networkVendor, .cisco)
        doc.language = "plaintext"
        XCTAssertEqual(doc.networkVendor, .auto)
        doc.language = NetworkConfigLanguage.id
        XCTAssertEqual(doc.networkVendor, .cisco)
    }

    func testTheValidatorsRunOnTheFallenBackDocument() throws {
        let doc = document("switch.cfg", bareCiscoFragment)
        let result = try XCTUnwrap(
            SyntaxEngine.shared.runsImmediately(text: doc.text, language: doc.syntaxLanguage)
        )
        let ns = doc.text as NSString
        let bad = ns.range(of: "306s").location
        let error = HighlightStyleTable.styleID(forCapture: "error")
        XCTAssertEqual(HighlightRunList.style(at: bad, in: result.runs), error,
                       "`306s` must be red on a .cfg with no signature, as it was under cisco_ios")
    }
}
