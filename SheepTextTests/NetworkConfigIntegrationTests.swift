//
//  NetworkConfigIntegrationTests.swift
//  The `network_config` language: NetworkHighlightKit's scanner underneath, the
//  editor's per-vendor table on top, one vendor per document.
//
//  What these lock down, in order of how much it would hurt to lose it:
//
//  * The Cisco validators still paint red. `vlan …306s` and `spanning-tree mode
//    rpvsts` are the reason this language exists at all for the person who
//    asked for it, and the package's own VLAN rule would have swallowed both:
//    it spans `vlan` AND the list as one constant. `.cisco` therefore suppresses
//    that rule and keeps the validating layer.
//  * A `.txt` with a vendor banner lights up with no manual step, and a `.txt`
//    without one stays visually plain.
//  * Offsets. The scanner works in UTF-8 bytes and an `NSTextStorage` works in
//    UTF-16; Thai and emoji are where a wrong conversion shows up, and a CRLF
//    file is where line splitting does.
//  * Incremental == clean, per vendor. Both layers are line-local and the
//    engine's reuse path depends on exactly that.
//

import XCTest
import AppKit
import NetworkHighlightKit
@testable import SheepText

@MainActor
final class NetworkConfigIntegrationTests: XCTestCase {

    // MARK: - Helpers

    private func runs(_ text: String, language: String, documentID: UUID? = nil) -> [HighlightRun] {
        SyntaxEngine.shared.runsImmediately(
            text: text, language: language, documentID: documentID
        )?.runs ?? []
    }

    private func style(_ runs: [HighlightRun], at location: Int) -> HighlightStyleID {
        HighlightRunList.style(at: location, in: runs)
    }

    private func style(
        _ runs: [HighlightRun], of token: String, in text: String,
        file: StaticString = #filePath, line: UInt = #line
    ) -> HighlightStyleID {
        let range = (text as NSString).range(of: token)
        guard range.location != NSNotFound else {
            XCTFail("token \(token) not in the fixture", file: file, line: line)
            return HighlightStyleTable.none
        }
        return style(runs, at: range.location)
    }

    private func scope(_ id: HighlightStyleID) -> String {
        guard Int(id) < HighlightStyleTable.styles.count else { return "?" }
        return HighlightStyleTable.styles[Int(id)].scope
    }

    // MARK: - The Cisco validators

    /// The expectations `SyntaxAuditFixTests.testCiscoTokenClassificationIs…`
    /// makes of the old regex highlighter, restated against the run list — and
    /// against the plain `network_config` id with the vendor pinned, not just
    /// against the `cisco_ios` alias.
    func testCiscoValidatorsStillPaintInvalidValuesRed() {
        let source = """
        ! header comment
        \tvlan 1,3,23,101-102,306s
        spanning-tree mode rpvsts
        spanning-tree mode rapid-pvst
        interface GigabitEthernet1/0/24
         switchport mode access
         ip address 10.0.0.1 255.255.255.0

        """
        for language in ["cisco_ios", "network_config:cisco"] {
            let list = runs(source, language: language)
            XCTAssertFalse(list.isEmpty, "\(language) produced no runs")

            let error = HighlightStyleTable.styleID(forCapture: "error")
            let number = HighlightStyleTable.styleID(forCapture: "number")
            let keyword = HighlightStyleTable.styleID(forCapture: "keyword")
            let comment = HighlightStyleTable.styleID(forCapture: "comment")
            let constant = HighlightStyleTable.styleID(forCapture: "constant")

            XCTAssertEqual(style(list, of: "306s", in: source), error, "\(language): 306s")
            XCTAssertEqual(style(list, of: "rpvsts", in: source), error, "\(language): rpvsts")
            XCTAssertEqual(style(list, of: "101-102", in: source), number, "\(language): 101-102")
            XCTAssertEqual(style(list, of: "10.0.0.1", in: source), number, "\(language): address")
            XCTAssertEqual(style(list, of: "rapid-pvst", in: source), constant, "\(language): mode")
            XCTAssertEqual(style(list, of: "! header", in: source), comment, "\(language): comment")
            XCTAssertEqual(style(list, of: "spanning-tree", in: source), keyword, "\(language): cmd")
            XCTAssertEqual(style(list, of: "access", in: source), keyword, "\(language): sub-keyword")
        }
    }

