import Foundation
import XCTest
@testable import NetworkHighlightKit

/// The fingerprint's whole design rests on one asymmetry: a wrong lock is worse
/// than no lock, because the user can always pick a family by hand. So these
/// tests are as much about what must NOT lock as about what must.
final class VendorFingerprintTests: XCTestCase {

    // MARK: - Stream mode (ported from SheepTerm)

    private let banners: [(Vendor, String)] = [
        (.arubaCX, "SW Image ArubaOS-CX Version FL.10.13.1000"),
        (.cisco,   "Cisco IOS Software, C2960X Software (C2960X-UNIVERSALK9-M)"),
        (.comware, "HPE Comware Software, Version 7.1.070"),
        (.huawei,  "Huawei Versatile Routing Platform Software"),
        (.arubaOS, "ArubaOS (MODEL: 7210), Version 8.6.0.0"),
        (.juniper, "JUNOS 21.4R3-S4 built 2023-01-01"),
        (.panos,   "PAN-OS 10.2.3 on PA-440"),
        (.fortios, "FortiGate-100F v7.2.5,build1517"),
        (.gaia,    "This is Check Point Gaia R81.10"),
        (.linux,   "Linux version 5.15.0-91-generic (buildd@lcy02)"),
    ]

    func testEachFamilyLocksOnItsOwnBanner() {
        for (vendor, banner) in banners {
            let bytes = Array(banner.utf8)
            var whole = VendorFingerprint()
            XCTAssertEqual(whole.consider(bytes), vendor, "\(vendor.rawValue) (whole chunk)")

            // Fed one byte at a time, the carry has to bridge every internal
            // boundary.
            var byByte = VendorFingerprint()
            var locked: Vendor?
            for b in bytes where locked == nil { locked = byByte.consider([b]) }
            XCTAssertEqual(locked, vendor, "\(vendor.rawValue) (byte at a time)")
        }
    }

    func testSignatureStraddlingAChunkBoundaryIsStillFound() {
        let split = Array("Cisco IOS Software".utf8)
        var fp = VendorFingerprint()
        XCTAssertNil(fp.consider(Array(split[..<5])), "no lock on the first half ('Cisco')")
        XCTAssertEqual(fp.consider(Array(split[5...])), .cisco, "lock once the boundary is bridged")
    }

    func testBareVendorNameNeverLocks() {
        // The rule the table is written to. `cisco` on its own turns up in a
        // hostname, a comment, an interface description, someone's notes.
        for text in ["cisco", "Cisco", "hostname cisco-sw1", "! aruba here",
                     "juniper", "# huawei rack 3", "description link to fortigate-b"] {
            var fp = VendorFingerprint()
            let locked = fp.consider(Array(text.utf8))
            if text.lowercased().contains("fortigate") {
                // `fortigate` IS a signature — it is a product name, not a
                // company name, and it does not appear in other vendors' text.
                XCTAssertEqual(locked, .fortios, text)
            } else {
                XCTAssertNil(locked, "\(text.debugDescription) must not lock")
            }
        }
    }

    func testBannerlessOutputDoesNotLockAndStaysArmed() {
        var fp = VendorFingerprint()
        XCTAssertNil(fp.consider(Array("show running-config\r\nhostname sw1\r\n!\r\n".utf8)))
        XCTAssertFalse(fp.locked, "the detector is still armed")
    }

    func testBudgetExhaustionIsPermanent() {
        var fp = VendorFingerprint()
        XCTAssertNil(fp.consider([UInt8](repeating: 0x2E, count: VendorFingerprint.budget)),
                     "no lock on 64 KB of signature-free filler")
        XCTAssertTrue(fp.locked, "over-budget detector is spent")
        XCTAssertNil(fp.consider(Array("Cisco IOS Software".utf8)),
                     "and a later banner is ignored once spent")
    }

    func testOneShot() {
        var fp = VendorFingerprint()
        XCTAssertEqual(fp.consider(Array("Cisco IOS Software".utf8)), .cisco)
        XCTAssertNil(fp.consider(Array("Cisco IOS Software".utf8)), "spent after the first lock")
        XCTAssertTrue(fp.locked)
    }

    // MARK: - File mode

