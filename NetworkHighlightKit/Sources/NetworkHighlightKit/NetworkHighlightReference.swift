import Foundation

/// The ORACLE, not the fast path.
///
/// Every rule the byte scanner implements also exists here as the ICU regex it
/// was hand-translated from, generated from the very same keyword arrays the
/// scanner buckets. Nothing in an app should call this: it is 15-20x slower and
/// it backtracks. It exists so the equivalence tests can prove the scanner and
/// the pattern it claims to implement agree, on a corpus and on seeded fuzz, for
/// every vendor — which is the only thing keeping a hand-written matcher honest.
///
/// > Important: the regex path is ASCII-only by contract. ICU's `\b` is
/// > Unicode-aware while the scanner treats every byte >= 0x80 as a word byte
/// > (see `HighlightScanner`), so the two are equivalent on ASCII input and
/// > deliberately are not beyond it. The equivalence tests feed ASCII only; the
/// > non-ASCII rule has its own tests.
public enum NetworkHighlightReference {
    /// One rule as a name and a pattern. Colours live in
    /// `NetworkHighlightDefaults` — the package itself has no opinion about
    /// them.
    public struct RuleConfig: Equatable, Sendable {
        public let rule: NetworkRule
        public let pattern: String
        public let caseInsensitive: Bool

        public var name: String { rule.rawValue }
    }

    /// Order = priority: earlier rules claim their ranges first.
    ///   vlan → interface → cx-port → mask → cidr → ipv4 → mac → ipv6
    ///        → state-good → state-warn → state-bad
    public static func defaultConfigs(for vendor: Vendor) -> [RuleConfig] {
        packs[vendor.rawValue] ?? packs[Vendor.auto.rawValue]!
    }

    /// The catalogue: every rule name, the union vocabulary. Never used to
    /// match anything — it exists so a host app can enumerate all eleven names
    /// whatever pack a document is on.
    public static var canonicalConfigs: [RuleConfig] {
        packs[HighlightScanner.catalogueKey]!
    }

    /// Every `Vendor` must resolve to its OWN profile — a typo in a raw value
    /// would silently fall back to `.auto` and colour, say, a Junos box with
    /// Aruba's cx-port rule. Asserted by the test suite.
    public static func vendorCoverageIsComplete() -> Bool {
        Vendor.allCases.allSatisfy { HighlightScanner.profiles[$0.rawValue] != nil }
    }

    /// Built once per vendor (plus the catalogue).
    private static let packs: [String: [RuleConfig]] = {
        var out: [String: [RuleConfig]] = [:]
        for key in Vendor.allCases.map(\.rawValue) + [HighlightScanner.catalogueKey] {
            out[key] = makeConfigs(HighlightScanner.profile(key))
        }
        return out
    }()