    /// The half the package adds: an interface name is now the thing the line is
    /// about, and it was uncoloured under the old Cisco highlighter.
    func testInterfaceNamesComeFromThePackage() {
        let source = "interface GigabitEthernet1/0/24\n shutdown\n no shutdown\n"
        let list = runs(source, language: "cisco_ios")
        XCTAssertEqual(
            style(list, of: "GigabitEthernet1/0/24", in: source),
            HighlightStyleTable.styleID(forCapture: "type")
        )
        // `shutdown` is bad, `no shutdown` is good — the package's negation rule.
        let bad = style(list, of: " shutdown\n", in: source)
        let ns = source as NSString
        let good = style(list, at: ns.range(of: "no shutdown").location)
        XCTAssertEqual(scope(good), "string")
        XCTAssertNotEqual(good, bad)
    }

    /// Paint order, both directions: a scanner span beats the editor's generic
    /// first-token keyword, and a validator's red beats a scanner span.
    func testScannerBeatsFillAndValidatorsBeatTheScanner() {
        // Huawei keeps the package's VLAN rule, which spans the keyword too.
        let huawei = "vlan batch 10 to 20\n"
        let huaweiRuns = runs(huawei, language: "network_config:huawei")
        XCTAssertEqual(
            style(huaweiRuns, of: "vlan", in: huawei),
            HighlightStyleTable.styleID(forCapture: "constant"),
            "the scanner's vlan span must win over the first-token keyword"
        )

        // Cisco suppresses it and validates instead.
        let cisco = "vlan 10,306s\n"
        let ciscoRuns = runs(cisco, language: "network_config:cisco")
        XCTAssertEqual(
            style(ciscoRuns, of: "vlan", in: cisco),
            HighlightStyleTable.styleID(forCapture: "keyword")
        )
        XCTAssertEqual(
            style(ciscoRuns, of: "306s", in: cisco),
            HighlightStyleTable.styleID(forCapture: "error")
        )
    }

    // MARK: - Vendor fingerprint

    private static let vendorSamples: [(Vendor, String)] = [
        (.cisco, """
        ! Last configuration change at 09:12:44 UTC Mon Sep 1 2026
        version 15.2
        service timestamps debug datetime msec
        boot-start-marker
        boot-end-marker
        hostname CoreSW01
        """),
        (.huawei, """
        #
        sysname CoreSW01
        #
        vlan batch 10 20 to 30
        #
        interface Eth-Trunk1
        """),
        (.arubaCX, """
        !Version ArubaOS-CX FL.10.13.1000
        !export-password: default
        hostname ACCESS-01
        ssh server vrf mgmt
        """),
        (.juniper, """
        ## Last commit: 2026-08-30 11:02:44 UTC by admin
        set system host-name lab-mx
        set routing-options static route 0.0.0.0/0 next-hop 10.0.0.1
        """),
        (.fortios, """
        #config-version=FGT60E-6.2.3-FW-build1066-200409:opmode=0
        config system global
            set hostname "FGT-BRANCH"
        end
        """),
        (.comware, """
        #
         sysname H3C-CORE
        #
        interface Bridge-Aggregation1
         port link-aggregation mode dynamic
        """)
    ]

    func testVendorFingerprintNamesEachFamily() {
        for (expected, sample) in Self.vendorSamples {
            XCTAssertEqual(
                NetworkConfigLanguage.detectVendor(in: sample), expected,
                "fingerprint missed \(expected.badge)"
            )
        }
    }