    /// Realistic first lines of each family's saved configuration. This is the
    /// case SheepText has and SheepTerm does not: a config on disk with no
    /// banner in it at all.
    func testSavedConfigurationsAreRecognised() {
        let configs: [(Vendor, String)] = [
            (.arubaCX, """
            Current configuration:
            !
            !Version ArubaOS-CX FL.10.13.1000
            !export-password: default
            hostname CX6300M
            """),
            (.arubaCX, """
            hostname CX6300M
            ssh server vrf mgmt
            vlan 1
            """),
            (.cisco, """
            ! Last configuration change at 09:12:03 ICT Tue Sep 2 2026 by admin
            !
            version 15.2
            service timestamps debug datetime msec
            no service password-encryption
            !
            hostname SW1
            !
            boot-start-marker
            boot-end-marker
            """),
            (.cisco, """
            Current configuration : 8102 bytes
            !
            hostname SW1
            """),
            (.juniper, """
            ## Last commit: 2026-09-02 09:12:03 ICT by admin
            version 21.4R3-S4;
            system {
                host-name mx-edge-1;
            }
            """),
            (.juniper, """
            set system host-name mx-edge-1
            set interfaces ge-0/0/0 unit 0 family inet address 10.1.1.1/24
            """),
            (.huawei, """
            #
            sysname SW-CORE
            #
            vlan batch 10 20 30 to 40
            #
            interface Eth-Trunk1
            #
            return
            """),
            (.comware, """
            #
             version 7.1.070, Release 6127P02
            #
             sysname H3C-SW1
            #
            interface Bridge-Aggregation1
            #
            return
            """),
            (.fortios, """
            #config-version=FGT60E-7.2.5-FW-build1517-230606:opmode=0:vdom=0
            config system global
                set hostname "FGT-EDGE"
            end
            """),
            (.panos, """
            set deviceconfig system hostname PA-440-EDGE
            set network interface ethernet ethernet1/1 layer3 ip 10.0.0.1/24
            """),
            (.gaia, """
            set hostname gw-cluster-a
            set expert-password-hash *
            set interface eth0 state on
            """),
            (.arubaOS, """
            version 8.6.0.0
            wlan ssid-profile "corp"
               essid "CorpNet"
            ap-group "default"
            """),
        ]
        for (vendor, config) in configs {
            XCTAssertEqual(VendorFingerprint.detect(in: config), vendor,
                           "\(vendor.rawValue): \(config.prefix(48))…")
        }
    }

    func testFileModeDoesNotLockOnBareVendorNames() {
        // Ordinary editor content that mentions a vendor. Nothing here is a
        // config grammar, so nothing may lock.
        for text in [
            "# TODO: ask cisco support about the licence",
            "The aruba switch in rack 3 needs a reboot.",
            "hostname juniper-lab",
            "192.168.1.1 is the gateway\n255.255.255.0\n",
            "",
            "interface Gi1/0/1\n switchport mode access\n",   // Cisco-SHAPED but not conclusive
        ] {
            XCTAssertNil(VendorFingerprint.detect(in: text),
                         "\(text.prefix(40).debugDescription) must not lock")
        }
    }

    func testFileModeRespectsTheBudget() {
        let filler = String(repeating: "-", count: 4096)
        let text = filler + "\nboot-start-marker\n"
        // Enough budget to reach the signature.
        XCTAssertEqual(VendorFingerprint.detect(in: text), .cisco)
        // Not enough: the answer is "unknown", not a guess.
        XCTAssertNil(VendorFingerprint.detect(in: text, budget: 100))
        XCTAssertNil(VendorFingerprint.detect(in: text, budget: 0))
    }

    /// The budget cuts at a BYTE offset, so it can land in the middle of a
    /// signature — and must then simply not match rather than half-match.
    func testFileModeBudgetCuttingThroughASignature() {
        let text = "boot-start-marker\n"
        XCTAssertEqual(VendorFingerprint.detect(in: text, budget: text.utf8.count), .cisco)
        for cut in 1..<"boot-start-marker".utf8.count {
            XCTAssertNil(VendorFingerprint.detect(in: text, budget: cut), "cut at \(cut)")
        }
    }

    func testFileModeHandlesNonASCIIWithoutMisreading() {
        // A Thai description above the header must not shift or break the
        // search; the budget counts BYTES, and a signature after multi-byte
        // text is still found.
        let text = "! ห้องเซิร์ฟเวอร์ ชั้น 3 🐑\n! Last configuration change at 09:12\nhostname SW1"
        XCTAssertEqual(VendorFingerprint.detect(in: text), .cisco)
        XCTAssertNil(VendorFingerprint.detect(in: "ห้องเซิร์ฟเวอร์ 🐑 สวัสดี"))
    }

    func testFileModeInheritsStreamPrecedence() {
        // An AOS-CX config that also happens to contain a Cisco-ish phrase:
        // arubaCX is first in the table, so it wins.
        let text = """
        !Version ArubaOS-CX FL.10.13.1000
        ! Last configuration change at 09:12
        """
        XCTAssertEqual(VendorFingerprint.detect(in: text), .arubaCX)
    }

    func testEveryConfigFileSignatureBelongsToAKnownVendor() {
        let fileVendors = Set(VendorFingerprint.configFileSignatures.map(\.0))
        XCTAssertTrue(fileVendors.isSubset(of: Set(Vendor.allCases)))
        // Merging must not drop or duplicate a vendor.
        XCTAssertEqual(VendorFingerprint.fileSignatures.map(\.0),
                       VendorFingerprint.signatures.map(\.0))
        for (i, entry) in VendorFingerprint.fileSignatures.enumerated() {
            XCTAssertGreaterThanOrEqual(entry.1.count, VendorFingerprint.signatures[i].1.count)
        }
        // Every signature is lowercase ASCII — the matcher lowercases only
        // A-Z, so an uppercase byte in the table could never match.
        for (_, patterns) in VendorFingerprint.fileSignatures {
            for pattern in patterns {
                XCTAssertFalse(pattern.contains { $0 >= 0x41 && $0 <= 0x5A },
                               String(decoding: pattern, as: UTF8.self))
                XCTAssertFalse(pattern.contains { $0 >= 0x80 },
                               String(decoding: pattern, as: UTF8.self))
                XCTAssertGreaterThanOrEqual(pattern.count, 5, "signatures must be long")
            }
        }
    }
}
