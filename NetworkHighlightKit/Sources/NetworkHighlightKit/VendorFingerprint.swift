import Foundation

/// Guesses a device family from the CONTENT of a stream or a file.
///
/// Two entry points, one table:
///
/// * `consider(_:)` — the passive one-shot stream fingerprint ported unchanged
///   from SheepTerm. Feed it chunks; it names the vendor exactly once, on the
///   first chunk that completes a signature, then becomes a no-op. If nothing
///   matches inside a 64 KB byte budget it gives up for good, so a session that
///   never shows a banner costs nothing after that. A 64-byte carry bridges a
///   signature split across a chunk boundary.
/// * `detect(in:budget:)` — file mode, added for SheepText. One shot over the
///   first `budget` UTF-8 bytes of a document.
///
/// Both are deliberately conservative, and that is the rule the whole table is
/// written to: **a wrong lock is worse than no lock**, because the user can
/// always pick a family by hand. Signatures are long, specific, lowercased
/// ASCII substrings — `"cisco ios software"`, never bare `"cisco"` — tried in a
/// fixed priority order with the most specific families first, so a Linux jump
/// host that merely prints a vendor's name somewhere cannot outrank that
/// vendor's own banner.
public struct VendorFingerprint: Sendable {
    /// Locked once a signature has matched (holds the vendor) OR the byte
    /// budget ran out with no match. Either way `consider` becomes a no-op.
    public private(set) var locked = false
    /// Total bytes examined so far. Past `budget`, give up: a banner shows up in
    /// the first handful of kilobytes or not at all, and an endless scan of a
    /// `cat bigfile` must not cost anything.
    private var scanned = 0
    public static let budget = 64 * 1024
    /// The tail of the previous chunk, kept so a signature split across a chunk
    /// boundary is still found. 64 bytes comfortably spans the longest
    /// signature.
    private var carry: [UInt8] = []
    private static let carryLen = 64

    public init() {}

    // MARK: - Signature tables

    /// LIVE-SESSION signatures, in PRIORITY order — ported from SheepTerm
    /// unchanged. These are things a device says on a terminal: a login banner,
    /// a `show version` header, a prompt.
    ///
    /// All lowercased ASCII; matching lowercases the stream to compare.
    public static let signatures: [(Vendor, [[UInt8]])] = {
        return [
            // `aos-cx` covers every command that matters: the `show version` /
            // `show system` banner AND the `!Version AOS-CX ...` header that
            // opens `show running-config`, which is what most sessions run.
            // (It is also why the file table below needs no separate
            // `!version aos-cx` entry — that string contains this one.)
            (.arubaCX, bytes(["arubaos-cx", "aos-cx"])),
            (.cisco, bytes(["cisco ios software", "ios-xe", "nx-os", "cisco nexus",
                            "cisco adaptive security"])),
            (.comware, bytes(["comware software", "h3c comware", "hpe comware"])),
            (.huawei, bytes(["huawei versatile routing platform", "vrp (r)",
                             "huawei technologies"])),
            // `aruba operating system`/`arubaos (` catch `show version`;
            // `[mynode]` is the Mobility Master node-path shown in EVERY prompt,
            // so a controller session that never runs show version still locks —
            // and it is durable, unlike a hostname. NOT a hostname such as
            // `arubavmc` (a renamed box would not match), and NOT `*#` (2-3
            // generic chars that appear all over text).
            (.arubaOS, bytes(["aruba operating system", "arubaos (", "[mynode]"])),
            (.juniper, bytes(["junos ", "juniper networks"])),
            (.panos, bytes(["pan-os", "palo alto networks"])),
            // `fortigate`/`fortios ` catch `get system status`; the two
            // `config ...` blocks catch `show` / `show full-configuration` — the
            // command most sessions run. `execute ping`/`execute traceroute`
            // catch the diagnostic the user runs from the box. NOT bare
            // `execute `/`diagnose `: those CLI verbs turn up in other vendors'
            // help text and aliases and mislocked.
            (.fortios, bytes(["fortigate", "fortios ", "config system global",
                              "config firewall policy", "execute ping",
                              "execute traceroute"])),
            // `check point gaia`/`gaia r8` = `show version all` + banner;
            // `set installer policy`/`set clienv` = `show configuration`
            // (clish); `enter expert password` = the prompt when dropping to
            // expert mode. NOT bare `expert` — that word alone shows up in
            // three unrelated captures; the full phrase is Gaia-only.
            (.gaia, bytes(["check point gaia", "gaia r8", "set installer policy",
                           "set clienv", "enter expert password"])),
            (.linux, bytes(["gnu/linux", "ubuntu ", "debian gnu", "centos",
                            "red hat enterprise", "linux version"])),
        ]
    }()

