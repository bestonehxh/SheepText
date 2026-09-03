//
//  FindReplaceBar.swift
//  The find-and-replace bar that slides down from the top of the editor.
//
//  Triggered by notifications (.findBarShow, .findBarShowWithReplace) so
//  menu items, keybindings, and plugins can all open it without coupling.
//
//  Matching strategy:
//    - Plain text search by default (fast, honors options)
//    - Regex when the `.regex` option is on; invalid regex shows an inline error
//    - Case-insensitive by default, toggle for case-sensitive
//    - Whole-word matching inserts \b boundaries in the pattern
//
//  Highlighting:
//    - All matches get a yellow background
//    - The "current" match gets an orange background
//    - Attributes live in a temporary attribute layer on the NSTextStorage
//      so they can be cleared cleanly on close
//

import SwiftUI
import AppKit

// MARK: - Matching

/// The find bar's matching, as pure functions over text.
///
/// It lives outside the view for two reasons. It is the part with the sharp
/// edge — `stillMatching` is what stands between a stale range and a corrupted
/// document — and it is the part worth testing without a window.
nonisolated enum FindMatching {

    static func regex(pattern: String,
                      useRegex: Bool,
                      wholeWord: Bool,
                      caseSensitive: Bool) throws -> NSRegularExpression {
        var regexPattern = useRegex ? pattern : NSRegularExpression.escapedPattern(for: pattern)
        if wholeWord {
            regexPattern = #"\b"# + regexPattern + #"\b"#
        }
        var options: NSRegularExpression.Options = []
        if !caseSensitive { options.insert(.caseInsensitive) }
        return try NSRegularExpression(pattern: regexPattern, options: options)
    }

    /// All matches, capped at `limit`.
    ///
    /// The cap used to apply only in large-file mode. A two-character query in an
    /// ordinary ~1 MB file can still match six figures of ranges, all of them held
    /// as NSRange and shipped through a notification; past the cap the count is
    /// meaningless to a human anyway and Replace All is disabled (matchesTruncated).
    static func matches(in text: String,
                        regex: NSRegularExpression,
                        limit: Int) -> (ranges: [NSRange], truncated: Bool) {
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        var ranges: [NSRange] = []
        var truncated = false
        regex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, stop in
            guard let range = match?.range, range.location != NSNotFound else { return }
            if ranges.count >= limit {
                truncated = true
                stop.pointee = true
                return
            }
            ranges.append(range)
        }
        return (ranges, truncated)
    }

    /// The subset of `ranges` that still describes a match of `regex` in `text`.
    ///
    /// Match ranges were computed once and then applied blind. Anything that
    /// edited the document in between — the user typing, a plugin, a compare
    /// transfer, an external reload — moved the text out from under them, and
    /// Replace wrote the replacement over whatever now occupied those offsets.
    /// A range survives only if the text at exactly those offsets is exactly a
    /// match: `.anchored` pins the start, and the length has to come back equal
    /// so a longer or shorter match at the same place is rejected too.
    static func stillMatching(_ ranges: [NSRange],
                              in text: NSString,
                              regex: NSRegularExpression) -> [NSRange] {
        let length = text.length
        return ranges.filter { range in
            guard range.location >= 0, range.length > 0, NSMaxRange(range) <= length else { return false }
            guard let found = regex.firstMatch(in: text as String, options: [.anchored], range: range)
            else { return false }
            return found.range == range
        }
    }
}

// MARK: - Controller

@Observable
@MainActor
final class FindReplaceController {
    var isVisible: Bool = false
    var showReplace: Bool = false
    var query: String = ""
    var replacement: String = ""

    var caseSensitive: Bool = false
    var wholeWord: Bool = false
    var useRegex: Bool = false

    /// Flat list of match ranges in the active document. Computed on every
    /// query/option change.
    var matches: [NSRange] = []
    var currentIndex: Int = 0
    var errorMessage: String?
    var matchesTruncated: Bool = false

    /// Pending debounced recompute. Typing runs a regex over the whole document,
    /// on the main thread — once per pause is enough, once per keystroke is not
    /// affordable on a large file.
    @ObservationIgnored var pendingRecompute: DispatchWorkItem?

    func show(withReplace: Bool) {
        showReplace = withReplace
        isVisible = true
    }

    func hide() {
        pendingRecompute?.cancel()
        pendingRecompute = nil
        isVisible = false
        matches = []
        currentIndex = 0
        errorMessage = nil
        matchesTruncated = false
        NotificationCenter.default.post(name: .findBarClearHighlights, object: nil)
    }
}

// MARK: - View

struct FindReplaceBar: View {