    /// Escapes the two characters an interface prefix may legitimately contain
    /// (`ge-`, `irb.`). Everything else in these lists is [A-Za-z0-9].
    private static func escaped(_ keyword: String) -> String {
        var out = ""
        out.reserveCapacity(keyword.count + 2)
        for ch in keyword {
            if ch == "." || ch == "-" { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// The alternation for a keyword list, IN THE PROFILE'S ORDER.
    ///
    /// This is the load-bearing line of the whole vendor design. The scanner
    /// tries a bucket's keywords in profile order and the regex tries its
    /// alternatives in written order; generating the alternation from the same
    /// already-sorted array is what makes "the longer of a prefix pair must come
    /// first" true by construction rather than by review. Never hand-write a
    /// pattern next to one of these arrays.
    public static func alternation(_ keywords: [String]) -> String {
        keywords.map(escaped).joined(separator: "|")
    }

    private static func makeConfigs(_ p: HighlightScanner.Profile) -> [RuleConfig] {
        func uses(_ rule: NetworkRule) -> Bool {
            p.rules & HighlightScanner.bit(of: rule) != 0
        }
        var out: [RuleConfig] = []

        // Before "interface": "vlan 1,10,225-227" (spaced list) is the vlan
        // keyword; "Vlan10" (attached) stays an interface name.
        if uses(.vlan) {
            let tail = p.vlanRanges
                ? #"(?:[ \t]*[,\-][ \t]*\d{1,4}|[ \t]+(?:to[ \t]+)?\d{1,4})*"#
                : #"(?:[ \t]*[,\-][ \t]*\d{1,4})*"#
            let batch = p.vlanRanges ? #"(?:[ \t]+batch)?"# : ""
            out.append(RuleConfig(
                rule: .vlan,
                pattern: #"\bvlan"# + batch + #"[ \t-]+\d{1,4}"# + tail,
                caseInsensitive: true
            ))
        }
        if uses(.interface) {
            // The digit-led alternative must lead: it can never share a start
            // byte with a keyword, and the scanner tries it first.
            let speed = p.digitSpeedPorts ? #"\d{1,3}GE|"# : ""
            var pattern = ""
            // A profile with digit-led ports but no keywords would emit
            // `(?:\d{1,3}GE|)` — the empty alternative makes the whole thing
            // `\b[ \t]?\d+…`, colouring every bare number, which the scanner
            // would never do. No pack does this today; keep it that way.
            precondition(
                !p.digitSpeedPorts || !p.interfaceKeywords.isEmpty,
                "digitSpeedPorts needs at least one interface keyword"
            )
            if !p.interfaceKeywords.isEmpty {
                // `[ \t]?`, not SheepTerm's `\s?`: a rule that can match across
                // a newline breaks per-line == whole-document scanning, which is
                // what the editor's incremental path rests on.
                pattern = #"\b(?:"# + speed + alternation(p.interfaceKeywords)
                    + #")[ \t]?\d+(?:[\/.:_-]\d+)*\b"#
            }
            // Digit-less names are a separate top-level alternative, always
            // second, so `lo0` still beats a bare `lo`.
            if !p.bareInterfaces.isEmpty {
                if !pattern.isEmpty { pattern += "|" }
                pattern += #"\b(?:"# + alternation(p.bareInterfaces) + #")\b"#
            }
            if !pattern.isEmpty {
                out.append(RuleConfig(rule: .interface, pattern: pattern, caseInsensitive: true))
            }
        }
        if uses(.cxPort) {
            out.append(RuleConfig(
                rule: .cxPort, pattern: #"\b\d{1,2}/\d{1,2}/\d{1,2}(?::\d)?\b"#,
                caseInsensitive: false
            ))
        }
        if uses(.mask) {
            out.append(RuleConfig(
                rule: .mask, pattern: #"\b255(?:\.\d{1,3}){3}\b"#, caseInsensitive: false
            ))
        }
        if uses(.cidr) {
            out.append(RuleConfig(
                rule: .cidr, pattern: #"(?<=[.:]\d{1,3})/\d{1,2}\b"#, caseInsensitive: false
            ))
        }
        // Octets are capped at 255 so "999.999.999.999" no longer matches.
        if uses(.ipv4) {
            out.append(RuleConfig(
                rule: .ipv4,
                pattern: #"\b(?:(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\b"#,
                caseInsensitive: false
            ))
        }
        if uses(.mac) {
            // The dash form of the 4-hex-group alternative would colour any
            // "1234-5678-9012"-shaped token, so only families that print MACs
            // that way carry it.
            let group = p.macDashGroups ? #"[.\-]"# : #"\."#
            // AOS-CX writes the chassis base MAC as two 6-hex groups
            // (3810f0-7ade00). Last alternative, and the scanner tries its
            // branches in this same order.
            let sixHex = p.macSixHexGroups
                ? #"|\b[0-9A-Fa-f]{6}\-[0-9A-Fa-f]{6}\b"#
                : ""
            out.append(RuleConfig(
                rule: .mac,
                pattern: #"\b(?:[0-9A-Fa-f]{4}"# + group + #"){2}[0-9A-Fa-f]{4}\b"#
                    + #"|\b(?:[0-9A-Fa-f]{2}[:\-]){5}[0-9A-Fa-f]{2}\b"# + sixHex,
                caseInsensitive: false
            ))
        }
        // Empty groups allow the compressed "::" form (2001:db8::1). Custom
        // boundaries instead of \b so a leading "::" (e.g. ::1) also matches —
        // ":" is a non-word char, so \b would never fire before it.
        //
        // The leading lookahead is what keeps clocks out of it: that shape on
        // its own also fits `14:37:24`, so every timestamp in `show events` /
        // `show logging` used to be painted address blue.
        if uses(.ipv6) {
            out.append(RuleConfig(
                rule: .ipv6,
                pattern: #"(?<![0-9A-Fa-f:])"#
                    + #"(?=[0-9A-Fa-f:]*::|(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}(?![0-9A-Fa-f:]))"#
                    + #"(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?![0-9A-Fa-f:])"#,
                caseInsensitive: false
            ))
        }
        if uses(.stateGood) {
            // The negation branch leads, matching the scanner.
            let negation = p.negations.isEmpty
                ? ""
                : "(?:" + p.negations.joined(separator: "|") + #")[ \t]+shutdown|"#
            out.append(RuleConfig(
                rule: .stateGood,
                pattern: #"\b(?:"# + negation + alternation(p.stateGoodKeywords) + #")\b"#,
                caseInsensitive: true
            ))
        }
        if uses(.stateWarn) {
            out.append(RuleConfig(
                rule: .stateWarn,
                pattern: #"\b(?:"# + alternation(p.stateWarnKeywords) + #")\b"#,
                caseInsensitive: true
            ))
        }
        if uses(.stateBad) {
            out.append(RuleConfig(
                rule: .stateBad,
                pattern: #"\b(?:"# + alternation(p.stateBadKeywords) + #")\b"#,
                caseInsensitive: true
            ))
        }
        return out
    }

    // MARK: - Reference matching

    /// The spans a vendor's rules claim, computed entirely with ICU regex and
    /// merged with the same priority-claim rule the scanner path uses.
    ///
    /// Offsets are UTF-16, which for the ASCII inputs this is meant for is also
    /// the byte offset. Slow by design; the tests are the only caller.
    public static func referenceSpans(in text: String, vendor: Vendor) -> [NetworkSpan] {
        let configs = defaultConfigs(for: vendor)
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var perRule = [[Range<Int>]](repeating: [], count: 11)
        for config in configs {
            var options: NSRegularExpression.Options = []
            if config.caseInsensitive { options.insert(.caseInsensitive) }
            guard let regex = try? NSRegularExpression(pattern: config.pattern, options: options) else {
                continue
            }
            var matches: [Range<Int>] = []
            regex.enumerateMatches(in: text, range: whole) { match, _, _ in
                guard let r = match?.range, r.length > 0 else { return }
                matches.append(r.location ..< (r.location + r.length))
            }
            perRule[HighlightScanner.ordinal(of: config.rule)] = matches
        }
        return NetworkHighlighter.claim(perRule, rules: configs.map(\.rule))
    }
}