    /// SAVED-CONFIGURATION signatures, added for file mode. A config file
    /// opened in an editor usually carries no banner at all — what it carries is
    /// the vendor's config GRAMMAR, which is every bit as distinctive if the
    /// string chosen is long enough.
    ///
    /// Same rule as above: long and specific, and when two families could print
    /// a string it is left out entirely rather than guessed at. Notable
    /// omissions and why:
    ///
    /// * `building configuration...` — Cisco prints it, but so does an ArubaOS
    ///   controller's `show running-config`. Ambiguous, so it is not here.
    /// * `sysname` — both Huawei VRP and H3C/Comware use it, as they do the `#`
    ///   section separators. The distinguishing tokens are the interface and
    ///   VLAN spellings instead (`eth-trunk`/`vlan batch` vs
    ///   `bridge-aggregation`/`irf member`).
    /// * bare `set hostname` — Gaia clish uses it, but so does a shell script
    ///   and systemd documentation. `set expert-password` is Gaia-only.
    /// * `version 15.` / `version 2` alone — a version number is not a vendor.
    ///   `boot-start-marker` (Cisco IOS) and `routing-options {` (Junos) say the
    ///   same thing without the ambiguity.
    public static let configFileSignatures: [(Vendor, [[UInt8]])] = {
        return [
            // AOS-CX running-config opens `!Version ArubaOS-CX FL.10.13.1000`,
            // already covered by `aos-cx` in the stream table. These two are the
            // AOS-CX-only config statements, for a fragment that starts below
            // the header.
            (.arubaCX, bytes(["ssh server vrf mgmt", "vsx-sync"])),
            // `boot-start-marker`/`boot-end-marker` bracket the boot section of
            // every IOS running-config. `! last configuration change` is the
            // first line IOS writes above `version 15.x`. `current configuration
            // :` is IOS's byte-count header — note the space BEFORE the colon,
            // which is what separates it from AOS-CX's `Current configuration:`.
            (.cisco, bytes(["boot-start-marker", "! last configuration change",
                            "current configuration :",
                            "service timestamps debug datetime"])),
            // Comware-only interface names and its stacking feature. Huawei
            // writes Eth-Trunk, never Bridge-Aggregation.
            (.comware, bytes(["bridge-aggregation", "route-aggregation", "irf member",
                              "irf-port"])),
            // Huawei-only: `vlan batch 10 20 to 30` is VRP syntax nobody else
            // has, `eth-trunk` is its link-aggregation spelling, and
            // `authentication-scheme` opens every VRP AAA block.
            (.huawei, bytes(["vlan batch", "eth-trunk", "authentication-scheme"])),
            // ArubaOS controller/MM config: WLAN and AP grammar no other family
            // uses. `ip access-list session` is ArubaOS's session-ACL keyword.
            (.arubaOS, bytes(["wlan ssid-profile", "wlan virtual-ap", "ap-group ",
                              "ip access-list session"])),
            // Junos in both formats: `## Last commit:` heads a `show
            // configuration`, `routing-options {` is in almost every curly
            // config, and the `set` form is unmistakable (Gaia says
            // `set hostname`, PAN-OS says `set deviceconfig system hostname`).
            (.juniper, bytes(["## last commit:", "routing-options {",
                              "set system host-name", "set routing-options"])),
            // PAN-OS set format and the XML export's root element.
            (.panos, bytes(["set deviceconfig system", "set network interface ethernet",
                            "<deviceconfig>"])),
            // The first line of a FortiOS config backup:
            // `#config-version=FGT60E-6.2.3-FW-build1066-...`. The `config
            // system global` / `config firewall policy` blocks are already in
            // the stream table and serve files too.
            (.fortios, bytes(["#config-version=", "config vdom", "set vdom \"root\""])),
            // Gaia clish `show configuration`. `set expert-password` and
            // `set installer policy` (stream table) are Gaia-only statements;
            // bare `set hostname` is not, so it is left out.
            (.gaia, bytes(["set expert-password", "set inactivity-timeout",
                           "set interface eth0 state"])),
            // Nothing for `linux`: a saved Linux "config" is any text file on
            // the box, and every candidate short enough to be common
            // (`#!/bin/bash`, `/etc/`) matches files that have nothing to do
            // with a network device. Its stream signatures already cover a
            // captured session.
        ]
    }()

