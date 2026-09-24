//
//  NetworkConfigHighlight.swift
//  The `network_config` language: one language for every device family, with a
//  vendor picked per document.
//
//  Two layers, and the split is the whole design:
//
//  1. **The package** (`NetworkHighlightKit`) claims the LITERAL VALUES — IPv4
//     and IPv6 addresses, netmasks, prefix lengths, MACs, VLAN ids, interface
//     names and the state words that carry a verdict. It is a byte scanner with
//     no AppKit dependency, shared with SheepTerm, and it knows eleven device
//     families. It never guesses: `.auto` carries no interface rule at all,
//     because an interface name is the most vendor-specific token there is.
//  2. **This file** adds what an EDITOR knows and a terminal does not: which
//     character opens a comment, that the first token of a line is the command,
//     which words are sub-keywords, and — for Cisco — that `vlan 306s` and
//     `spanning-tree mode rpvsts` are not merely uncoloured but WRONG.
//
//  Paint order is fill → scanner → override, so a scanner span wins over the
//  editor's generic guesses (a first-token keyword, a bare integer) while a
//  comment line and a validator's red both win over the scanner. Nothing else
//  needs to know the priority: `HighlightRunPainter` is last-paint-wins.
//
//  The vendor rules are a TABLE. Adding a device family's comment character or
//  a new validated command is a data change here, not a new branch in a
//  highlighter.
//

import Foundation
import NetworkHighlightKit

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

// MARK: - The per-vendor editor table

/// What one command's arguments mean. Data, not code: a new validated command
/// is one dictionary entry.
nonisolated struct NetworkConfigCommand: Sendable {

    enum Argument: Sendable {
        /// A comma-separated VLAN list — each item is `1…4094` or `a-b` with
        /// both ends in range and `a <= b`. Anything else is an ERROR, not an
        /// unknown token: `vlan 306s` is a typo a config review has to catch.
        ///
        /// It is only read as a list when it BEGINS WITH A DIGIT. `vlan` is not
        /// one command in IOS: `vlan internal allocation policy ascending`
        /// (emitted by default on most Catalyst platforms), `vlan dot1q tag
        /// native` and `vlan database` share the word and mean something else
        /// entirely, and painting their second token red said a correct config
        /// was broken. A false red is worse than a missed one — it teaches the
        /// reader to stop trusting the colour.
        case vlanList
        /// A closed set: a member takes the constant colour, anything else is
        /// an error (`spanning-tree mode rpvsts`).
        case oneOf(Set<String>)
    }

    /// What the token immediately after the command — or after the last
    /// sub-command matched — means.
    let argument: Argument?
    /// Sub-commands keyed by the next token (`spanning-tree` → `mode`,
    /// `vlan` → `configuration`). The walker descends this tree as far as it
    /// goes, so a three-word command is three table entries and no new code.
    let subCommands: [String: NetworkConfigCommand]

    init(argument: Argument? = nil, subCommands: [String: NetworkConfigCommand] = [:]) {
        self.argument = argument
        self.subCommands = subCommands
    }
}

/// A small set of short lowercase-ASCII keywords, matched against a
/// `CFStringInlineBuffer` without building a `String`.
///
/// The tail of `highlightLine` asks this question for EVERY token in the
/// document — on the order of 440 000 of them in a 20 000-line config — and the
/// answer used to cost an `NSString.substring` plus a `.lowercased()` plus the
/// ARC pair for both. Measured by the auditor: 9.06 ms for the substring path
/// against 0.77 ms for the tokenise alone, on every full pass and every first
/// open.
///
/// Keywords are bucketed by length, so a token of the wrong length exits before
/// any comparison at all; a unit above 0x7F can never equal an ASCII keyword
/// byte, so a Thai or CJK token exits on its first unit.
nonisolated struct NetworkKeywordSet: Sendable {

    /// `byLength[n]` holds every keyword of length `n`, as lowercase ASCII.
    /// Index 0 is always empty. There are never more than a handful per bucket.
    private let byLength: [[[UInt8]]]
    let isEmpty: Bool

    init(_ words: Set<String>) {
        isEmpty = words.isEmpty
        let longest = words.map(\.utf8.count).max() ?? 0
        var buckets = [[[UInt8]]](repeating: [], count: longest + 1)
        for word in words {
            let units = Array(word.lowercased().utf8)
            // A keyword the table spelled with a non-ASCII character could
            // never be matched here, and silently never matching is how a rule
            // disappears. There is no such keyword today.
            guard !units.contains(where: { $0 >= 0x80 }) else { continue }
            buckets[units.count].append(units)
        }
        byLength = buckets
    }

    func contains(_ buffer: inout CFStringInlineBuffer, _ range: NSRange) -> Bool {
        guard range.length > 0, range.length < byLength.count else { return false }
        let candidates = byLength[range.length]
        guard !candidates.isEmpty else { return false }
        for word in candidates {
            var matched = true
            for offset in 0..<range.length {
                var unit = CFStringGetCharacterFromInlineBuffer(&buffer, range.location + offset)
                if unit >= 0x41, unit <= 0x5A { unit += 0x20 }
                if unit != UniChar(word[offset]) { matched = false; break }
            }
            if matched { return true }
        }
        return false
    }
}

