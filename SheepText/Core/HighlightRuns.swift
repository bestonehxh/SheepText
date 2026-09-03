//
//  HighlightRuns.swift
//  The syntax engine's output, and the palette that turns it into attributes.
//
//  The engine used to hand back a document-sized `NSAttributedString`, and the
//  editor copied it into the `NSTextStorage`. That made the *apply* cost
//  proportional to the FILE (65 ms on 542k characters, on the main thread, on
//  every tab switch, appearance change and dropped completion), when what the
//  user can see is proportional to the SCREEN.
//
//  So the engine now produces a compact, sorted, non-overlapping list of
//  `HighlightRun`s over the full text, and the editor paints only the visible
//  ones through `NSLayoutManager.addTemporaryAttributes`. Two properties make
//  that work:
//
//  1. **A run carries a `HighlightStyleID`, not a colour.** The id indexes a
//     fixed table, so the same run list serves light and dark: an appearance
//     change re-resolves the palette and repaints the viewport, with no parse
//     and no re-query. (`isDark` is therefore NOT part of a run, of a parse
//     session, or of the editor's run cache.)
//  2. **Every style is layout-neutral.** Temporary attributes must not change
//     glyph metrics — TextKit lays out from the text storage and never
//     re-lays-out when a temporary attribute changes — so no style may carry
//     `.font`, `.kern`, `.baselineOffset`, `.expansion` or a paragraph style.
//     `HighlightStyleTable.paletteIsLayoutNeutral` is the machine-checkable
//     form of that rule and a test asserts it.
//

import AppKit

/// Index into `HighlightStyleTable.styles`. 0 means "no style" — the character
/// keeps the editor's base foreground, exactly like a capture that resolved to
/// no attributes did before.
typealias HighlightStyleID = UInt16

/// One maximal span of text sharing a style, in **full-text UTF-16 offsets**
/// (the coordinates the syntax engine works in — never display offsets, which
/// differ whenever a fold is collapsed).
nonisolated struct HighlightRun: Equatable, Sendable {
    var location: Int
    var length: Int
    var style: HighlightStyleID

    init(location: Int, length: Int, style: HighlightStyleID) {
        self.location = location
        self.length = length
        self.style = style
    }

    init(range: NSRange, style: HighlightStyleID) {
        self.init(location: range.location, length: range.length, style: style)
    }

    var range: NSRange {
        get { NSRange(location: location, length: length) }
        set { location = newValue.location; length = newValue.length }
    }

    var end: Int { location + length }
}

// MARK: - The style table

