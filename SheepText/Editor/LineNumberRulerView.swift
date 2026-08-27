//
//  LineNumberRulerView.swift
//  Lightweight line-number gutter view (not NSRulerView).
//

import AppKit

private extension NSColor {
    static let editorBackground = NSColor(name: nil) { appearance in
        NSColor.bestTextEditorBackground(for: appearance)
    }
}

nonisolated enum CompareLineStyle: Sendable {
    case same
    case changedLeft
    case changedRight
    case removed
    case added
    case moved
    case filler
}

nonisolated struct CompareLineInfo: Sendable {
    var realLineNumber: Int?
    var isFiller: Bool
    var gutterSymbol: String
    var style: CompareLineStyle
    var mappedLineNumber: Int?
    /// Character-level highlight ranges relative to the line's start.
    var charHighlights: [NSRange]

    @MainActor var symbolColor: NSColor {
        switch style {
        case .same, .filler: return .clear
        case .changedLeft, .changedRight: return .editorModifiedAmber
        case .removed: return .bestTextDanger
        case .added: return .bestTextSuccess
        case .moved: return .bestTextMoved
        }
    }

    @MainActor var lineBackground: NSColor? {
        switch style {
        case .same: return nil
        case .changedLeft: return .bestTextCompareChangedLeft
        case .changedRight: return .bestTextCompareChangedRight
        case .removed: return .bestTextCompareRemoved
        case .added: return .bestTextCompareAdded
        case .moved: return .bestTextCompareMoved
        case .filler: return .bestTextCompareFiller
        }
    }
}

final class LineNumberRulerView: NSView {

    /// Starting width, and the floor the gutter never shrinks below.
    static let gutterWidth: CGFloat = 44
    // Right-side arrow zone; numbers are right-aligned just to the left of it.
    private static let arrowZoneWidth: CGFloat = 12
    /// Furniture to the left of the number: the 3 px change bar, the change
    /// symbol at x=5 and the edited-line marker at x=14.
    private static let compareLeftZone: CGFloat = 21
    private static let normalLeftZone: CGFloat = 6
    private static let numberGap: CGFloat = 4

    /// Set by EditorView so the gutter can widen itself when the line numbers
    /// need more room. Without this the width was pinned at 44 pt, which fits
    /// two digits — a three-digit number was clamped rightwards and ran under
    /// the transfer arrow.
    weak var widthConstraint: NSLayoutConstraint?

    /// High-water mark of the largest line number drawn. Monotonic within a
    /// document so the gutter does not twitch narrower and wider as you scroll.
    private var widestNumberSeen: Int = 0

    private weak var scrollView: NSScrollView?
    private weak var textView: NSTextView?

    /// Set by EditorView after makeNSView so the gutter can trigger folds.
    weak var foldingManager: FoldingManager?

    /// When set, the gutter renders compare symbols + real line numbers instead of sequential ones.
    var compareLineInfos: [CompareLineInfo]? = nil {
        didSet {
            // In compare mode every real line number is known up front, so the
            // gutter can be sized correctly straight away instead of growing as
            // the user scrolls.
            widestNumberSeen = compareLineInfos?.compactMap(\.realLineNumber).max() ?? 0
        }
    }

    /// Transfer-arrow direction for this compare pane: true = left pane (pushes right
    /// with →), false = right pane (pushes left with ←), nil = no arrows.
    var compareTransferPointsRight: Bool? = nil

    /// Invoked with the display-row range of a diff block when its transfer arrow is clicked.
    var onCompareBlockTransfer: ((NSRange) -> Void)? = nil

    /// Clickable arrow rects rebuilt on every draw pass (visible rows only).
    private var transferArrowHitRects: [(rect: NSRect, rows: NSRange)] = []

    /// 1-based line number where the cursor currently sits.
    private var currentLine: Int = 1

    /// Modified-since-save indicators for normal mode: line number → bar color.
    var savedLineMarks: [Int: NSColor] = [:] {
        didSet { needsDisplay = true }
    }

    /// Display line numbers (1-based) the user has personally edited this session in compare mode.
    var editedLines: Set<Int> = [] {
        didSet { needsDisplay = true }
    }


    private var boundsObserver: NSObjectProtocol?
    private var textDidChangeObserver: NSObjectProtocol?
    private var selectionObserver: NSObjectProtocol?