    /// The stream table followed, per vendor, by the file table — the order of
    /// vendors is the stream table's, so file mode inherits exactly the same
    /// precedence. Built once.
    public static let fileSignatures: [(Vendor, [[UInt8]])] = {
        let extra = Dictionary(uniqueKeysWithValues: configFileSignatures.map { ($0.0, $0.1) })
        return signatures.map { vendor, patterns in
            (vendor, patterns + (extra[vendor] ?? []))
        }
    }()

    private static func bytes(_ strings: [String]) -> [[UInt8]] {
        strings.map { Array($0.utf8) }
    }

    // MARK: - Stream mode

    /// Feed the next chunk. Returns the detected vendor exactly once, on the
    /// first chunk that completes a signature; nil otherwise (including once
    /// locked or over budget). Cost after a lock is a single branch.
    public mutating func consider(_ bytes: [UInt8]) -> Vendor? {
        guard !locked, scanned < Self.budget, !bytes.isEmpty else { return nil }
        scanned += bytes.count

        // Search over (carry + lowercased(chunk)) so a signature that straddled
        // the previous boundary is seen whole. Non-ASCII bytes are left as-is:
        // they simply never match an ASCII signature.
        var hay = carry
        hay.reserveCapacity(carry.count + bytes.count)
        for b in bytes {
            hay.append((b >= 0x41 && b <= 0x5A) ? b + 0x20 : b)
        }
        // Keep the last bytes as the next carry regardless of outcome.
        if hay.count > Self.carryLen {
            carry = Array(hay[(hay.count - Self.carryLen)...])
        } else {
            carry = hay
        }

        for (vendor, patterns) in Self.signatures {
            for pattern in patterns where Self.contains(hay, pattern) {
                locked = true
                return vendor
            }
        }
        if scanned >= Self.budget { locked = true }   // spent; stop for good
        return nil
    }

    // MARK: - File mode

    /// One-shot fingerprint of a saved configuration. Scans the first `budget`
    /// UTF-8 bytes of `text` against the stream table PLUS the config-file
    /// table, in the same vendor priority order, and returns the first hit.
    ///
    /// `nil` means "no strong signal" — the caller keeps `.auto`, which never
    /// misleads, rather than guessing.
    ///
    /// The budget is a document prefix, not a whole file: the vendor is
    /// announced in the header of a config, and reading 40 MB of a log to look
    /// for one is not a trade worth making. Pass a larger budget explicitly if
    /// the caller knows better.
    public static func detect(in text: String, budget: Int = VendorFingerprint.budget) -> Vendor? {
        var copy = text
        return copy.withUTF8 { buffer in
            detect(inUTF8: buffer, budget: budget)
        }
    }

    /// The buffer form, for a caller that already has UTF-8 bytes.
    public static func detect(
        inUTF8 buffer: UnsafeBufferPointer<UInt8>, budget: Int = VendorFingerprint.budget
    ) -> Vendor? {
        let limit = min(buffer.count, max(0, budget))
        guard limit > 0 else { return nil }
        var hay = [UInt8]()
        hay.reserveCapacity(limit)
        for i in 0..<limit {
            let b = buffer[i]
            hay.append((b >= 0x41 && b <= 0x5A) ? b + 0x20 : b)
        }
        for (vendor, patterns) in fileSignatures {
            for pattern in patterns where contains(hay, pattern) {
                return vendor
            }
        }
        return nil
    }

    public static func detect(inUTF8 bytes: [UInt8], budget: Int = VendorFingerprint.budget) -> Vendor? {
        bytes.withUnsafeBufferPointer { detect(inUTF8: $0, budget: budget) }
    }

    /// Straight substring search — the signatures are short and matches are
    /// rare, so a plain scan beats building any index.
    private static func contains(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, hay.count >= needle.count else { return false }
        let first = needle[0]
        let last = hay.count - needle.count
        var i = 0
        while i <= last {
            if hay[i] == first {
                var j = 1
                while j < needle.count, hay[i + j] == needle[j] { j += 1 }
                if j == needle.count { return true }
            }
            i += 1
        }
        return false
    }
}
