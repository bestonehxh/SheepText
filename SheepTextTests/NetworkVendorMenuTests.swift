//
//  NetworkVendorMenuTests.swift
//  The status bar lists device families by name, Aruba CX first, and one click
//  on a family sets both the language and the vendor.
//

import XCTest
import NetworkHighlightKit
@testable import SheepText

@MainActor
final class NetworkVendorMenuTests: XCTestCase {

    func testMenuOrderStartsWithArubaCXAndListsEveryFamilyOnce() {
        let order = LanguageDetector.networkVendorMenuOrder
        XCTAssertEqual(order.first, .arubaCX)
        XCTAssertFalse(order.contains(.auto), "Auto is spelled 'Auto-detect' by the menus themselves")
        XCTAssertEqual(Set(order), Set(Vendor.allCases).subtracting([.auto]))
        XCTAssertEqual(order.count, Vendor.allCases.count - 1, "no family listed twice")
    }

    func testNonNetworkLanguagesExcludeOnlyNetworkConfig() {
        let ids = LanguageDetector.nonNetworkLanguages.map(\.id)
        XCTAssertFalse(ids.contains(NetworkConfigLanguage.id))
        XCTAssertEqual(ids.count, LanguageDetector.supportedLanguages.count - 1)
        XCTAssertTrue(ids.contains("swift"))
    }

    private func openTemporary(_ name: String, _ contents: String, in store: DocumentStore) throws -> Document {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vendor-menu-\(UUID().uuidString)-\(name)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try XCTUnwrap(store.open(url: url, rememberRecent: false, showError: false))
    }

    func testPickingAFamilyFromTheLanguageMenuSetsLanguageAndPinsTheVendor() throws {
        let store = DocumentStore()
        let doc = try openTemporary("notes.md", "# heading\n", in: store)
        XCTAssertEqual(doc.language, "markdown")

        store.setNetworkLanguage(doc.id, vendor: .arubaCX)
        XCTAssertEqual(doc.language, NetworkConfigLanguage.id)
        XCTAssertEqual(doc.networkVendor, .arubaCX)
        XCTAssertTrue(doc.networkVendorIsManual)
        XCTAssertEqual(doc.syntaxLanguage, "network_config:arubaCX")
    }

    func testPickingAutoDetectFromTheLanguageMenuFingerprintsTheText() throws {
        let store = DocumentStore()
        let cisco = "! Last configuration change at 10:00\nversion 17.9\nboot-start-marker\nboot-end-marker\n"
        let doc = try openTemporary("dump.log", cisco, in: store)
        XCTAssertEqual(doc.language, "log")

        store.setNetworkLanguage(doc.id, vendor: nil)
        XCTAssertEqual(doc.language, NetworkConfigLanguage.id)
        XCTAssertFalse(doc.networkVendorIsManual)
        XCTAssertEqual(doc.networkVendor, .cisco)

        // And back to a pinned family on a document that is already a network config.
        store.setNetworkLanguage(doc.id, vendor: .huawei)
        XCTAssertEqual(doc.networkVendor, .huawei)
        XCTAssertTrue(doc.networkVendorIsManual)
    }
}