    @Environment(DocumentStore.self) private var documents
    @Bindable var controller: FindReplaceController
    /// Callback invoked when the user clicks Next/Prev or types — the host
    /// (EditorView) uses it to scroll and highlight in the text view.
    let onNavigate: (NSRange) -> Void
    /// Callback invoked to apply a replacement to the underlying textStorage.
    let onReplace:   (NSRange, String) -> Void
    /// Callback invoked to apply one replacement to EVERY match at once. Kept
    /// separate from `onReplace` so Replace All is a single edit and a single undo
    /// step rather than one of each per match.
    let onReplaceAll: ([NSRange], String) -> Void
    /// Access to the text view's string, for recomputing matches on edit.
    let currentText: () -> String

    @FocusState private var focused: Field?
    private enum Field { case find, replace }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Find", text: $controller.query)
                        .textFieldStyle(.plain)
                        .focused($focused, equals: .find)
                        .onSubmit { goToNext() }
                        .onChange(of: controller.query) { _, _ in scheduleRecompute() }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .bestTextInputBackground)))
                .frame(maxWidth: 280)

                // Options toggles
                HStack(spacing: 2) {
                    OptionToggle(symbol: "textformat.size", help: "Case Sensitive",
                                 isOn: $controller.caseSensitive)
                        .onChange(of: controller.caseSensitive)   { _, _ in recompute() }
                    OptionToggle(symbol: "text.word.spacing", help: "Whole Word",
                                 isOn: $controller.wholeWord)
                        .onChange(of: controller.wholeWord)       { _, _ in recompute() }
                    OptionToggle(symbol: "asterisk", help: "Regular Expression",
                                 isOn: $controller.useRegex)
                        .onChange(of: controller.useRegex)        { _, _ in recompute() }
                }

                matchCountLabel

                // ── Navigation buttons ────────────────────────────────────────
                HStack(spacing: 6) {
                    Button("Prev", action: goToPrevious)
                        .disabled(controller.matches.isEmpty)
                        .help("Previous match (⌘⇧G)")

                    Button("Find", action: goToNext)
                        .disabled(controller.matches.isEmpty)
                        .help("Next match (⌘G)")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button(action: { controller.hide() }) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close (Esc)")
            }

            if controller.showReplace {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.turn.down.right")
                            .foregroundStyle(.secondary)
                        TextField("Replace", text: $controller.replacement)
                            .textFieldStyle(.plain)
                            .focused($focused, equals: .replace)
                            .onSubmit { replaceCurrent() }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(Color(nsColor: .bestTextInputBackground)))
                    .frame(maxWidth: 280)

                    Button("Replace") { replaceCurrent() }
                        .disabled(controller.matches.isEmpty)
                    Button("Replace All") { replaceAll() }
                        .disabled(controller.matches.isEmpty || controller.matchesTruncated)

                    Spacer()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .bestTextPanelBackground))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .bestTextBorder))
                .frame(height: 1)
        }
        .onAppear {
            recompute()
            focused = .find
        }
        .onReceive(NotificationCenter.default.publisher(for: .findBarNext)) { _ in
            if controller.isVisible { goToNext() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .findBarPrevious)) { _ in
            if controller.isVisible { goToPrevious() }
        }
        // The match list was computed on appear and on option/query changes and
        // then never again, so every edit to the document left it describing text
        // that had moved. The count went wrong, the highlights drifted, and
        // Replace applied a stale range. AppKit already posts this for every edit
        // that goes through the text view, so nothing in EditorView has to change.
        //
        // Filtered to EditorTextView on purpose: a plain NSTextField's field
        // editor posts the same notification, so typing in the find bar's OWN
        // query box would otherwise schedule a second, redundant pass.
        .onReceive(NotificationCenter.default.publisher(for: NSText.didChangeNotification)) { note in
            guard controller.isVisible, note.object is EditorTextView else { return }
            scheduleRefresh()
        }
    }

    // MARK: - Count label

    @ViewBuilder
    private var matchCountLabel: some View {
        if let err = controller.errorMessage {
            Text(err)
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .bestTextDanger))
        } else if !controller.query.isEmpty {
            if controller.matches.isEmpty {
                Text("No results")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text("\(controller.currentIndex + 1) of \(controller.matches.count)\(controller.matchesTruncated ? "+" : "")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    private func goToNext() {
        guard !controller.matches.isEmpty else { return }
        controller.currentIndex = (controller.currentIndex + 1) % controller.matches.count
        let range = controller.matches[controller.currentIndex]
        onNavigate(range)
        postCurrentHighlight()
    }

    private func goToPrevious() {
        guard !controller.matches.isEmpty else { return }
        controller.currentIndex = (controller.currentIndex - 1 + controller.matches.count) % controller.matches.count
        let range = controller.matches[controller.currentIndex]
        onNavigate(range)
        postCurrentHighlight()
    }

    private func postCurrentHighlight() {
        guard !controller.matches.isEmpty else {
            NotificationCenter.default.post(name: .findBarClearHighlights, object: nil)
            return
        }
        // Always send every match so grey pills appear for non-current matches.
        // findCurrentIdx in EditorTextView picks which one gets the pastel yellow.
        NotificationCenter.default.post(
            name: .findBarHighlightAll,
            object: nil,
            userInfo: [
                "ranges": highlightRangesForCurrentMode(),
                "currentIndex": documents.activeDocument?.isLargeFileModeActive == true ? 0 : controller.currentIndex
            ]
        )
    }

    private func highlightRangesForCurrentMode() -> [NSRange] {
        guard documents.activeDocument?.isLargeFileModeActive == true,
              controller.matches.indices.contains(controller.currentIndex)
        else { return controller.matches }
        return [controller.matches[controller.currentIndex]]
    }

    private func replaceCurrent() {
        guard controller.matches.indices.contains(controller.currentIndex) else { return }
        let range = controller.matches[controller.currentIndex]
        // Verify against the document as it is NOW. `replaceOccurrences` only
        // bounds-checks, so a range left over from before an edit would happily
        // overwrite whatever moved into those offsets.
        guard verified([range]).count == 1 else {
            recompute(navigating: false)
            return
        }
        onReplace(range, controller.replacement)
        recompute(navigating: false)
        if !controller.matches.isEmpty {
            // After replacement the indices shift; keep pointer at the
            // same position if possible.
            controller.currentIndex = min(controller.currentIndex, controller.matches.count - 1)
            onNavigate(controller.matches[controller.currentIndex])
        }
    }

    private func replaceAll() {
        guard !controller.matches.isEmpty, !controller.matchesTruncated else { return }
        let survivors = verified(controller.matches)
        guard !survivors.isEmpty else {
            recompute(navigating: false)
            return
        }
        onReplaceAll(survivors, controller.replacement)
        recompute(navigating: false)
    }

    /// The ranges that still match the query in the document's current text.
    private func verified(_ ranges: [NSRange]) -> [NSRange] {
        guard !controller.query.isEmpty,
              let re = try? FindMatching.regex(pattern: controller.query,
                                               useRegex: controller.useRegex,
                                               wholeWord: controller.wholeWord,
                                               caseSensitive: controller.caseSensitive)
        else { return [] }
        return FindMatching.stillMatching(ranges, in: currentText() as NSString, regex: re)
    }

    // MARK: - Match computation

    /// Coalesce keystrokes into one match pass.
    private func scheduleRecompute() {
        controller.pendingRecompute?.cancel()
        let item = DispatchWorkItem { recompute() }
        controller.pendingRecompute = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: item)
    }

    /// Same coalescing, for edits to the document rather than to the query.
    /// Never navigates: the user is typing in the editor, and yanking the caret
    /// to match #1 on every keystroke would make the find bar unusable.
    private func scheduleRefresh() {
        controller.pendingRecompute?.cancel()
        let item = DispatchWorkItem { recompute(navigating: false) }
        controller.pendingRecompute = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: item)
    }

    /// - Parameter navigating: whether to jump to (and select) the first match.
    ///   True for a fresh query, false when re-syncing after a document edit.
    private func recompute(navigating: Bool = true) {
        controller.pendingRecompute?.cancel()
        controller.pendingRecompute = nil
        controller.errorMessage = nil

        // Where the current match was, so a refresh after an edit can land on
        // the nearest match to it instead of snapping back to the top.
        let previousAnchor = controller.matches.indices.contains(controller.currentIndex)
            ? controller.matches[controller.currentIndex].location
            : 0

        controller.matches = []
        controller.currentIndex = 0
        controller.matchesTruncated = false

        guard !controller.query.isEmpty else {
            NotificationCenter.default.post(name: .findBarClearHighlights, object: nil)
            return
        }

        let text = currentText()
        let result: (ranges: [NSRange], truncated: Bool)
        do {
            let regex = try FindMatching.regex(pattern: controller.query,
                                               useRegex: controller.useRegex,
                                               wholeWord: controller.wholeWord,
                                               caseSensitive: controller.caseSensitive)
            result = FindMatching.matches(in: text, regex: regex,
                                          limit: LargeFilePolicy.largeFindMatchLimit)
        } catch {
            controller.errorMessage = "Invalid regex"
            NotificationCenter.default.post(name: .findBarClearHighlights, object: nil)
            return
        }
        controller.matches = result.ranges
        controller.matchesTruncated = result.truncated

        guard !result.ranges.isEmpty else {
            NotificationCenter.default.post(name: .findBarClearHighlights, object: nil)
            return
        }

        if navigating {
            onNavigate(result.ranges[0])
        } else {
            controller.currentIndex = result.ranges.firstIndex { $0.location >= previousAnchor }
                ?? (result.ranges.count - 1)
        }
        postCurrentHighlight()
    }
}

// MARK: - Option toggle

private struct OptionToggle: View {
    let symbol: String
    let help: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isOn ? Color(nsColor: .bestTextAccent).opacity(0.3) : Color.clear)
                )
                .foregroundStyle(isOn ? Color(nsColor: .bestTextAccent) : Color.secondary)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