    func testPlainTextWithNoSignatureStaysOnAuto() {
        let notes = """
        Grocery list
        buy milk bread and eggs
        call the plumber tomorrow
        """
        XCTAssertNil(NetworkConfigLanguage.detectVendor(in: notes))

        let doc = Document(
            url: URL(fileURLWithPath: "/tmp/sheeptext-notes.txt"),
            initialText: notes, encoding: .utf8, hasBOM: false
        )
        XCTAssertEqual(doc.language, NetworkConfigLanguage.id)
        XCTAssertEqual(doc.networkVendor, .auto)
        XCTAssertFalse(doc.networkVendorIsManual)
    }

    /// The promise made about ordinary `.txt` files: on `.auto` nothing but a
    /// literal value is coloured, so prose stays prose.
    func testAutoVendorLeavesProseCompletelyUncoloured() {
        let notes = "Grocery list\nbuy milk bread and eggs\ncall the plumber tomorrow\n"
        XCTAssertTrue(runs(notes, language: "network_config").isEmpty)

        // …and still colours the one thing that is unambiguous anywhere.
        let withAddress = "the switch answers on 10.20.30.40 now\n"
        let list = runs(withAddress, language: "network_config")
        XCTAssertEqual(
            style(list, of: "10.20.30.40", in: withAddress),
            HighlightStyleTable.styleID(forCapture: "number")
        )
        // No first-token keyword, no comment marker: `the` is untouched.
        XCTAssertEqual(style(list, at: 0), HighlightStyleTable.none)
    }

    func testATxtDumpWithAVendorBannerLightsUpWithNoManualStep() {
        for (expected, sample) in Self.vendorSamples {
            let doc = Document(
                url: URL(fileURLWithPath: "/tmp/sheeptext-dump.txt"),
                initialText: sample, encoding: .utf8, hasBOM: false
            )
            XCTAssertEqual(doc.language, NetworkConfigLanguage.id)
            XCTAssertEqual(doc.networkVendor, expected)
            XCTAssertEqual(doc.syntaxLanguage, "network_config:" + expected.rawValue)
        }
    }

    /// The whole open path, not just `Document.init`: a `.txt` dropped on the
    /// app comes up as a Huawei config, and the highlight precomputed for its
    /// first frame is keyed on that vendor.
    func testOpeningATxtDumpEndToEndDetectsTheVendor() throws {
        let sample = Self.vendorSamples.first { $0.0 == .huawei }!.1
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sheeptext-netconf-\(UUID().uuidString).txt")
        try sample.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let store = DocumentStore()
        guard let doc = store.open(url: url, rememberRecent: false, showError: false) else {
            return XCTFail("could not open the fixture")
        }
        XCTAssertEqual(doc.language, NetworkConfigLanguage.id)
        XCTAssertEqual(doc.networkVendor, .huawei)
        XCTAssertEqual(doc.syntaxLanguage, "network_config:huawei")
        XCTAssertTrue(SyntaxEngine.supportsHighlighting(doc.syntaxLanguage))
        // Only precomputed when the "detect syntax by extension" preference is
        // on, which is the default but is a user setting — assert the key, not
        // its presence.
        if let precomputed = doc.precomputedSyntaxHighlight {
            XCTAssertEqual(precomputed.language, "network_config:huawei")
            XCTAssertFalse(precomputed.runs.isEmpty)
        }
        SyntaxEngine.shared.discardSession(for: doc.id)
    }

    func testManualVendorSurvivesADetectAndAutoDetectClearsIt() {
        let doc = Document(
            url: URL(fileURLWithPath: "/tmp/sheeptext-dump.txt"),
            initialText: Self.vendorSamples[0].1, encoding: .utf8, hasBOM: false
        )
        XCTAssertEqual(doc.networkVendor, .cisco)

        doc.networkVendorIsManual = true
        doc.networkVendor = .juniper
        doc.refreshDetectedNetworkVendor()
        XCTAssertEqual(doc.networkVendor, .juniper, "a manual pick must outrank the fingerprint")
        XCTAssertEqual(doc.syntaxLanguage, "network_config:juniper")

        doc.networkVendorIsManual = false
        doc.refreshDetectedNetworkVendor()
        XCTAssertEqual(doc.networkVendor, .cisco)
    }

