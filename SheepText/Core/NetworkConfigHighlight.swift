//
//  NetworkConfigHighlight.swift
//  The `network_config` language: one language for every device family, with a
//  vendor picked per document.
//
//  What lives here is the APP's half: the language ids and their aliases, the
//  composite id the syntax engine is asked for, and vendor detection. The
//  highlighting itself — the vendor table, the validators (`vlan 306s`,
//  `spanning-tree mode rpvsts`) and the line walker over NetworkHighlightKit's
//  scanner — is `SheepSyntaxKit/Sources/SheepSyntaxKit/Lexers/NetworkConfigLexer.swift`,
//  so it runs through the same engine, incremental rule and fuzz as every other
//  language. It moved there unchanged; `NetworkParity` in the Linux harness
//  compared the two style for style on every vendor before the old copy was
//  deleted.
//

import Foundation
import NetworkHighlightKit
import SheepSyntaxKit

// MARK: - Language id and vendor plumbing

/// The `network_config` language id, its aliases, and the composite id the
/// syntax engine is actually asked for.
nonisolated enum NetworkConfigLanguage {

    static let id = "network_config"
    static let displayName = "Network Config"

    /// Extensions that open as a network config. `.txt` is in here on purpose:
    /// the configs people actually keep are `.txt` dumps of `show run` /
    /// `display current-configuration`, and one of those must light up with no
    /// manual step. A `.txt` with no vendor signature stays on `.auto`, which
    /// colours only literal values — so ordinary notes stay almost plain.
    static let fileExtensions: Set<String> = ["cfg", "ios", "cisco", "conf", "txt"]

    /// Language ids that mean `network_config` with the vendor already decided.
    /// These are what shipped as separate languages until 1.3.5, so drafts,
    /// sessions and hand-edited preferences still carry them.
    private static let aliases: [String: Vendor] = [
        "cisco_ios": .cisco, "cisco": .cisco, "ios": .cisco,
        "aruba_cx": .arubaCX, "arubacx": .arubaCX, "aoscx": .arubaCX, "cx": .arubaCX
    ]

    /// The vendor an alias id fixes, or nil when the id is not an alias.
    static func aliasVendor(for languageID: String) -> Vendor? {
        aliases[languageID.lowercased()]
    }

    /// The vendor an engine language id resolves to; nil when the id is not a
    /// network config at all.
    ///
    /// Resolved case-INSENSITIVELY throughout. The alias branch always was; the
    /// composite branch was not, and exactly two `Vendor` raw values are
    /// camelCase — `arubaCX` and `arubaOS`. Every language id the app takes
    /// from outside goes through a lowercasing normaliser
    /// (`HighlightOverrides.normalizedLanguage`, `LanguageDetector`), so
    /// `network_config:arubaCX` came back as `network_config:arubacx`,
    /// `Vendor(rawValue:)` returned nil and the `?? .auto` swallowed it: the
    /// document highlighted as `.auto` — literal values only, no comment
    /// character, no interface rule — with no error anywhere. The nine
    /// all-lowercase families survived, which is why it went unnoticed.
    static func vendor(forEngineLanguage languageID: String) -> Vendor? {
        let lowered = languageID.lowercased()
        if let alias = aliases[lowered] { return alias }
        if lowered == id { return .auto }
        guard lowered.hasPrefix(id + ":") else { return nil }
        let raw = String(lowered.dropFirst(id.count + 1))
        return Vendor.allCases.first { $0.rawValue.lowercased() == raw } ?? .auto
    }

    static func isNetworkConfig(_ languageID: String) -> Bool {
        vendor(forEngineLanguage: languageID) != nil
    }

    /// The id to hand the syntax engine for a document.
    ///
    /// The vendor rides in the language string rather than in a parameter
    /// because the language string is ALREADY the cache key everywhere: the
    /// engine's parse session, the editor's shared run cache and
    /// `Document.precomputedSyntaxHighlight` all compare languages before
    /// reusing anything. Switching vendor therefore invalidates every one of
    /// them without a single new field — and a stale run list painted after a
    /// vendor change is exactly the bug that would otherwise be waiting.
    static func engineLanguage(for languageID: String, vendor: Vendor) -> String {
        if let alias = aliasVendor(for: languageID) { return id + ":" + alias.rawValue }
        guard languageID == id else { return languageID }
        return id + ":" + vendor.rawValue
    }

    /// Vendor from the head of a document, or nil for "no strong signal".
    ///
    /// Takes a bounded UTF-8 prefix rather than calling
    /// `VendorFingerprint.detect(in:)`, which starts with `var copy = text;
    /// copy.withUTF8 { … }` and so transcodes the WHOLE string before it ever
    /// looks at the budget. Opening a 40 MB `.txt` would have paid for all of
    /// it, on the main thread, for a 64 KB answer.
    static func detectVendor(in text: String) -> Vendor? {
        let bytes = Array(text.utf8.prefix(VendorFingerprint.budget))
        guard !bytes.isEmpty else { return nil }
        return VendorFingerprint.detect(inUTF8: bytes)
    }
}

// MARK: - The highlighter, now in SheepSyntaxKit

/// The names this file used to define, so the rest of the app (and its tests)
/// keeps reading `NetworkConfigVendorRules.table`, `NetworkConfigHighlighter.isValidVlanItem`…
typealias NetworkConfigHighlighter = SheepSyntaxKit.NetworkConfigHighlighter
typealias NetworkConfigVendorRules = SheepSyntaxKit.NetworkConfigVendorRules
typealias NetworkConfigCommand = SheepSyntaxKit.NetworkConfigCommand
typealias NetworkKeywordSet = SheepSyntaxKit.NetworkKeywordSet