/// Everything the editor layer knows about one device family.
nonisolated struct NetworkConfigVendorRules: Sendable {

    /// UTF-16 units that open a whole-line comment when one is the first
    /// non-blank character on the line. Empty = this family has none here.
    let commentMarkers: [UniChar]
    /// Paint the first token of every line as the command keyword.
    let firstTokenIsKeyword: Bool
    /// Paint a token made only of digits, `.` and `:` as a number. The package
    /// already claims addresses; this catches the bare `100` in
    /// `spanning-tree vlan 10 priority 100`.
    let paintsPlainNumbers: Bool
    let subKeywords: Set<String>
    let commands: [String: NetworkConfigCommand]
    /// Words after which a digit-leading token is a VLAN list, wherever on the
    /// line they appear.
    ///
    /// A VLAN list is named by the word in FRONT of it far more often than by
    /// its position in a command: `switchport trunk allowed vlan 10,20`,
    /// `switchport access vlan 100`, `no vlan 10`, `spanning-tree vlan 1-10
    /// priority 24576` and `vlan filter MAP1 vlan-list 10-20` are all the same
    /// shape and none of them starts with the command `vlan`. Keying on the
    /// introducing word reaches every one of them with a single table row —
    /// before this, `switchport trunk allowed vlan 10,20,306s` got no
    /// validation at all, which is the line a switch config has most of.
    ///
    /// `interface Vlan10` is deliberately NOT reached: the introducer has to be
    /// a token of its own, and `Vlan10` is an interface name the package
    /// already claims.
    let vlanListIntroducers: Set<String>
    /// Words that CONTINUE a list one of the above already opened, and mean
    /// nothing on their own.
    ///
    /// `add`, `remove` and `except` finish `switchport trunk allowed vlan add
    /// 10,20` — and they are also ordinary English and ordinary CLI. Treated as
    /// introducers in their own right they reddened numbers that are not VLAN
    /// ids at all: `description add 5000 ports to po1`, `remark remove 9999
    /// later`, `ip sla schedule 5 life forever except 70000`. They only arm
    /// after a `vlan` / `vlan-list` token has appeared earlier on the SAME line.
    let vlanListContinuations: Set<String>
    /// Commands after which the rest of the line is PROSE.
    ///
    /// `description`, `remark`, `banner …`, a vlan's `name`, `alias`,
    /// `snmp-server location|contact` — everything after one of these is what a
    /// person typed, not CLI. The editor layer claims nothing there: no list
    /// validation, no sub-keyword, no bare integer. `description spare port 24`
    /// used to come out with `24` in number-orange and `description add 4095
    /// trunk` with `4095` in error-red.
    ///
    /// The package's scanner is a separate layer and still runs, which is what
    /// keeps the address in `description uplink to 10.0.0.1` coloured. Free text
    /// can only REMOVE editor paint, never add it, so an entry here can be
    /// wrong only in the harmless direction.
    let freeTextCommands: Set<String>
    /// Package rules this family's editor layer replaces.
    ///
    /// Cisco suppresses `vlan` because the scanner's VLAN rule spans the
    /// `vlan` keyword AND its list as one constant-coloured span, which would
    /// bury both the command keyword and the per-item validation above. Every
    /// other family keeps it — none of them validates the list.
    let suppressedScannerRules: Set<NetworkRule>

    /// The two per-token sets, in the form the line walker asks them in. The
    /// `Set<String>`s above stay because they are how the table READS; these
    /// are how it is matched.
    let subKeywordMatcher: NetworkKeywordSet
    let vlanListIntroducerMatcher: NetworkKeywordSet
    let vlanListContinuationMatcher: NetworkKeywordSet
    let freeTextMatcher: NetworkKeywordSet
    /// Exactly the keys of `commands`, so the first token of a line only pays
    /// for a `String` on the lines that really do open a command — one line in
    /// six of a Cisco config rather than all of them.
    let commandMatcher: NetworkKeywordSet

    init(
        commentMarkers: [UniChar],
        firstTokenIsKeyword: Bool,
        paintsPlainNumbers: Bool,
        subKeywords: Set<String>,
        commands: [String: NetworkConfigCommand],
        vlanListIntroducers: Set<String>,
        vlanListContinuations: Set<String>,
        freeTextCommands: Set<String>,
        suppressedScannerRules: Set<NetworkRule>
    ) {
        self.commentMarkers = commentMarkers
        self.firstTokenIsKeyword = firstTokenIsKeyword
        self.paintsPlainNumbers = paintsPlainNumbers
        self.subKeywords = subKeywords
        self.commands = commands
        self.vlanListIntroducers = vlanListIntroducers
        self.vlanListContinuations = vlanListContinuations
        self.freeTextCommands = freeTextCommands
        self.suppressedScannerRules = suppressedScannerRules
        self.subKeywordMatcher = NetworkKeywordSet(subKeywords)
        self.vlanListIntroducerMatcher = NetworkKeywordSet(vlanListIntroducers)
        self.vlanListContinuationMatcher = NetworkKeywordSet(vlanListContinuations)
        self.freeTextMatcher = NetworkKeywordSet(freeTextCommands)
        self.commandMatcher = NetworkKeywordSet(Set(commands.keys))
    }

    var isActive: Bool {
        firstTokenIsKeyword || paintsPlainNumbers
            || !commentMarkers.isEmpty || !commands.isEmpty || !subKeywords.isEmpty
            || !vlanListIntroducers.isEmpty
    }

    static func rules(for vendor: Vendor) -> NetworkConfigVendorRules {
        table[vendor] ?? neutral
    }

    // MARK: Shared pieces

    private static let bang: [UniChar] = [0x21]   // !
    private static let hash: [UniChar] = [0x23]   // #

    /// The words a switch config uses as the second half of a command. Shared
    /// by the families that speak switchport-shaped CLI.
    private static let switchSubKeywords: Set<String> = [
        "mode", "access", "trunk", "native", "allowed", "encapsulation",
        "dot1q", "add", "remove", "except", "all", "none"
    ]

    private static let spanningTreeModes: Set<String> = [
        "pvst", "rapid-pvst", "mst", "rstp", "rpvst"
    ]

    /// Cisco also knows two words that introduce a list, so they are keywords.
    private static let ciscoSubKeywords: Set<String> =
        switchSubKeywords.union(["vlan", "vlan-list"])

    /// `banner` covers `banner motd`/`banner login`/…; `location` and `contact`
    /// are the tails of `snmp-server location|contact` and are listed on their
    /// own because the walker matches one token. A bare `location` elsewhere
    /// would only suppress paint, which is the safe direction.
    private static let ciscoFreeTextCommands: Set<String> = [
        "description", "remark", "banner", "name", "alias", "location", "contact"
    ]

    /// The second word of every `vlan …` global that is NOT a VLAN list.
    ///
    /// They are here to be painted as the keywords they are; the validator is
    /// already kept off them by `.vlanList`'s digit rule, so a form nobody
    /// thought of (`vlan mapping …`) is left alone rather than reddened. Only
    /// `configuration` carries a list of its own.
    private static let ciscoVlanSubCommands: [String: NetworkConfigCommand] = [
        "internal": NetworkConfigCommand(),
        "dot1q": NetworkConfigCommand(),
        "database": NetworkConfigCommand(),
        "accounting": NetworkConfigCommand(),
        "name": NetworkConfigCommand(),
        "access-map": NetworkConfigCommand(),
        "filter": NetworkConfigCommand(),
        "group": NetworkConfigCommand(),
        "configuration": NetworkConfigCommand(argument: .vlanList)
    ]

    private static let ciscoCommands: [String: NetworkConfigCommand] = [
        // No argument on `vlan` itself: `vlan` is also its own list introducer,
        // so `vlan 10,20` is validated by the same rule that validates
        // `switchport access vlan 10` — one mechanism, not two.
        "vlan": NetworkConfigCommand(subCommands: ciscoVlanSubCommands),
        "spanning-tree": NetworkConfigCommand(subCommands: [
            "mode": NetworkConfigCommand(argument: .oneOf(spanningTreeModes))
        ])
    ]

    /// `.auto`'s table, and the fallback for anything unknown. Deliberately
    /// empty: with no vendor there is no comment character to be sure of, no
    /// command grammar and no keyword list, so the package's literal values are
    /// the only honest thing to colour.
    static let neutral = NetworkConfigVendorRules(
        commentMarkers: [], firstTokenIsKeyword: false, paintsPlainNumbers: false,
        subKeywords: [], commands: [:], vlanListIntroducers: [], vlanListContinuations: [],
        freeTextCommands: [], suppressedScannerRules: []
    )

    /// Every family that speaks a CLI has a `description`, and what follows one
    /// is a person's sentence. Cisco adds the rest below.
    private static let commonFreeTextCommands: Set<String> = ["description"]

    private static func standard(
        comment: [UniChar],
        subKeywords: Set<String> = [],
        commands: [String: NetworkConfigCommand] = [:],
        vlanListIntroducers: Set<String> = [],
        vlanListContinuations: Set<String> = [],
        freeTextCommands: Set<String> = commonFreeTextCommands,
        suppressing: Set<NetworkRule> = []
    ) -> NetworkConfigVendorRules {
        NetworkConfigVendorRules(
            commentMarkers: comment,
            firstTokenIsKeyword: true,
            paintsPlainNumbers: true,
            subKeywords: subKeywords,
            commands: commands,
            vlanListIntroducers: vlanListIntroducers,
            vlanListContinuations: vlanListContinuations,
            freeTextCommands: freeTextCommands,
            suppressedScannerRules: suppressing
        )
    }

    static let table: [Vendor: NetworkConfigVendorRules] = [
        .auto: neutral,
        // `vlan` and `vlan-list` open a list; `add`/`remove`/`except` only
        // CONTINUE one (`switchport trunk allowed vlan add 10,20`) because on
        // their own they are ordinary words. `all` and `none` take no list.
        .cisco: standard(comment: bang, subKeywords: ciscoSubKeywords,
                         commands: ciscoCommands,
                         vlanListIntroducers: ["vlan", "vlan-list"],
                         vlanListContinuations: ["add", "remove", "except"],
                         freeTextCommands: ciscoFreeTextCommands,
                         suppressing: [.vlan]),
        .arubaCX: standard(comment: bang, subKeywords: switchSubKeywords),
        .arubaOS: standard(comment: bang, subKeywords: switchSubKeywords),
        .huawei: standard(comment: hash, subKeywords: switchSubKeywords),
        .comware: standard(comment: hash, subKeywords: switchSubKeywords),
        .juniper: standard(comment: hash),
        .panos: standard(comment: hash),
        .fortios: standard(comment: hash),
        .gaia: standard(comment: hash),
        .linux: standard(comment: hash)
    ]
}