    // MARK: - Ids, aliases and extensions

    func testAliasIdsResolveToTheirVendor() {
        XCTAssertEqual(NetworkConfigLanguage.vendor(forEngineLanguage: "cisco_ios"), .cisco)
        XCTAssertEqual(NetworkConfigLanguage.vendor(forEngineLanguage: "ios"), .cisco)
        XCTAssertEqual(NetworkConfigLanguage.vendor(forEngineLanguage: "aruba_cx"), .arubaCX)
        XCTAssertEqual(NetworkConfigLanguage.vendor(forEngineLanguage: "aoscx"), .arubaCX)
        XCTAssertEqual(NetworkConfigLanguage.vendor(forEngineLanguage: "network_config"), .auto)
        XCTAssertEqual(
            NetworkConfigLanguage.vendor(forEngineLanguage: "network_config:arubaCX"), .arubaCX
        )
        XCTAssertNil(NetworkConfigLanguage.vendor(forEngineLanguage: "swift"))

        // An alias pins its vendor no matter what the document says.
        XCTAssertEqual(
            NetworkConfigLanguage.engineLanguage(for: "cisco_ios", vendor: .huawei),
            "network_config:cisco"
        )
        XCTAssertEqual(
            NetworkConfigLanguage.engineLanguage(for: "network_config", vendor: .huawei),
            "network_config:huawei"
        )
        XCTAssertEqual(NetworkConfigLanguage.engineLanguage(for: "swift", vendor: .cisco), "swift")

        for id in ["cisco_ios", "aruba_cx", "aoscx", "network_config", "network_config:panos"] {
            XCTAssertTrue(SyntaxEngine.supportsHighlighting(id), id)
        }
    }

    /// A document opened from an old session or draft that still says
    /// `cisco_ios` must come up as a Cisco network config, vendor and all.
    func testALegacyLanguageIdOpensAsAPinnedVendor() {
        let doc = Document(
            url: URL(fileURLWithPath: "/tmp/sheeptext-switch.aoscx"),
            initialText: "interface 1/1/1\n", encoding: .utf8, hasBOM: false
        )
        XCTAssertEqual(doc.language, "aruba_cx")
        XCTAssertEqual(doc.networkVendor, .arubaCX)
        XCTAssertEqual(doc.syntaxLanguage, "network_config:arubaCX")

        doc.language = "cisco_ios"
        XCTAssertEqual(doc.networkVendor, .cisco)
        XCTAssertEqual(doc.syntaxLanguage, "network_config:cisco")
    }

    func testTheFiveExtensionsEnterNetworkConfig() {
        for ext in ["cfg", "ios", "cisco", "conf", "txt"] {
            XCTAssertEqual(
                LanguageDetector.detect(for: URL(fileURLWithPath: "/tmp/file.\(ext)")),
                NetworkConfigLanguage.id, ".\(ext)"
            )
        }
        // Not swept up with them.
        XCTAssertEqual(LanguageDetector.detect(for: URL(fileURLWithPath: "/tmp/a.log")), "log")
        XCTAssertEqual(LanguageDetector.detect(for: URL(fileURLWithPath: "/tmp/a.config")), "log")
        XCTAssertEqual(
            LanguageDetector.detect(for: URL(fileURLWithPath: "/tmp/a.aoscx")), "aruba_cx"
        )
        XCTAssertTrue(
            LanguageDetector.supportedLanguages.contains { $0.id == NetworkConfigLanguage.id }
        )
        XCTAssertEqual(
            LanguageDetector.displayName(for: "cisco_ios"), NetworkConfigLanguage.displayName
        )
    }

