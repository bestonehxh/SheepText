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
        guard !controller.matches.isEmpty else { return }
        let range = controller.matches[controller.currentIndex]
        onReplace(range, controller.replacement)
        recompute()
        if !controller.matches.isEmpty {
            // After replacement the indices shift; keep pointer at the
            // same position if possible.
            controller.currentIndex = min(controller.currentIndex, controller.matches.count - 1)
            onNavigate(controller.matches[controller.currentIndex])
        }
    }

    private func replaceAll() {
        guard !controller.matches.isEmpty, !controller.matchesTruncated else { return }
        onReplaceAll(controller.matches, controller.replacement)
        recompute()
    }

    // MARK: - Match computation

    /// Coalesce keystrokes into one match pass.
    private func scheduleRecompute() {
        controller.pendingRecompute?.cancel()
        let item = DispatchWorkItem { recompute() }
        controller.pendingRecompute = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: item)
    }

    private func recompute() {
        controller.pendingRecompute?.cancel()
        controller.pendingRecompute = nil
        controller.errorMessage = nil
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
            result = try computeMatches(in: text, pattern: controller.query)
        } catch {
            controller.errorMessage = "Invalid regex"
            return
        }
        controller.matches = result.ranges
        controller.matchesTruncated = result.truncated
        if !result.ranges.isEmpty {
            onNavigate(result.ranges[0])
            postCurrentHighlight()
        } else {
            NotificationCenter.default.post(name: .findBarClearHighlights, object: nil)
        }
    }

    private func computeMatches(in text: String, pattern: String) throws -> (ranges: [NSRange], truncated: Bool) {
        let fullRange = NSRange(location: 0, length: (text as NSString).length)

        var regexPattern = controller.useRegex ? pattern : NSRegularExpression.escapedPattern(for: pattern)
        if controller.wholeWord {
            regexPattern = #"\b"# + regexPattern + #"\b"#
        }
        var options: NSRegularExpression.Options = []
        if !controller.caseSensitive { options.insert(.caseInsensitive) }

        let regex = try NSRegularExpression(pattern: regexPattern, options: options)
        // The cap used to apply only in large-file mode. A two-character query in an
        // ordinary ~1 MB file can still match six figures of ranges, all of them held
        // as NSRange and shipped through a notification; past the cap the count is
        // meaningless to a human anyway and Replace All is disabled (matchesTruncated).
        let limit = LargeFilePolicy.largeFindMatchLimit
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
