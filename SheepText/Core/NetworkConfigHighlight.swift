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
    /// plugin overrides and hand-edited preferences still carry them.
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
    static func vendor(forEngineLanguage languageID: String) -> Vendor? {
        if let alias = aliases[languageID.lowercased()] { return alias }
        if languageID == id { return .auto }
        guard languageID.hasPrefix(id + ":") else { return nil }
        return Vendor(rawValue: String(languageID.dropFirst(id.count + 1))) ?? .auto
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
        case vlanList
        /// A closed set: a member takes the constant colour, anything else is
        /// an error (`spanning-tree mode rpvsts`).
        case oneOf(Set<String>)
    }

    /// What the token immediately after the command means.
    let argument: Argument?
    /// Sub-commands keyed by the second token (`spanning-tree` → `mode`).
    let subCommands: [String: NetworkConfigCommand]

    init(argument: Argument? = nil, subCommands: [String: NetworkConfigCommand] = [:]) {
        self.argument = argument
        self.subCommands = subCommands
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
    /// Package rules this family's editor layer replaces.
    ///
    /// Cisco suppresses `vlan` because the scanner's VLAN rule spans the
    /// `vlan` keyword AND its list as one constant-coloured span, which would
    /// bury both the command keyword and the per-item validation above. Every
    /// other family keeps it — none of them validates the list.
    let suppressedScannerRules: Set<NetworkRule>

    var isActive: Bool {
        firstTokenIsKeyword || paintsPlainNumbers
            || !commentMarkers.isEmpty || !commands.isEmpty || !subKeywords.isEmpty
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

    private static let ciscoCommands: [String: NetworkConfigCommand] = [
        "vlan": NetworkConfigCommand(argument: .vlanList),
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
        subKeywords: [], commands: [:], suppressedScannerRules: []
    )

    private static func standard(
        comment: [UniChar],
        subKeywords: Set<String> = [],
        commands: [String: NetworkConfigCommand] = [:],
        suppressing: Set<NetworkRule> = []
    ) -> NetworkConfigVendorRules {
        NetworkConfigVendorRules(
            commentMarkers: comment,
            firstTokenIsKeyword: true,
            paintsPlainNumbers: true,
            subKeywords: subKeywords,
            commands: commands,
            suppressedScannerRules: suppressing
        )
    }

    static let table: [Vendor: NetworkConfigVendorRules] = [
        .auto: neutral,
        .cisco: standard(comment: bang, subKeywords: switchSubKeywords,
                         commands: ciscoCommands, suppressing: [.vlan]),
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
            var lineRanges: [NSRange] = []
            nsText.enumerateSubstrings(
                in: range, options: [.byLines, .substringNotRequired]
            ) { _, lineRange, _, _ in
                lineRanges.append(lineRange)
            }

            var buffer = CFStringInlineBuffer()
            CFStringInitInlineBuffer(nsText as CFString, &buffer, CFRangeMake(0, nsText.length))
            defer { withExtendedLifetime(nsText) {} }

            for lineRange in lineRanges {
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
        if let command = rules.commands[lowercased(nsText, tokens[0]) ?? ""] {
            var resolved = command
            if tokens.count >= 2,
               let sub = lowercased(nsText, tokens[1]),
               let child = command.subCommands[sub] {
                fill.append((palette.keyword, tokens[1]))
                resolved = child
                next = 2
            }
            if let argument = resolved.argument, tokens.count > next {
                apply(
                    argument, to: tokens[next], nsText: nsText, buffer: &buffer,
                    palette: palette, fill: &fill, overrides: &overrides, blocked: &blocked
                )
                next += 1
            }
        }

        for token in tokens[min(next, tokens.count)...] {
            if let lower = lowercased(nsText, token), rules.subKeywords.contains(lower) {
                fill.append((palette.keyword, token))
            } else if rules.paintsPlainNumbers {
                paintPlainNumber(
                    nsText: nsText, buffer: &buffer, token: token,
                    palette: palette, fill: &fill
                )
            }
        }
    }

    private static func apply(
        _ argument: NetworkConfigCommand.Argument,
        to token: NSRange,
        nsText: NSString,
        buffer: inout CFStringInlineBuffer,
        palette: Palette,
        fill: inout [(HighlightStyleID, NSRange)],
        overrides: inout [(HighlightStyleID, NSRange)],
        blocked: inout [NSRange]
    ) {
        switch argument {
        case .vlanList:
            paintVlanList(
                nsText: nsText, buffer: &buffer, listRange: token,
                palette: palette, fill: &fill, overrides: &overrides, blocked: &blocked
            )
        case .oneOf(let allowed):
            let value = lowercased(nsText, token)
            if let value, allowed.contains(value) {
                fill.append((palette.constant, token))
            } else {
                overrides.append((palette.error, token))
                blocked.append(token)
            }
        }
    }

    /// `1,3,23,101-102,306s` — every item judged on its own.
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
                if cursor > itemStart {
                    let itemRange = NSRange(location: itemStart, length: cursor - itemStart)
                    if isValidVlanItem(nsText.substring(with: itemRange)) {
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

    static func isValidVlanItem(_ item: String) -> Bool {
        let trimmed = item.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        if let single = Int(trimmed), single >= 1, single <= 4094 { return true }
        let parts = trimmed.split(separator: "-", maxSplits: 1)
        if parts.count == 2,
           let low = Int(parts[0]), let high = Int(parts[1]),
           low >= 1, low <= 4094, high >= 1, high <= 4094, low <= high { return true }
        return false
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