    // MARK: - Offsets

    func testUTF8ToUTF16OffsetsAreExactAcrossThaiAndEmoji() {
        let source = """
        interface GigabitEthernet1/0/7
         description แกะน้อย 🐑 uplink ไปยัง core
         ip address 10.20.30.40 255.255.255.0
         mac-address aabb.ccdd.eeff

        """
        let list = runs(source, language: "cisco_ios")
        let ns = source as NSString
        let number = HighlightStyleTable.styleID(forCapture: "number")

        for token in ["10.20.30.40", "255.255.255.0"] {
            let range = ns.range(of: token)
            guard let run = list.first(where: { $0.location == range.location }) else {
                return XCTFail("no run starts at \(token)")
            }
            XCTAssertEqual(run.length, range.length, "\(token) run length")
            XCTAssertEqual(run.style, number, "\(token) style")
            // Nothing painted on the character before or after it.
            XCTAssertEqual(style(list, at: range.location - 1), HighlightStyleTable.none)
        }

        let mac = ns.range(of: "aabb.ccdd.eeff")
        guard let macRun = list.first(where: { $0.location == mac.location }) else {
            return XCTFail("no run starts at the MAC")
        }
        XCTAssertEqual(macRun.length, mac.length)
        XCTAssertEqual(scope(macRun.style), "property")
        XCTAssertNotEqual(macRun.style, number, "a MAC and an address must not share ink")

        // Every run has to land inside the document.
        for run in list { XCTAssertLessThanOrEqual(run.end, ns.length) }
    }

    func testCRLFGivesTheSameRunsPerLineAsItsLFTwin() {
        let lines = [
            "! edge switch",
            "interface GigabitEthernet1/0/1",
            " description แกะ 🐑 uplink",
            " switchport trunk allowed vlan 10,20,30-40,306s",
            " spanning-tree mode rpvsts",
            " ip address 10.0.0.1 255.255.255.0",
            " no shutdown"
        ]
        let lf = lines.joined(separator: "\n") + "\n"
        let crlf = lines.joined(separator: "\r\n") + "\r\n"

        func perLine(_ text: String, terminator: Int) -> [[HighlightRun]] {
            let list = runs(text, language: "cisco_ios")
            var starts: [Int] = []
            var cursor = 0
            for line in lines {
                starts.append(cursor)
                cursor += (line as NSString).length + terminator
            }
            return starts.enumerated().map { index, start in
                let end = index + 1 < starts.count ? starts[index + 1] : cursor
                return list.filter { $0.location >= start && $0.end <= end }
                    .map { HighlightRun(location: $0.location - start, length: $0.length, style: $0.style) }
            }
        }

        let a = perLine(lf, terminator: 1)
        let b = perLine(crlf, terminator: 2)
        XCTAssertFalse(a.flatMap { $0 }.isEmpty)
        for (index, line) in lines.enumerated() {
            XCTAssertEqual(a[index], b[index], "line \(index): \(line)")
        }
    }

    // MARK: - Incremental == clean

    private func vendorCorpus(_ vendor: Vendor) -> [String] {
        var out: [String] = []
        for i in 0..<200 {
            switch vendor {
            case .cisco:
                out.append("interface GigabitEthernet1/0/\(i % 24 + 1)")
                out.append(" switchport trunk allowed vlan 10,20,30-40,\(i % 4000 + 1)")
                out.append(" spanning-tree mode rapid-pvst")
                out.append(" ip address 10.\(i % 250).0.1 255.255.255.0")
                out.append("!")
            case .huawei:
                out.append("interface 10GE1/0/\(i % 24 + 1)")
                out.append(" port trunk allow-pass vlan batch \(i % 4000 + 1) to \(i % 4000 + 3)")
                out.append(" mac-address 00e0-fc12-\(String(format: "%04x", i % 65535))")
                out.append(" undo shutdown")
                out.append("#")
            case .arubaCX:
                out.append("interface 1/1/\(i % 24 + 1)")
                out.append("    vlan trunk allowed 10,20-30")
                out.append("    ip address 10.\(i % 250).0.1/24")
                out.append("    state connected up warning down")
                out.append("! section \(i)")
            case .juniper:
                out.append("set interfaces ge-0/0/\(i % 24) unit 0 family inet address 10.0.\(i % 250).1/24")
                out.append("set protocols lldp interface ge-0/0/\(i % 24)")
                out.append("# comment \(i)")
            default:
                out.append("line \(i) 10.0.0.\(i % 250) up")
            }
        }
        return out
    }