/// The fixed set of token styles, and the capture-name resolution that maps a
/// grammar's `@capture` onto one.
nonisolated enum HighlightStyleTable {

    /// The reserved id for "this text has no token style".
    static let none: HighlightStyleID = 0

    struct Style: Sendable {
        /// The tree-sitter scope this style is named by, e.g. `keyword.function`.
        let scope: String
        /// sRGB, dark appearance / light appearance.
        let dark: UInt32
        let light: UInt32
        /// Markdown emphasis. Rendered with `.obliqueness` / `.strokeWidth`,
        /// which skew and outline the SAME glyphs — deliberately not a bold or
        /// italic *font*, which would change advances and therefore layout, and
        /// so could never be a temporary attribute. See the file header.
        let oblique: Bool
        let stroked: Bool
    }

    /// One Dark (dark) / One Light (light) — Zed default theme colours.
    ///
    /// Index 0 is the "no style" sentinel and is never painted. The order of
    /// the rest is the id assignment: ids are an implementation detail that
    /// never leaves the process (nothing persists them), so the list may be
    /// reordered or extended freely.
    static let styles: [Style] = {
        var list: [Style] = [Style(scope: "", dark: 0, light: 0, oblique: false, stroked: false)]
        for entry in definitions {
            list.append(Style(
                scope: entry.0,
                dark: entry.1,
                light: entry.2,
                oblique: obliqueScopes.contains(entry.0),
                stroked: strokedScopes.contains(entry.0)
            ))
        }
        return list
    }()

    private static let obliqueScopes: Set<String> = ["emphasis", "markup.italic", "text.emphasis"]
    private static let strokedScopes: Set<String> = ["emphasis.strong", "markup.bold", "text.strong"]

    /// Keys are standard tree-sitter highlight names; the hierarchical resolver
    /// below means `keyword.function` falls back to `keyword` automatically.
    private static let definitions: [(String, UInt32, UInt32)] = [
        // comments
        ("comment",                    0x5C6370, 0xA0A1A7),
        ("comment.doc",                0x5C6370, 0xA0A1A7),
        // strings
        ("string",                     0x98C379, 0x50A14F),
        ("string.escape",              0x56B6C2, 0x0184BC),
        ("string.regex",               0x98C379, 0x50A14F),
        ("string.special",             0x56B6C2, 0x0184BC),
        ("string.special.symbol",      0x56B6C2, 0x0184BC),
        // literals
        ("number",                     0xD19A66, 0x986801),
        ("boolean",                    0xD19A66, 0x986801),
        ("character",                  0xD19A66, 0x986801),
        // constants
        ("constant",                   0x56B6C2, 0x0184BC),
        ("constant.builtin",           0x56B6C2, 0x0184BC),
        // keywords
        ("keyword",                    0xC678DD, 0xA626A4),
        ("keyword.type",               0x56B6C2, 0x0184BC),
        ("keyword.directive",          0xC678DD, 0xA626A4),
        // functions
        ("function",                   0x61AFEF, 0x4078F2),
        ("function.builtin",           0x56B6C2, 0x0184BC),
        ("function.macro",             0xC678DD, 0xA626A4),
        ("function.method",            0x61AFEF, 0x4078F2),
        ("function.method.builtin",    0x56B6C2, 0x0184BC),
        // types
        ("constructor",                0xE5C07B, 0xC18401),
        ("constructor.builtin",        0x56B6C2, 0x0184BC),
        ("type",                       0xE5C07B, 0xC18401),
        ("type.builtin",               0x56B6C2, 0x0184BC),
        ("type.enum.variant",          0x56B6C2, 0x0184BC),
        // attributes / decorators
        ("attribute",                  0xE5C07B, 0xC18401),
        // members
        ("property",                   0xE06C75, 0xE45649),
        ("label",                      0xE06C75, 0xE45649),
        // variables
        ("variable",                   0xABB2BF, 0x383A42),
        ("variable.builtin",           0xE06C75, 0xE45649),
        ("variable.member",            0xE06C75, 0xE45649),
        ("variable.parameter",         0xE06C75, 0xE45649),
        ("variable.special",           0xE06C75, 0xE45649),
        // HTML / JSX
        ("tag",                        0xE06C75, 0xE45649),
        ("tag.attribute",              0xE5C07B, 0xC18401),
        ("tag.doctype",                0xC678DD, 0xA626A4),
        // operators / punctuation
        ("operator",                   0xABB2BF, 0x383A42),
        ("punctuation",                0xABB2BF, 0x383A42),
        ("punctuation.bracket",        0xABB2BF, 0x383A42),
        ("punctuation.delimiter",      0xABB2BF, 0x383A42),
        ("punctuation.list_marker",    0xE06C75, 0xE45649),
        ("punctuation.special",        0x56B6C2, 0x0184BC),
        // embedded / misc
        ("embedded",                   0xABB2BF, 0x383A42),
        // markdown / rich text
        ("title",                      0xE5C07B, 0xC18401),
        ("emphasis",                   0xABB2BF, 0x383A42),
        ("emphasis.strong",            0xABB2BF, 0x383A42),
        ("link_text",                  0x61AFEF, 0x4078F2),
        ("link_uri",                   0x56B6C2, 0x0184BC),
        ("text.literal",               0x98C379, 0x50A14F),
        // text.* aliases — the nvim-treesitter names the bundled markdown
        // grammars actually emit. Only `text.literal` was defined, so a
        // markdown heading, link or emphasis resolved through the hierarchy to
        // `text`, which is not a scope either, and came out with no style at
        // all. `text.emphasis` and `text.strong` were already named in
        // `obliqueScopes` / `strokedScopes` above — those sets were describing
        // entries that did not exist. Same colours as the `markup.*` and bare
        // aliases beside them; this adds no new colour to the palette.
        ("text.title",                 0xE5C07B, 0xC18401),
        ("text.emphasis",              0xABB2BF, 0x383A42),
        ("text.strong",                0xABB2BF, 0x383A42),
        ("text.uri",                   0x56B6C2, 0x0184BC),
        ("text.reference",             0x61AFEF, 0x4078F2),
        // markup.* aliases used by some grammars
        ("markup.heading",             0xE5C07B, 0xC18401),
        ("markup.bold",                0xABB2BF, 0x383A42),
        ("markup.italic",              0xABB2BF, 0x383A42),
        ("markup.raw",                 0x98C379, 0x50A14F),
        ("markup.link",                0x56B6C2, 0x0184BC),
        ("markup.quote",               0x5C6370, 0xA0A1A7),
        ("markup.list",                0xE06C75, 0xE45649),
        // SheepText log grammar
        ("log.error",                  0xE06C75, 0xE45649),
        ("log.warning",                0xD19A66, 0xC18401),
        ("log.success",                0x98C379, 0x50A14F),
        // diff grammar tokens
        ("diff.plus",                  0x98C379, 0x50A14F),
        ("diff.minus",                 0xE06C75, 0xE45649),
        ("diff.delta",                 0xD19A66, 0x986801),
        ("diff.delta.moved",           0x61AFEF, 0x4078F2),
        // SheepText UI tokens
        ("hint",                       0x5C6370, 0xA0A1A7),
        ("predictive",                 0x4B5263, 0xBBBFC6),
        ("primary",                    0xABB2BF, 0x383A42),
        // Error / invalid token (used by the regex-based highlighters)
        ("error",                      0xFF5F57, 0xE45649),
        // Verdict tokens. `network_config` maps the package's `state-warn` rule
        // here; `string` (green) and `error` (red) already carried the other two
        // thirds of the traffic light, and there was no amber that was not
        // spelled `log.warning`. Same amber as `log.warning`, and the same
        // meaning as `editorModifiedAmber` in `AppColors`: attention, not
        // failure.
        ("warning",                    0xD19A66, 0xC18401)
    ]

    /// scope → id, for the exact scopes above.
    private static let idsByScope: [String: HighlightStyleID] = {
        var map: [String: HighlightStyleID] = [:]
        for (index, style) in styles.enumerated() where index > 0 {
            map[style.scope] = HighlightStyleID(index)
        }
        return map
    }()

    // Resolution memo, keyed on the raw capture name a grammar handed us.
    //
    // Every capture in a 100k-character Swift file comes through here — order
    // of 15 000 lookups — and resolution lowercases, strips a prefix and walks
    // the dot hierarchy slicing a String per step. The lock costs ~50 ns and
    // buys freedom from having to prove that every caller is on the engine's
    // serial queue (the tests are not).
    nonisolated(unsafe) private static var memo: [String: HighlightStyleID] = [:]
    private static let memoLock = NSLock()
    private static let memoLimit = 1024

    /// Resolve a grammar capture name (`@keyword.function`, `string.special`)
    /// to a style id, hierarchically: `keyword.function` → `keyword` → none.
    static func styleID(forCapture captureName: String) -> HighlightStyleID {
        memoLock.lock()
        if let cached = memo[captureName] {
            memoLock.unlock()
            return cached
        }
        memoLock.unlock()

        let resolved = resolve(captureName)

        memoLock.lock()
        if memo.count >= memoLimit { memo.removeAll(keepingCapacity: true) }
        memo[captureName] = resolved
        memoLock.unlock()
        return resolved
    }

    private static func resolve(_ captureName: String) -> HighlightStyleID {
        var scope = normalizedScope(captureName)
        while !scope.isEmpty {
            if let id = idsByScope[scope] { return id }
            guard let dot = scope.lastIndex(of: ".") else { break }
            scope = String(scope[scope.startIndex..<dot])
        }
        return none
    }

    /// Tree-sitter strips the `@` when it stores a capture name, so nothing
    /// SwiftTreeSitter delivers here has ever carried one; the leading strip is
    /// kept as a cheap prefix check because the regex highlighters pass scope
    /// names of their own.
    private static func normalizedScope(_ captureName: String) -> String {
        var scope = captureName.lowercased()
        if scope.hasPrefix("@") { scope.removeFirst() }
        return scope.replacingOccurrences(of: "syntax.", with: "")
    }

    // MARK: Attributes

    static func color(_ id: HighlightStyleID, isDark: Bool) -> NSColor? {
        guard id != none, Int(id) < styles.count else { return nil }
        let style = styles[Int(id)]
        return rgb(isDark ? style.dark : style.light)
    }

    /// The attribute dictionary for a style. **Layout-neutral by construction**
    /// — see the file header. Used by the palette (main actor) and by the
    /// `NSAttributedString` compatibility shim.
    static func attributes(_ id: HighlightStyleID, isDark: Bool) -> [NSAttributedString.Key: Any] {
        guard id != none, Int(id) < styles.count else { return [:] }
        let style = styles[Int(id)]
        var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: rgb(isDark ? style.dark : style.light)]
        if style.oblique { attrs[.obliqueness] = 0.12 }
        if style.stroked { attrs[.strokeWidth] = -2.0 }
        return attrs
    }

    /// Every attribute key any style can emit. The apply layer owns exactly
    /// these keys in the layout manager's temporary attributes and removes
    /// exactly these — never a key someone else painted (compare mode's
    /// `.backgroundColor`, for one).
    static let ownedAttributeKeys: [NSAttributedString.Key] = [
        .foregroundColor, .obliqueness, .strokeWidth
    ]

    /// Keys that would change glyph metrics, and so can never travel through
    /// `addTemporaryAttributes`. Asserted against the whole palette by a test.
    static let layoutAffectingKeys: [NSAttributedString.Key] = [
        .font, .kern, .baselineOffset, .expansion, .paragraphStyle, .attachment, .ligature
    ]

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green:   CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue:    CGFloat(hex & 0xFF) / 255.0,
            alpha: 1
        )
    }
}