    // MARK: - Foldable-marker cache
    //
    // `foldableLines` scans the whole document for brace pairs. `draw()` needs it
    // for the chevrons, and draw() runs on every scroll tick and every keystroke,
    // so recomputing it per frame made scrolling a large source file crawl. The
    // marker sets only change when the text or the fold set changes, so cache them
    // and key the cache on everything that can invalidate it.

    private struct FoldMarkerCache {
        let documentID: Document.ID?
        let textLength: Int
        let regionCount: Int
        let changeStamp: Int
        let foldable: Set<Int>
        let folded: Set<Int>
    }

    private var foldMarkerCache: FoldMarkerCache?

    /// Bumped on every text change. Length alone is not enough of a key: typing
    /// over a one-character selection leaves the document exactly as long as it
    /// was, and the brace structure can still have changed.
    private var textChangeStamp: Int = 0

    private var accentColor: NSColor {
        .bestTextAccent
    }

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.scrollView = scrollView
        self.textView = textView
        super.init(frame: .zero)

        wantsLayer = true

        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addMainActorObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.needsDisplay = true
        }

        textDidChangeObserver = NotificationCenter.default.addMainActorObserver(
            forName: NSText.didChangeNotification,
            object: textView,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.textChangeStamp &+= 1
            self.needsDisplay = true
        }

        selectionObserver = NotificationCenter.default.addMainActorObserver(
            forName: EditorTextView.selectionDidChange,
            object: textView,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            if let line = note.userInfo?["line"] as? Int {
                self.currentLine = line
            }
            self.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    isolated deinit {
        for observer in [boundsObserver, textDidChangeObserver, selectionObserver] {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    override var isFlipped: Bool { true }

    private func requiredWidth(font: NSFont) -> CGFloat {
        let digits = max(2, String(max(widestNumberSeen, 1)).count)
        let sample = String(repeating: "8", count: digits) as NSString
        let numberWidth = sample.size(withAttributes: [.font: font]).width
        let left = compareLineInfos != nil ? Self.compareLeftZone : Self.normalLeftZone
        return max(Self.gutterWidth,
                   ceil(left + numberWidth + Self.numberGap + Self.arrowZoneWidth))
    }

    /// The width the gutter needs right now.
    ///
    /// Anything that sets the width constraint must ask for this rather than
    /// hard-coding the base width. `updateNSView` runs on every SwiftUI update —
    /// i.e. on every keystroke — and resetting the constraint to 44 there made
    /// it fight this view's self-sizing: the gutter flipped between the two
    /// widths every frame, which shook the line numbers and the text beside them
    /// left and right as you typed.
    func preferredWidth() -> CGFloat {
        let font = textView?.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        return requiredWidth(font: font)
    }

    /// Never mutates layout inside the draw pass — that re-enters drawing.
    private func applyRequiredWidth(font: NSFont) {
        let width = requiredWidth(font: font)
        guard let widthConstraint, widthConstraint.constant > 0,
              abs(widthConstraint.constant - width) > 0.5 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let c = self.widthConstraint, c.constant > 0,
                  abs(c.constant - width) > 0.5 else { return }
            c.constant = width
            self.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard
            let textView,
            let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer,
            let textStorage   = textView.textStorage
        else { return }

        NSColor.editorBackground.setFill()
        bounds.fill()

        transferArrowHitRects.removeAll()

        let baseFont = textView.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let numberFont = baseFont
        let activeNumberFont = baseFont
        let accentColor = accentColor
        let dimAttrs: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let activeAttrs: [NSAttributedString.Key: Any] = [
            .font: activeNumberFont,
            .foregroundColor: accentColor
        ]

        let visibleRect    = textView.visibleRect
        let textInsetY     = textView.textContainerInset.height
        let fullText       = textStorage.string as NSString
        let visibleGlyphs  = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        // DiffLayoutManager overrides this to include its optical baseline drop, so
        // querying it gives the exact baseline the editor glyphs sit on. Numbers drawn
        // relative to this value are guaranteed level with the text on every row.
        let textBaselineOffset = layoutManager.defaultBaselineOffset(for: baseFont)

        if visibleGlyphs.length == 0 { return }

        let visibleChars = layoutManager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        let isLargeFileMode = (textView as? EditorTextView)?.document?.isLargeFileModeActive == true

        // Line number of the first visible row.
        //
        // This used to run enumerateSubstrings(.byLines) over the whole prefix on
        // every redraw — i.e. on every scroll tick and every keystroke — so
        // scrolling to the end of a 1 MB file re-enumerated the entire document
        // per frame. TextLineIndex counts newlines through chunked getCharacters
        // instead, allocating nothing.
        //
        // It also fixes an off-by-one the old call had: with word wrap on,
        // visibleChars.location can land in the MIDDLE of a logical line (the top
        // visible fragment being a wrapped continuation). enumerateSubstrings
        // counts that partial line as a whole one, so the gutter numbered every
        // row one too high until the next unwrapped row scrolled in. Counting
        // newlines strictly before the offset gives the line that CONTAINS it,
        // which is the row the enumeration below starts on.
        var displayLineNumber = TextLineIndex.lineNumber(in: fullText, at: visibleChars.location)

        let infos     = compareLineInfos
        let markers   = (infos == nil && !isLargeFileMode)
            ? foldMarkers(displayText: fullText,
                          documentID: (textView as? EditorTextView)?.document?.id)
            : (foldable: Set<Int>(), folded: Set<Int>())
        let foldable  = markers.foldable
        let folded    = markers.folded
        // savedLineMarks is keyed by FULL-text line numbers, but this loop counts
        // display rows — a collapsed fold hides lines and pushes every mark below it
        // onto the wrong row. These spans translate between the two.
        let foldSpans = (infos == nil && !savedLineMarks.isEmpty)
            ? foldLineSpans(displayText: fullText)
            : []
        var lastLineStart = -1

        layoutManager.enumerateLineFragments(forGlyphRange: visibleGlyphs) { lineRect, _, _, glyphRange, _ in
            guard glyphRange.length > 0 else { return }

            let charIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            let lineRange = fullText.lineRange(for: NSRange(location: charIndex, length: 0))
            guard lineRange.location != lastLineStart else { return }
            lastLineStart = lineRange.location

            let y = lineRect.minY + textInsetY - visibleRect.origin.y
            let rowHeight = lineRect.height

            if let infos {
                // ── Compare mode gutter ──────────────────────────────────────
                let idx = displayLineNumber - 1
                guard idx >= 0 && idx < infos.count else { displayLineNumber += 1; return }
                let info = infos[idx]

                // Row background tint (mirrors line background color).
                if let bg = info.lineBackground {
                    bg.withAlphaComponent(0.35).setFill()
                    NSRect(x: 0, y: y, width: self.bounds.width, height: rowHeight).fill()
                }

                // Transfer arrow on the first row of each diff block (right-edge zone).
                if Self.isDiffRow(info),
                   idx == 0 || !Self.isDiffRow(infos[idx - 1]),
                   let pointsRight = self.compareTransferPointsRight,
                   self.onCompareBlockTransfer != nil {
                    let glyph = (pointsRight ? "→" : "←") as NSString
                    let arrowAttrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                        .foregroundColor: self.accentColor
                    ]
                    let aSize = glyph.size(withAttributes: arrowAttrs)
                    let zone = NSRect(x: self.bounds.width - Self.arrowZoneWidth, y: y,
                                      width: Self.arrowZoneWidth, height: rowHeight)
                    glyph.draw(
                        at: NSPoint(x: zone.midX - aSize.width / 2,
                                    y: y + max(0, (rowHeight - aSize.height) / 2)),
                        withAttributes: arrowAttrs
                    )
                    self.transferArrowHitRects.append(
                        (rect: zone, rows: Self.diffBlockRange(containing: idx, in: infos))
                    )
                }

                if !info.isFiller {
                    // Left-edge change indicator bar — 3 px wide, full row height.
                    // Gives an immediate, color-coded visual cue (VS Code style).
                    let barColor = info.symbolColor
                    if barColor != .clear {
                        barColor.setFill()
                        NSRect(x: 0, y: y, width: 3, height: rowHeight).fill()
                    }

                    // Symbol (−/+/~/↕) immediately right of the bar.
                    if !info.gutterSymbol.isEmpty {
                        let symAttrs: [NSAttributedString.Key: Any] = [
                            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .bold),
                            .foregroundColor: info.symbolColor
                        ]
                        let sym = info.gutterSymbol as NSString
                        let symSize = sym.size(withAttributes: symAttrs)
                        sym.draw(
                            at: NSPoint(x: 5, y: y + max(0, (rowHeight - symSize.height) / 2)),
                            withAttributes: symAttrs
                        )
                    }

                    // * marker for lines the user personally edited this session.
                    if self.editedLines.contains(displayLineNumber) {
                        let starAttrs: [NSAttributedString.Key: Any] = [
                            .font: NSFont.monospacedSystemFont(ofSize: 8, weight: .regular),
                            .foregroundColor: NSColor.tertiaryLabelColor
                        ]
                        let star = "*" as NSString
                        let starSize = star.size(withAttributes: starAttrs)
                        star.draw(
                            at: NSPoint(x: 14, y: y + max(0, (rowHeight - starSize.height) / 2)),
                            withAttributes: starAttrs
                        )
                    }

                    // Real line number, right-aligned just before the right edge.
                    //
                    // Deliberately NOT tinted with the change colour. It used to
                    // be, and on a changed row that colour is systemYellow over
                    // the row's pale tint — the number was unreadable. The change
                    // type is already carried by three other things: the 3 px
                    // bar, the symbol, and the row background. The number only
                    // needs to say "this row changed", which the step from
                    // tertiary to secondary label does while staying legible in
                    // both light and dark appearance.
                    if let real = info.realLineNumber {
                        let numberColor: NSColor = info.gutterSymbol.isEmpty
                            ? NSColor.tertiaryLabelColor
                            : NSColor.secondaryLabelColor
                        let label = "\(real)" as NSString
                        let lAttrs: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: numberColor]
                        let lSize = label.size(withAttributes: lAttrs)
                        // Right-align just before the transfer-arrow zone.
                        let lx = self.bounds.width - Self.arrowZoneWidth - lSize.width - 2
                        self.drawLineNumberLabel(
                            String(real),
                            x: max(15, lx),
                            y: y,
                            baselineOffset: textBaselineOffset,
                            font: numberFont,
                            color: numberColor
                        )
                    }
                }

            } else {
                // ── Normal mode gutter ───────────────────────────────────────
                if displayLineNumber > self.widestNumberSeen {
                    self.widestNumberSeen = displayLineNumber
                }
                let isCurrent  = displayLineNumber == self.currentLine
                let isFolded   = folded.contains(displayLineNumber)
                let isFoldable = foldable.contains(displayLineNumber)
                let numAttrs   = isCurrent ? activeAttrs : dimAttrs

                if isCurrent {
                    let strip = NSRect(x: 0, y: y, width: self.bounds.width, height: rowHeight)
                    accentColor.withAlphaComponent(0.12).setFill()
                    strip.fill()
                }

                if let markColor = self.savedMarkColor(displayLine: displayLineNumber,
                                                       foldSpans: foldSpans) {
                    markColor.setFill()
                    NSRect(x: 0, y: y, width: 3, height: rowHeight).fill()
                }

                let label = "\(displayLineNumber)" as NSString
                let lSize = label.size(withAttributes: numAttrs)
                let lx    = self.bounds.width - Self.arrowZoneWidth - lSize.width - 2
                self.drawLineNumberLabel(
                    "\(displayLineNumber)",
                    x: max(0, lx),
                    y: y,
                    baselineOffset: textBaselineOffset,
                    font: isCurrent ? activeNumberFont : numberFont,
                    color: isCurrent ? accentColor : NSColor.tertiaryLabelColor
                )

                if isFolded || isFoldable {
                    let cx = self.bounds.width - Self.arrowZoneWidth / 2
                    let cy = y + rowHeight / 2
                    let s: CGFloat = 4.0
                    let chevron = NSBezierPath()
                    if isFolded {
                        chevron.move(to: NSPoint(x: cx - s * 0.45, y: cy - s))
                        chevron.line(to: NSPoint(x: cx + s * 0.55, y: cy))
                        chevron.line(to: NSPoint(x: cx - s * 0.45, y: cy + s))
                    } else {
                        chevron.move(to: NSPoint(x: cx - s, y: cy - s * 0.35))
                        chevron.line(to: NSPoint(x: cx,     y: cy + s * 0.65))
                        chevron.line(to: NSPoint(x: cx + s, y: cy - s * 0.35))
                    }
                    chevron.lineWidth = isFolded ? 1.9 : 1.5
                    chevron.lineCapStyle = .round
                    chevron.lineJoinStyle = .round
                    (isFolded ? NSColor.bestTextSuccess : NSColor.tertiaryLabelColor).setStroke()
                    chevron.stroke()
                }
            }

            displayLineNumber += 1
        }

        if infos == nil,
           fullText.length > 0 {
            let lastCharacter = fullText.character(at: fullText.length - 1)
            if lastCharacter == 0x0A || lastCharacter == 0x0D {
                let extraLine = layoutManager.extraLineFragmentRect
                let y = extraLine.minY + textInsetY - visibleRect.origin.y
                let rowHeight = extraLine.height
                if !extraLine.isEmpty,
                   rowHeight > 0,
                   y + rowHeight >= dirtyRect.minY,
                   y <= dirtyRect.maxY {
                    let isCurrent = displayLineNumber == self.currentLine
                    let numAttrs = isCurrent ? activeAttrs : dimAttrs

                    if isCurrent {
                        let strip = NSRect(x: 0, y: y, width: self.bounds.width, height: rowHeight)
                        accentColor.withAlphaComponent(0.12).setFill()
                        strip.fill()
                    }

                    let label = "\(displayLineNumber)" as NSString
                    let lSize = label.size(withAttributes: numAttrs)
                    let lx = self.bounds.width - Self.arrowZoneWidth - lSize.width - 2
                    drawLineNumberLabel(
                        "\(displayLineNumber)",
                        x: max(0, lx),
                        y: y,
                        baselineOffset: textBaselineOffset,
                        font: isCurrent ? activeNumberFont : numberFont,
                        color: isCurrent ? accentColor : NSColor.tertiaryLabelColor
                    )
                }
            }
        }

        applyRequiredWidth(font: numberFont)
    }

    /// Draws the label so its baseline coincides exactly with the editor text baseline
    /// for the same row. `baselineOffset` is the layout manager's baseline offset for
    /// the editor font (DiffLayoutManager includes its optical drop in that value), and
    /// `y` is the row's top edge in gutter coordinates. In a flipped view NSString
    /// draws with its origin at the TOP of the text, so the top edge sits one ascender
    /// above the baseline.
    private func drawLineNumberLabel(
        _ label: String,
        x: CGFloat,
        y: CGFloat,
        baselineOffset: CGFloat,
        font: NSFont,
        color: NSColor
    ) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let drawY = y + baselineOffset - font.ascender
        (label as NSString).draw(at: NSPoint(x: x, y: drawY), withAttributes: attrs)
    }

    /// Fold chevron markers for the current text, recomputed only when something
    /// that affects them has changed. `documentID` is part of the key because a
    /// tab switch replaces the text through `textView.string = …`, which does not
    /// post a text-change notification — without it, switching between two files
    /// of the same length would keep drawing the previous file's chevrons.
    private func foldMarkers(
        displayText: NSString,
        documentID: Document.ID?
    ) -> (foldable: Set<Int>, folded: Set<Int>) {
        guard let foldingManager else { return ([], []) }

        if let cached = foldMarkerCache,
           cached.documentID == documentID,
           cached.textLength == displayText.length,
           cached.regionCount == foldingManager.regions.count,
           cached.changeStamp == textChangeStamp {
            return (cached.foldable, cached.folded)
        }

        let foldable = foldingManager.foldableLines(displayText: displayText)
        let folded   = foldingManager.foldedLines(displayText: displayText)
        foldMarkerCache = FoldMarkerCache(
            documentID: documentID,
            textLength: displayText.length,
            regionCount: foldingManager.regions.count,
            changeStamp: textChangeStamp,
            foldable: foldable,
            folded: folded
        )
        return (foldable, folded)
    }

    // MARK: - Compare block transfer

    /// A display row belongs to a diff block if it is a filler (absence on this side)
    /// or carries a change symbol (+/−/~/↕). Runs of such rows form one block.
    private static func isDiffRow(_ info: CompareLineInfo) -> Bool {
        info.isFiller || !info.gutterSymbol.isEmpty
    }

    /// Expands from `idx` in both directions to the maximal run of diff rows.
    private static func diffBlockRange(containing idx: Int, in infos: [CompareLineInfo]) -> NSRange {
        var start = idx
        while start > 0, isDiffRow(infos[start - 1]) { start -= 1 }
        var end = idx
        while end + 1 < infos.count, isDiffRow(infos[end + 1]) { end += 1 }
        return NSRange(location: start, length: end - start + 1)
    }

    // MARK: - Saved-mark ↔ fold mapping

    /// One entry per collapsed fold: the display row it sits on, and how many
    /// full-text lines it swallows.
    private func foldLineSpans(displayText: NSString) -> [(displayLine: Int, hidden: Int)] {
        guard let foldingManager, !foldingManager.regions.isEmpty else { return [] }
        return foldingManager.regions.compactMap { region in
            guard region.displayLocation >= 0, region.displayLocation < displayText.length
            else { return nil }
            let hidden = region.hiddenLineCount
            guard hidden > 0 else { return nil }
            return (TextLineIndex.lineNumber(in: displayText, at: region.displayLocation), hidden)
        }
        .sorted { $0.displayLine < $1.displayLine }
    }

    /// Modified-since-save colour for a display row, accounting for collapsed folds.
    /// A fold whose hidden lines contain marks shows the strongest of them, so a
    /// change never disappears just because it was folded away.
    private func savedMarkColor(displayLine: Int,
                                foldSpans: [(displayLine: Int, hidden: Int)]) -> NSColor? {
        guard !savedLineMarks.isEmpty else { return nil }
        guard !foldSpans.isEmpty else { return savedLineMarks[displayLine] }

        var offset = 0
        var hiddenHere = 0
        for span in foldSpans {
            if span.displayLine < displayLine {
                offset += span.hidden
            } else if span.displayLine == displayLine {
                hiddenHere += span.hidden
            }
        }
        let fullLine = displayLine + offset
        if let direct = savedLineMarks[fullLine] { return direct }
        guard hiddenHere > 0 else { return nil }

        var found: NSColor?
        for line in (fullLine + 1)...(fullLine + hiddenHere) {
            guard let color = savedLineMarks[line] else { continue }
            // Amber (modified) outranks green (added) for a summarised row.
            if color == NSColor.editorModifiedAmber { return color }
            found = color
        }
        return found
    }

    // MARK: - Fold click handling

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Compare mode: transfer-arrow clicks take priority (folding is disabled there).
        if compareLineInfos != nil {
            if let hit = transferArrowHitRects.first(where: { $0.rect.contains(point) }) {
                onCompareBlockTransfer?(hit.rows)
            }
            return
        }

        guard let tv = textView,
              let storage = tv.textStorage,
              let line = lineNumber(atGutterY: point.y, in: tv)
        else {
            super.mouseDown(with: event)
            return
        }

        let clickedArrowZone = point.x >= (bounds.width - Self.arrowZoneWidth)

        if clickedArrowZone,
           let fm = foldingManager,
           (tv as? EditorTextView)?.document?.isLargeFileModeActive != true {
            let displayText = storage.string as NSString
            let folded = fm.foldedLines(displayText: displayText)

            if folded.contains(line) {
                if let region = fm.regions.first(where: { r in
                    guard r.displayLocation >= 0 && r.displayLocation < displayText.length else { return false }
                    return TextLineIndex.lineNumber(in: displayText, at: r.displayLocation) == line
                }) {
                    fm.unfold(at: region.displayLocation, in: storage)
                    tv.discardUndoHistory()
                    tv.didChangeText()
                }
            } else if let range = fm.foldableRange(onLine: line, displayText: displayText) {
                fm.fold(range: range, in: storage)
                tv.discardUndoHistory()
                tv.didChangeText()
            }
        } else {
            if let loc = characterLocationForLineStart(line, in: storage.string as NSString) {
                let target = NSRange(location: loc, length: 0)
                tv.window?.makeFirstResponder(tv)
                tv.setSelectedRange(target)
                tv.scrollRangeToVisible(target)
                tv.needsDisplay = true
                tv.displayIfNeeded()
            }
        }

        needsDisplay = true
        tv.needsDisplay = true
    }

    private func lineNumber(atGutterY gutterY: CGFloat, in textView: NSTextView) -> Int? {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let textStorage = textView.textStorage
        else { return nil }

        // Map gutter Y into the text view's content coordinates.
        let yInText = gutterY + textView.visibleRect.origin.y - textView.textContainerInset.height
        let xInText = textView.textContainerInset.width + 1
        let point = NSPoint(x: xInText, y: max(0, yInText))

        let glyphIndex = layoutManager.glyphIndex(for: point, in: textContainer)
        guard layoutManager.numberOfGlyphs > 0 else { return 1 }

        let safeGlyph = min(glyphIndex, max(0, layoutManager.numberOfGlyphs - 1))
        let charIndex = layoutManager.characterIndexForGlyph(at: safeGlyph)
        let displayText = textStorage.string as NSString
        let safeChar = min(charIndex, displayText.length)

        return TextLineIndex.lineNumber(in: displayText, at: safeChar)
    }

    private func characterLocationForLineStart(_ line: Int, in text: NSString) -> Int? {
        guard line >= 1 else { return nil }
        if line == 1 { return 0 }

        // Chunked scan rather than one ObjC message per UTF-16 unit. Only runs on
        // a gutter click, but there is no reason to hand-roll the slow version
        // when TextLineIndex already does this properly.
        return TextLineIndex.lineStart(of: line, in: text)
    }
}