    func testIncrementalMatchesACleanPassForEveryVendor() {
        for vendor in [Vendor.cisco, .huawei, .arubaCX, .juniper, .auto] {
            let language = "network_config:" + vendor.rawValue
            let base = vendorCorpus(vendor).joined(separator: "\n") + "\n"
            let id = UUID()
            defer { SyntaxEngine.shared.discardSession(for: id) }
            _ = runs(base, language: language, documentID: id)

            let ns = NSMutableString(string: base)
            for step in 0..<6 {
                let offset = ns.length / 2 + step * 37
                ns.replaceCharacters(in: NSRange(location: offset, length: 1), with: "x")
                let edited = ns as String
                let incremental = runs(edited, language: language, documentID: id)
                let clean = runs(edited, language: language)
                XCTAssertEqual(
                    incremental, clean,
                    "\(vendor.badge): incremental diverged from a clean pass at step \(step)"
                )
            }
        }
    }

    /// Changing the vendor has to change the picture. It would not if the
    /// vendor were not part of the engine's session key.
    func testChangingVendorRebuildsTheRunList() {
        let source = "vlan batch 10 to 20\n"
        let id = UUID()
        defer { SyntaxEngine.shared.discardSession(for: id) }

        let asCisco = runs(source, language: "network_config:cisco", documentID: id)
        let asHuawei = runs(source, language: "network_config:huawei", documentID: id)
        XCTAssertNotEqual(asCisco, asHuawei)
        XCTAssertEqual(
            style(asHuawei, of: "batch", in: source),
            HighlightStyleTable.styleID(forCapture: "constant")
        )
    }

    // MARK: - Palette

    func testTheStateWordsMapToThreeDistinctColours() {
        // `warning` was not a scope in the table before this language needed it.
        let good = HighlightStyleTable.styleID(forCapture: "string")
        let warn = HighlightStyleTable.styleID(forCapture: "warning")
        let bad = HighlightStyleTable.styleID(forCapture: "error")
        for id in [good, warn, bad] { XCTAssertNotEqual(id, HighlightStyleTable.none) }
        XCTAssertNotEqual(good, warn)
        XCTAssertNotEqual(warn, bad)
        for isDark in [true, false] {
            XCTAssertNotEqual(
                HighlightStyleTable.color(warn, isDark: isDark),
                HighlightStyleTable.color(bad, isDark: isDark)
            )
        }
    }

    func testEveryPackageRuleResolvesToARealStyle() {
        for rule in NetworkRule.allCases {
            guard let token = NetworkConfigHighlighter.ruleTokenNames[rule] else {
                return XCTFail("no capture name for \(rule.rawValue)")
            }
            XCTAssertNotEqual(
                HighlightStyleTable.styleID(forCapture: token), HighlightStyleTable.none,
                "\(rule.rawValue) -> \(token) resolves to no style"
            )
        }
    }

    func testEveryVendorHasAnEditorRuleEntry() {
        for vendor in Vendor.allCases {
            XCTAssertNotNil(
                NetworkConfigVendorRules.table[vendor], "no editor rules for \(vendor.rawValue)"
            )
        }
        XCTAssertFalse(NetworkConfigVendorRules.rules(for: .auto).isActive)
        XCTAssertTrue(NetworkConfigVendorRules.rules(for: .cisco).isActive)
    }
}