// MARK: - Palette

/// `HighlightStyleID` → attributes, resolved once per appearance on the main
/// actor and handed to `addTemporaryAttributes` without further work.
@MainActor
final class HighlightPalette {

    let isDark: Bool
    private let resolved: [[NSAttributedString.Key: Any]]

    private static var cache: [Bool: HighlightPalette] = [:]

    static func shared(isDark: Bool) -> HighlightPalette {
        if let existing = cache[isDark] { return existing }
        let palette = HighlightPalette(isDark: isDark)
        cache[isDark] = palette
        return palette
    }

    /// Theme colours are compiled in today, so this only matters to tests — but
    /// the door is here so a future editable theme has one place to knock.
    static func invalidateAll() { cache.removeAll() }

    init(isDark: Bool) {
        self.isDark = isDark
        self.resolved = HighlightStyleTable.styles.indices.map {
            HighlightStyleTable.attributes(HighlightStyleID($0), isDark: isDark)
        }
    }

    func attributes(for style: HighlightStyleID) -> [NSAttributedString.Key: Any] {
        let index = Int(style)
        guard index > 0, index < resolved.count else { return [:] }
        return resolved[index]
    }
}

// MARK: - Painter

/// Accumulates overlapping capture paints into one style per character, then
/// hands back the maximal runs.
///
/// Painting into a scratch array rather than straight into a run list is what
/// preserves the old `addAttributes` semantics: captures nest, the innermost
/// one wins, and a capture that resolves to no style leaves whatever is
/// underneath it alone (that used to be `guard !attrs.isEmpty`).
///
/// `bounds` is a set of disjoint ranges, not one range: an incremental pass
/// repaints a handful of changed paragraphs that can sit far apart, and a
/// scratch buffer spanning the gap between them would be the size of the
/// document.
nonisolated struct HighlightRunPainter {

    private let segments: [NSRange]
    /// Prefix sums: `starts[i]` is where segment `i` begins in `scratch`.
    private let starts: [Int]
    private var scratch: [HighlightStyleID]

    init(bounds: [NSRange]) {
        var sorted = bounds.filter { $0.length > 0 }.sorted { $0.location < $1.location }
        // Merge touching/overlapping ranges so no character is represented twice.
        var merged: [NSRange] = []
        for range in sorted {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        sorted = merged
        var offsets: [Int] = []
        offsets.reserveCapacity(sorted.count)
        var total = 0
        for range in sorted {
            offsets.append(total)
            total += range.length
        }
        self.segments = sorted
        self.starts = offsets
        self.scratch = [HighlightStyleID](repeating: HighlightStyleTable.none, count: total)
    }

    init(bounds: NSRange) { self.init(bounds: [bounds]) }

    var isEmpty: Bool { scratch.isEmpty }

    /// Paint `style` over `range`. Later paints win, which is the order the
    /// queries run in: primary highlights, then markdown fences, then
    /// injections.
    mutating func paint(_ style: HighlightStyleID, in range: NSRange) {
        guard style != HighlightStyleTable.none, range.length > 0 else { return }
        for (index, segment) in segments.enumerated() {
            let hit = NSIntersectionRange(segment, range)
            guard hit.length > 0 else { continue }
            let base = starts[index] + (hit.location - segment.location)
            for offset in base..<(base + hit.length) { scratch[offset] = style }
        }
    }

    /// The painted spans, sorted by location and non-overlapping.
    func runs() -> [HighlightRun] {
        var result: [HighlightRun] = []
        result.reserveCapacity(scratch.count / 8 + 1)
        for (index, segment) in segments.enumerated() {
            let base = starts[index]
            var offset = 0
            while offset < segment.length {
                let style = scratch[base + offset]
                if style == HighlightStyleTable.none { offset += 1; continue }
                var end = offset + 1
                while end < segment.length, scratch[base + end] == style { end += 1 }
                result.append(HighlightRun(
                    location: segment.location + offset,
                    length: end - offset,
                    style: style
                ))
                offset = end
            }
        }
        return result
    }
}

// MARK: - Run-list algebra

nonisolated enum HighlightRunList {

    /// Index of the first run that could intersect `location` — i.e. the first
    /// whose end is past it. Runs are sorted and disjoint, so this is a plain
    /// lower bound.
    static func firstIndex(endingAfter location: Int, in runs: [HighlightRun]) -> Int {
        var low = 0
        var high = runs.count
        while low < high {
            let mid = (low + high) / 2
            if runs[mid].end <= location { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Every run intersecting `range`, clipped to it.
    static func forEach(
        _ runs: [HighlightRun],
        intersecting range: NSRange,
        _ body: (NSRange, HighlightStyleID) -> Void
    ) {
        guard range.length > 0 else { return }
        let end = NSMaxRange(range)
        var index = firstIndex(endingAfter: range.location, in: runs)
        while index < runs.count, runs[index].location < end {
            let run = runs[index]
            index += 1
            let hit = NSIntersectionRange(run.range, range)
            guard hit.length > 0 else { continue }
            body(hit, run.style)
        }
    }

    /// The style at a character, or `none`.
    static func style(at index: Int, in runs: [HighlightRun]) -> HighlightStyleID {
        let position = firstIndex(endingAfter: index, in: runs)
        guard position < runs.count, runs[position].location <= index else {
            return HighlightStyleTable.none
        }
        return runs[position].style
    }

    /// Move runs across a text edit that replaced `oldRange` with `newLength`
    /// characters, so the list keeps describing the CURRENT text while the
    /// engine's next pass is still in flight.
    ///
    /// The five overlap cases are the same ones `DiffLayoutManager.processEditing`
    /// handles for its compare highlights, and for the same reason: treating the
    /// edit as a point corrupts every run a multi-character replacement spans.
    static func shifting(
        _ runs: [HighlightRun],
        replacing oldRange: NSRange,
        withLength newLength: Int
    ) -> [HighlightRun] {
        let delta = newLength - oldRange.length
        let editStart = oldRange.location
        let editEnd = NSMaxRange(oldRange)
        guard delta != 0 || oldRange.length > 0 else { return runs }

        var result: [HighlightRun] = []
        result.reserveCapacity(runs.count)
        for run in runs {
            let start = run.location
            let end = run.end
            if end <= editStart {
                result.append(run)
            } else if start >= editEnd {
                result.append(HighlightRun(location: start + delta, length: run.length, style: run.style))
            } else if start <= editStart && end >= editEnd {
                let length = run.length + delta
                if length > 0 {
                    result.append(HighlightRun(location: start, length: length, style: run.style))
                }
            } else if start < editStart {
                result.append(HighlightRun(location: start, length: editStart - start, style: run.style))
            } else if end > editEnd {
                result.append(HighlightRun(
                    location: editStart + newLength,
                    length: end - editEnd,
                    style: run.style
                ))
            }
            // else: entirely inside the replaced span — the styled text is gone.
        }
        return result
    }

    /// Replace whatever `runs` says about `ranges` with `fresh`.
    ///
    /// `fresh` must lie inside `ranges` (it comes from a painter bounded by
    /// them). Runs that straddle a boundary — a block comment crossing a
    /// repainted paragraph — are trimmed, not dropped.
    static func replacing(
        _ runs: [HighlightRun],
        in ranges: [NSRange],
        with fresh: [HighlightRun]
    ) -> [HighlightRun] {
        let cleared = ranges.filter { $0.length > 0 }.sorted { $0.location < $1.location }
        guard !cleared.isEmpty else { return runs }

        var surviving: [HighlightRun] = []
        surviving.reserveCapacity(runs.count)
        var clearIndex = 0

        for run in runs {
            // Advance past cleared ranges entirely behind this run.
            while clearIndex < cleared.count, NSMaxRange(cleared[clearIndex]) <= run.location {
                clearIndex += 1
            }
            var pieces = [run.range]
            var probe = clearIndex
            while probe < cleared.count, cleared[probe].location < run.end {
                let cut = cleared[probe]
                var next: [NSRange] = []
                for piece in pieces {
                    let hit = NSIntersectionRange(piece, cut)
                    if hit.length == 0 { next.append(piece); continue }
                    if hit.location > piece.location {
                        next.append(NSRange(location: piece.location,
                                            length: hit.location - piece.location))
                    }
                    if NSMaxRange(hit) < NSMaxRange(piece) {
                        next.append(NSRange(location: NSMaxRange(hit),
                                            length: NSMaxRange(piece) - NSMaxRange(hit)))
                    }
                }
                pieces = next
                probe += 1
            }
            for piece in pieces where piece.length > 0 {
                surviving.append(HighlightRun(range: piece, style: run.style))
            }
        }

        // Both sides are sorted and disjoint (the survivors keep the input's
        // order; `fresh` comes out of a painter in order), so this is a merge —
        // not a concatenate-and-sort, which would be O(n log n) per keystroke on
        // a list with one entry per token in the file.
        var result: [HighlightRun] = []
        result.reserveCapacity(surviving.count + fresh.count)
        var left = 0
        var right = 0
        while left < surviving.count || right < fresh.count {
            if right == fresh.count
                || (left < surviving.count && surviving[left].location <= fresh[right].location) {
                result.append(surviving[left])
                left += 1
            } else {
                result.append(fresh[right])
                right += 1
            }
        }
        return result
    }

    /// Materialise runs as an `NSAttributedString`.
    ///
    /// The editor does NOT do this — it paints the visible runs as temporary
    /// attributes. This exists for `SyntaxEngine.highlightImmediately`, which
    /// the tests and the benchmarks use to compare two passes attribute for
    /// attribute.
    static func attributedString(
        text: String,
        runs: [HighlightRun],
        isDark: Bool
    ) -> NSAttributedString {
        let output = NSMutableAttributedString(string: text)
        let length = output.length
        var attributesByStyle: [HighlightStyleID: [NSAttributedString.Key: Any]] = [:]
        output.beginEditing()
        for run in runs {
            guard run.length > 0, run.end <= length else { continue }
            let attrs: [NSAttributedString.Key: Any]
            if let cached = attributesByStyle[run.style] {
                attrs = cached
            } else {
                attrs = HighlightStyleTable.attributes(run.style, isDark: isDark)
                attributesByStyle[run.style] = attrs
            }
            guard !attrs.isEmpty else { continue }
            output.addAttributes(attrs, range: run.range)
        }
        output.endEditing()
        return output
    }
}