// MARK: - The pass

nonisolated enum NetworkConfigHighlighter {

    /// One highlighter per vendor, built once. A `NetworkHighlighter` holds a
    /// shared `Profile` reference and two small derived values, so eleven of
    /// them cost nothing and none of them is ever built on a keystroke.
    private static let highlighters: [Vendor: NetworkHighlighter] =
        Dictionary(uniqueKeysWithValues: Vendor.allCases.map { ($0, NetworkHighlighter(vendor: $0)) })

    /// Rule → capture name: `NetworkHighlightDefaults.suggestedTokenNames`
    /// verbatim, and it must stay verbatim.
    ///
    /// The one entry worth knowing about is `.mac`, which takes `property`
    /// rather than the `number` every other literal value gets. MACs and IPv4
    /// addresses must not share ink — SheepTerm itself never painted them alike
    /// (pink `E08BC7` vs cyan `6CD1E0`), and a config where `aabb.ccdd.eeff` and
    /// `10.20.30.40` are the same colour is harder to read, not easier.
    /// `property` is the closest this palette comes to that pink, and it is what
    /// the old Aruba rule table already used. This file used to override the
    /// package's suggestion to get it; the package's default IS that now, so the
    /// override is gone and there is one place to change it.
    static let ruleTokenNames: [NetworkRule: String] =
        NetworkHighlightDefaults.suggestedTokenNames

    /// Style per rule ordinal — resolved once, so the span loop does no
    /// dictionary work at all.
    private static let ruleStyles: [HighlightStyleID] = (0..<NetworkRule.allCases.count).map { ordinal in
        guard let rule = HighlightScanner.rule(ordinal: ordinal),
              let token = ruleTokenNames[rule]
        else { return HighlightStyleTable.none }
        return HighlightStyleTable.styleID(forCapture: token)
    }

    /// The five scopes the editor layer asks for, resolved once per pass.
    struct Palette {
        let keyword = HighlightStyleTable.styleID(forCapture: "keyword")
        let comment = HighlightStyleTable.styleID(forCapture: "comment")
        let number = HighlightStyleTable.styleID(forCapture: "number")
        let constant = HighlightStyleTable.styleID(forCapture: "constant")
        let error = HighlightStyleTable.styleID(forCapture: "error")
        let punctuation = HighlightStyleTable.styleID(forCapture: "punctuation")
    }

    /// Paint the lines intersecting `range`, which must start and end on line
    /// boundaries.
    ///
    /// Every rule on both layers is LINE-LOCAL — the package asserts it
    /// (`testPerLineEqualsWholeText`), and the editor layer reads one line and
    /// nothing else — so painting a line-aligned subrange gives exactly what a
    /// full pass gives for those lines. That is what makes the incremental path
    /// in `SyntaxEngine` exact rather than approximately right.
    static func highlight(
        text: String,
        nsText: NSString,
        in range: NSRange,
        vendor: Vendor,
        into painter: inout HighlightRunPainter
    ) {
        guard range.length > 0 else { return }
        let rules = NetworkConfigVendorRules.rules(for: vendor)
        let palette = Palette()

        // Layer 1: the editor's own reading of each line. `fill` is what a
        // scanner span may overwrite; `overrides` is what wins over one.
        var fill: [(HighlightStyleID, NSRange)] = []
        var overrides: [(HighlightStyleID, NSRange)] = []
        // Sorted, disjoint spans a scanner match may not touch: comment lines
        // and the validators' errors.
        var blocked: [NSRange] = []

        if rules.isActive {
            var buffer = CFStringInlineBuffer()
            CFStringInitInlineBuffer(nsText as CFString, &buffer, CFRangeMake(0, nsText.length))
            defer { withExtendedLifetime(nsText) {} }

            var cursor = range.location
            while let lineRange = nextLine(in: range, cursor: &cursor, buffer: &buffer) {
                highlightLine(
                    nsText: nsText, buffer: &buffer, lineRange: lineRange,
                    rules: rules, palette: palette,
                    fill: &fill, overrides: &overrides, blocked: &blocked
                )
            }
        }

        for (style, span) in fill { painter.paint(style, in: span) }

        // Layer 2: the package. One `spans(in:)` over the whole slice — it
        // splits lines itself and hands back UTF-16 offsets, which is what an
        // NSTextStorage counts in. UTF-8 -> UTF-16 conversion is the package's
        // job and it is exact for Thai and for emoji (a 4-byte lead is a
        // surrogate PAIR); this file must never try to do that arithmetic
        // itself.
        let coversWholeText = range.location == 0 && range.length == nsText.length
        let slice = coversWholeText ? text : nsText.substring(with: range)
        let highlighter = highlighters[vendor] ?? highlighters[.auto]!
        var blockIndex = 0
        for span in highlighter.spans(in: slice) {
            guard !rules.suppressedScannerRules.contains(span.rule) else { continue }
            let style = ruleStyles[HighlightScanner.ordinal(of: span.rule)]
            guard style != HighlightStyleTable.none else { continue }
            let painted = NSRange(
                location: range.location + span.range.lowerBound,
                length: span.range.upperBound - span.range.lowerBound
            )
            // Spans arrive in ascending order and `blocked` is sorted and
            // disjoint, so one forward cursor decides every one of them.
            while blockIndex < blocked.count,
                  NSMaxRange(blocked[blockIndex]) <= painted.location {
                blockIndex += 1
            }
            if blockIndex < blocked.count,
               blocked[blockIndex].location < NSMaxRange(painted) { continue }
            painter.paint(style, in: painted)
        }

        for (style, span) in overrides { painter.paint(style, in: span) }
    }

    // MARK: - One line

    /// The next line of `range`, terminator EXCLUDED, advancing `cursor` past
    /// it. nil at the end.
    ///
    /// This replaced `NSString.enumerateSubstrings(.byLines)`, which is
    /// locale- and grapheme-aware and was doing far more work than "find the
    /// line breaks": 5.67 ms against 1.10 ms on a 20 000-line config, over a
    /// `CFStringInlineBuffer` that the next line of `highlight` was building
    /// anyway.
    ///
    /// Two things have to stay exactly as `.byLines` had them:
    ///
    /// * the range EXCLUDES the terminator, which is what keeps a CRLF's `\r`
    ///   out of a token (`testCRLFGivesTheSameRunsPerLineAsItsLFTwin`);
    /// * the break set is LF, CR, CRLF, NEL, U+2028 and U+2029, and does NOT
    ///   include VT or FF. That is also what `NSString.lineRange(for:)` breaks
    ///   on — the call `SyntaxEngine.paragraphRanges` derives every incremental
    ///   range from — and what `NetworkHighlighter.spansUTF16` now splits on.
    ///   All three agreeing is what makes an incremental pass equal a clean one.
    private static func nextLine(
        in range: NSRange, cursor: inout Int, buffer: inout CFStringInlineBuffer
    ) -> NSRange? {
        let end = NSMaxRange(range)
        guard cursor < end else { return nil }
        let lineStart = cursor
        var index = cursor
        while index < end {
            let unit = CFStringGetCharacterFromInlineBuffer(&buffer, index)
            let terminator: Int
            switch unit {
            case 0x000A, 0x0085, 0x2028, 0x2029:
                terminator = 1
            case 0x000D:
                terminator = index + 1 < end
                    && CFStringGetCharacterFromInlineBuffer(&buffer, index + 1) == 0x000A ? 2 : 1
            default:
                index += 1
                continue
            }
            cursor = index + terminator
            return NSRange(location: lineStart, length: index - lineStart)
        }
        cursor = end
        return NSRange(location: lineStart, length: end - lineStart)
    }

    @inline(__always)
    private static func isBlank(_ unit: UniChar) -> Bool { unit == 0x20 || unit == 0x09 }

    /// Longest token this layer ever compares against a keyword set
    /// (`encapsulation`, `spanning-tree`, `rapid-pvst`). Anything longer cannot
    /// match, so it never needs a String built for it.
    private static let keywordLengthLimit = 16

    private static func lowercased(_ nsText: NSString, _ range: NSRange) -> String? {
        guard range.length > 0, range.length <= keywordLengthLimit else { return nil }
        return nsText.substring(with: range).lowercased()
    }

    private static func highlightLine(
        nsText: NSString,
        buffer: inout CFStringInlineBuffer,
        lineRange: NSRange,
        rules: NetworkConfigVendorRules,
        palette: Palette,
        fill: inout [(HighlightStyleID, NSRange)],
        overrides: inout [(HighlightStyleID, NSRange)],
        blocked: inout [NSRange]
    ) {
        guard lineRange.length > 0 else { return }
        let end = NSMaxRange(lineRange)

        var scan = lineRange.location
        while scan < end, isBlank(CFStringGetCharacterFromInlineBuffer(&buffer, scan)) { scan += 1 }
        guard scan < end else { return }

        if rules.commentMarkers.contains(CFStringGetCharacterFromInlineBuffer(&buffer, scan)) {
            overrides.append((palette.comment, lineRange))
            blocked.append(lineRange)
            return
        }

        // Tokenize into ranges only — no String is allocated per token.
        var tokens: [NSRange] = []
        tokens.reserveCapacity(8)
        var pos = scan
        while pos < end {
            while pos < end, isBlank(CFStringGetCharacterFromInlineBuffer(&buffer, pos)) { pos += 1 }
            guard pos < end else { break }
            let start = pos
            while pos < end, !isBlank(CFStringGetCharacterFromInlineBuffer(&buffer, pos)) { pos += 1 }
            tokens.append(NSRange(location: start, length: pos - start))
        }
        guard !tokens.isEmpty else { return }

        if rules.firstTokenIsKeyword {
            fill.append((palette.keyword, tokens[0]))
        }

        var next = 1
        // The matcher first: Swift evaluates the subscript's argument before the
        // lookup, so the old form built and lowercased a `String` for the first
        // token of EVERY line — including for the five families whose command
        // table is empty, which paid it to look nothing up.
        if rules.commandMatcher.contains(&buffer, tokens[0]),
           let command = rules.commands[lowercased(nsText, tokens[0]) ?? ""] {
            var resolved = command
            // Descend the sub-command tree as far as it goes. One level is
            // `spanning-tree mode`; `vlan configuration <list>` is the other
            // shape, and a three-word command would need three table entries
            // and nothing here.
            while next < tokens.count, !resolved.subCommands.isEmpty,
                  let sub = lowercased(nsText, tokens[next]),
                  let child = resolved.subCommands[sub] {
                fill.append((palette.keyword, tokens[next]))
                resolved = child
                next += 1
            }
            if let argument = resolved.argument, next < tokens.count {
                next = apply(
                    argument, at: next, tokens: tokens, nsText: nsText, buffer: &buffer,
                    palette: palette, fill: &fill, overrides: &overrides, blocked: &blocked
                )
            }
        }

        // Two pieces of line state, both of which exist because a word means
        // different things in different places on the same line.
        //
        // `listIsOpen`: has a `vlan` / `vlan-list` token appeared yet? Only then
        // do `add` / `remove` / `except` continue a list.
        // `freeText`: has a command been seen after which the line is prose?
        // Then the editor layer claims nothing more on it.
        var listIsOpen = false
        for consumed in 0..<next {
            if rules.freeTextMatcher.contains(&buffer, tokens[consumed]) { return }
            if rules.vlanListIntroducerMatcher.contains(&buffer, tokens[consumed]) {
                listIsOpen = true
            }
        }

        // The tail runs for every remaining token in the document, so all of
        // its questions go through `NetworkKeywordSet` — length-bucketed
        // comparison against the inline buffer, no `String` built at all. This
        // used to be a `substring` + `lowercased()` per token whether or not the
        // vendor had any word to look up.
        var previous = tokens[next - 1]
        var index = next
        while index < tokens.count {
            let token = tokens[index]
            let previousOpensAList = rules.vlanListIntroducerMatcher.contains(&buffer, previous)
                || (listIsOpen && rules.vlanListContinuationMatcher.contains(&buffer, previous))
            if previousOpensAList {
                let after = paintVlanArgument(
                    at: index, tokens: tokens, nsText: nsText, buffer: &buffer,
                    palette: palette, fill: &fill, overrides: &overrides, blocked: &blocked
                )
                if after > index {
                    previous = tokens[after - 1]
                    index = after
                    continue
                }
            }
            // Everything from here on is what a person typed.
            if rules.freeTextMatcher.contains(&buffer, token) { return }
            if rules.subKeywordMatcher.contains(&buffer, token) {
                fill.append((palette.keyword, token))
            } else if rules.paintsPlainNumbers {
                paintPlainNumber(
                    nsText: nsText, buffer: &buffer, token: token,
                    palette: palette, fill: &fill
                )
            }
            if rules.vlanListIntroducerMatcher.contains(&buffer, token) { listIsOpen = true }
            previous = token
            index += 1
        }
    }

    /// Apply a command's argument starting at token `index`; returns the index
    /// of the first token it did not consume.
    private static func apply(
        _ argument: NetworkConfigCommand.Argument,
        at index: Int,
        tokens: [NSRange],
        nsText: NSString,
        buffer: inout CFStringInlineBuffer,
        palette: Palette,
        fill: inout [(HighlightStyleID, NSRange)],
        overrides: inout [(HighlightStyleID, NSRange)],
        blocked: inout [NSRange]
    ) -> Int {
        switch argument {
        case .vlanList:
            return paintVlanArgument(
                at: index, tokens: tokens, nsText: nsText, buffer: &buffer,
                palette: palette, fill: &fill, overrides: &overrides, blocked: &blocked
            )
        case .oneOf(let allowed):
            let token = tokens[index]
            let value = lowercased(nsText, token)
            if let value, allowed.contains(value) {
                fill.append((palette.constant, token))
            } else {
                overrides.append((palette.error, token))
                blocked.append(token)
            }
            return index + 1
        }
    }

    /// The VLAN list that starts at token `index`, or nothing.
    ///
    /// Two rules, and both of them were bugs:
    ///
    /// * **It has to start with a digit.** `vlan` heads half a dozen unrelated
    ///   IOS globals (`vlan internal allocation policy ascending`, `vlan dot1q
    ///   tag native`, `vlan database`) and every one of them used to have its
    ///   second token painted error-red on a config that was perfectly correct.
    /// * **It may run over several tokens.** `show running-config` never writes
    ///   a space after a comma, but a hand-edited config does, and
    ///   `vlan 10, 20, 5000` tokenises into three. Only the first was judged, so
    ///   `5000` came out in the same orange a *validated* item gets.
    ///
    /// Returns the index after the list, or `index` when this is not one.
    private static func paintVlanArgument(
        at index: Int,
        tokens: [NSRange],
        nsText: NSString,
        buffer: inout CFStringInlineBuffer,
        palette: Palette,
        fill: inout [(HighlightStyleID, NSRange)],
        overrides: inout [(HighlightStyleID, NSRange)],
        blocked: inout [NSRange]
    ) -> Int {
        let first = tokens[index]
        guard first.length > 0 else { return index }
        let lead = CFStringGetCharacterFromInlineBuffer(&buffer, first.location)
        guard lead >= 0x30, lead <= 0x39 else { return index }

        // Keep taking tokens while the list is unfinished: either this one ends
        // on a comma or the next one opens with it.
        var last = index
        while last + 1 < tokens.count {
            let endsOnComma =
                CFStringGetCharacterFromInlineBuffer(&buffer, NSMaxRange(tokens[last]) - 1) == 0x2C
            let nextOpensOnComma =
                CFStringGetCharacterFromInlineBuffer(&buffer, tokens[last + 1].location) == 0x2C
            guard endsOnComma || nextOpensOnComma else { break }
            last += 1
        }

        let listRange = NSUnionRange(tokens[index], tokens[last])
        paintVlanList(
            nsText: nsText, buffer: &buffer, listRange: listRange,
            palette: palette, fill: &fill, overrides: &overrides, blocked: &blocked
        )
        return last + 1
    }

    /// `1,3,23,101-102,306s` — every item judged on its own. The range may span
    /// the blanks of a spaced list (`10, 20, 30`), so each item's own run is
    /// trimmed back to the item.
    private static func paintVlanList(
        nsText: NSString,
        buffer: inout CFStringInlineBuffer,
        listRange: NSRange,
        palette: Palette,
        fill: inout [(HighlightStyleID, NSRange)],
        overrides: inout [(HighlightStyleID, NSRange)],
        blocked: inout [NSRange]
    ) {
        let end = NSMaxRange(listRange)
        var itemStart = listRange.location
        var cursor = listRange.location
        while cursor <= end {
            let isComma = cursor < end
                && CFStringGetCharacterFromInlineBuffer(&buffer, cursor) == 0x2C
            if cursor == end || isComma {
                var itemBegin = itemStart
                var itemEnd = cursor
                while itemBegin < itemEnd,
                      isBlank(CFStringGetCharacterFromInlineBuffer(&buffer, itemBegin)) {
                    itemBegin += 1
                }
                while itemEnd > itemBegin,
                      isBlank(CFStringGetCharacterFromInlineBuffer(&buffer, itemEnd - 1)) {
                    itemEnd -= 1
                }
                if itemEnd > itemBegin {
                    let itemRange = NSRange(location: itemBegin, length: itemEnd - itemBegin)
                    if isValidVlanItem(&buffer, itemRange) {
                        fill.append((palette.number, itemRange))
                    } else {
                        overrides.append((palette.error, itemRange))
                        blocked.append(itemRange)
                    }
                }
                if cursor == end { break }
                fill.append((palette.punctuation, NSRange(location: cursor, length: 1)))
                itemStart = cursor + 1
            }
            cursor += 1
        }
    }

    /// The `String` form exists for tests and one-off callers; the painter
    /// goes through the buffer form below.
    static func isValidVlanItem(_ item: String) -> Bool {
        let ns = item.trimmingCharacters(in: .whitespaces) as NSString
        var buffer = CFStringInlineBuffer()
        CFStringInitInlineBuffer(ns, &buffer, CFRange(location: 0, length: ns.length))
        return isValidVlanItem(&buffer, NSRange(location: 0, length: ns.length))
    }

    /// `N` or `A-B`, ASCII digits only, each in `1…4094`, `A <= B`.
    ///
    /// Reads the inline buffer directly: the list painter runs this once per
    /// item, and `switchport trunk allowed vlan 10,20,30-40,…` on every third
    /// line of a switch config used to mean a `substring` + `trimming` + `split`
    /// per item — tens of thousands of `String`s for one full pass, which is
    /// what made the Cisco full pass the one network workload that got slower
    /// when the introducer rule started reaching those lines at all. A VLAN id
    /// is digits and nothing else: `Int.init` accepts a sign, so `vlan +5` was
    /// once valid, and IOS does not take it.
    static func isValidVlanItem(_ buffer: inout CFStringInlineBuffer, _ range: NSRange) -> Bool {
        let end = NSMaxRange(range)
        var cursor = range.location
        // Digits up to a `-` or the end. Values are clamped past the maximum
        // rather than overflowed — `99999999999999999999` is simply invalid.
        func number() -> Int? {
            var value = 0
            var digits = 0
            while cursor < end {
                let unit = CFStringGetCharacterFromInlineBuffer(&buffer, cursor)
                guard unit >= 0x30, unit <= 0x39 else { break }
                if value <= 4094 { value = value * 10 + Int(unit - 0x30) }
                digits += 1
                cursor += 1
            }
            return digits == 0 ? nil : value
        }
        guard let low = number(), low >= 1, low <= 4094 else { return false }
        if cursor == end { return true }
        guard CFStringGetCharacterFromInlineBuffer(&buffer, cursor) == 0x2D else { return false }
        cursor += 1
        guard let high = number(), cursor == end, high >= 1, high <= 4094, low <= high else { return false }
        return true
    }

    private static func paintPlainNumber(
        nsText: NSString,
        buffer: inout CFStringInlineBuffer,
        token: NSRange,
        palette: Palette,
        fill: inout [(HighlightStyleID, NSRange)]
    ) {
        guard token.length > 0 else { return }
        // ASCII fast path over the inline buffer. `Character.isNumber` is also
        // true for non-ASCII digits (Thai ๐-๙ among them), so a token carrying
        // any non-ASCII unit falls back to the Character test rather than
        // quietly changing what counts as a number.
        var allNumeric = true
        var sawNonASCII = false
        for index in token.location..<NSMaxRange(token) {
            let unit = CFStringGetCharacterFromInlineBuffer(&buffer, index)
            if unit > 0x7F { sawNonASCII = true; break }
            let isDigit = unit >= 0x30 && unit <= 0x39
            if !(isDigit || unit == 0x2E || unit == 0x3A) { allNumeric = false; break }
        }
        if sawNonASCII {
            allNumeric = nsText.substring(with: token)
                .allSatisfy { $0.isNumber || $0 == "." || $0 == ":" }
        }
        if allNumeric { fill.append((palette.number, token)) }
    }
}
