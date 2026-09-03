//
//  StatusBarView.swift
//  Bottom bar showing cursor position, selection count, document size,
//  language, indentation, and encoding — Sublime Text-style.
//
//  Reads from the shared CursorState which the editor keeps up-to-date
//  on every selection change.
//

import SwiftUI
import AppKit
import NetworkHighlightKit

struct StatusBarView: View {

    @Environment(DocumentStore.self) private var documents
    @Environment(CursorState.self) private var cursor
    @Environment(AppPreferences.self) private var preferences

    /// Transient message posted by a plugin through `ui.showStatusMessage`.
    /// Sits on the left, where nothing else lives, so it never shifts the
    /// readouts on the right while it comes and goes.
    @State private var pluginMessage: String?
    @State private var pluginMessageTask: Task<Void, Never>?

    /// How long a plugin's status message stays up.
    private static let pluginMessageDuration: Duration = .seconds(4)

    var body: some View {
        HStack(spacing: 0) {
            if let pluginMessage {
                StatusItem(label: pluginMessage, color: Color(nsColor: .bestTextAccent))
                    .lineLimit(1)
                    .transition(.opacity)
            }
            Spacer()

            // Cursor position — primary info, always shown.
            StatusItem(label: "Ln \(cursor.line),  Col \(cursor.column)")

            // Selection count — accent-colored when active.
            if cursor.selectedCount > 0 {
                StatusDivider()
                StatusItem(
                    label: "\(cursor.selectedCount) selected",
                    color: Color(nsColor: .bestTextAccent)
                )
            }

            // Total character count.
            StatusDivider()
            StatusItem(label: "\(cursor.totalCount) chars", secondary: true)

            if let doc = documents.activeDocument {
                StatusDivider()
                StatusItem(
                    label: doc.isDirty ? "Unsaved" : "Saved",
                    color: Color(nsColor: doc.isDirty ? .bestTextDanger : .bestTextSuccess)
                )
                if preferences.autoSaveEnabled, doc.url != nil {
                    StatusDivider()
                    StatusItem(label: "Auto Save On", color: Color(nsColor: .bestTextAccent))
                }
                if doc.isDirty, let savedAt = doc.lastDraftSavedAt {
                    StatusDivider()
                    StatusItem(label: "Draft Saved \(timeLabel(savedAt))", secondary: true)
                } else if let savedAt = doc.lastAutoSavedAt {
                    StatusDivider()
                    StatusItem(label: "Auto Saved \(timeLabel(savedAt))", secondary: true)
                }
                if doc.isLargeFileModeActive {
                    StatusDivider()
                    StatusItem(label: "Large File Mode", color: Color(nsColor: .editorModifiedAmber))
                        .help(doc.largeFileModeDetail.map { "Large File Mode is active: \($0)" } ?? "Large File Mode is active.")
                }
                StatusDivider()
                lineEndingMenu(for: doc)
                StatusDivider()
                languageMenu(for: doc)
                if NetworkConfigLanguage.isNetworkConfig(doc.language) {
                    StatusDivider()
                    vendorMenu(for: doc)
                }
                StatusDivider()
                indentationMenu(for: doc)
                StatusDivider()
                encodingMenu(for: doc)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .frame(height: 22)
        .background { ChromeBackground(zone: .statusBar) }
        .overlay(alignment: .top) { Divider() }
        // U13: `ui.showStatusMessage` has been posting `.statusMessage` with
        // nobody listening — the bundled hello-world plugin calls it and nothing
        // appeared. This is that observer. The message inherits the bar's own
        // 11 pt monospace; the only thing it adds is the accent ink.
        .onReceive(NotificationCenter.default.publisher(for: .statusMessage)) { note in
            guard let message = note.userInfo?[UIBridge.statusMessageKey] as? String,
                  !message.isEmpty
            else { return }
            pluginMessageTask?.cancel()
            pluginMessage = message
            pluginMessageTask = Task {
                try? await Task.sleep(for: Self.pluginMessageDuration)
                guard !Task.isCancelled else { return }
                pluginMessage = nil
            }
        }
        .onDisappear { pluginMessageTask?.cancel() }
    }

    private func languageMenu(for document: Document) -> some View {
        let label = languageMenuLabel(for: document)

        return StatusMenu(label: label) {
            Button("Detect from Extension") {
                documents.resetLanguageFromFile(document.id)
            }

            Divider()

            // Device families first, by name, the way SheepTerm's picker lists
            // them: a network engineer opening this menu is choosing a vendor
            // far more often than a programming language.
            let isNetwork = NetworkConfigLanguage.isNetworkConfig(document.language)
            Section("Network Config") {
                ForEach(LanguageDetector.networkVendorMenuOrder) { vendor in
                    Toggle(
                        vendor.label,
                        isOn: choiceBinding(isNetwork && document.networkVendor == vendor) {
                            documents.setNetworkLanguage(document.id, vendor: vendor)
                        }
                    )
                }
                Toggle(
                    "Auto-detect Vendor",
                    isOn: choiceBinding(isNetwork && !document.networkVendorIsManual) {
                        documents.setNetworkLanguage(document.id, vendor: nil)
                    }
                )
            }

            Divider()

            ForEach(LanguageDetector.nonNetworkLanguages) { language in
                Toggle(
                    language.displayName,
                    isOn: choiceBinding(document.language == language.id) {
                        documents.setLanguage(document.id, language: language.id)
                    }
                )
            }
        }
    }

    private func languageMenuLabel(for document: Document) -> String {
        LanguageDetector.displayName(for: document.language)
    }

    /// The device family a `network_config` document is highlighted as.
    ///
    /// A second menu rather than eleven more entries in the language list: the
    /// language and the vendor are different questions, and the badge has to
    /// show the ANSWER — a detected `Huawei` next to `Network Config` is the
    /// whole point, and a language menu cannot show that.
    private func vendorMenu(for document: Document) -> some View {
        StatusMenu(label: document.networkVendor.badge, secondary: !document.networkVendorIsManual) {
            Button("Auto-detect from Content") {
                documents.resetNetworkVendorFromContent(document.id)
            }

            Divider()

            ForEach(LanguageDetector.networkVendorMenuOrder) { vendor in
                Toggle(
                    vendor.label,
                    isOn: choiceBinding(document.networkVendor == vendor) {
                        documents.setNetworkVendor(document.id, vendor: vendor)
                    }
                )
            }
        }
        .help(
            document.networkVendorIsManual
                ? "Device family: \(document.networkVendor.label) (chosen manually)"
                : "Device family: \(document.networkVendor.label) (detected)"
        )
    }

    private func textToolsMenu(for document: Document) -> some View {
        StatusMenu(label: "Text", secondary: true) {
            Button(document.wordWrap ? "Disable Word Wrap" : "Enable Word Wrap") {
                let next = !document.wordWrap
                documents.setWordWrap(document.id, isEnabled: next)
                EditorCommandTarget.focusedEditor?.applyDocumentVisualSettings()
            }

            Button(document.showsInvisibleCharacters ? "Hide Invisible Characters" : "Show Invisible Characters") {
                let next = !document.showsInvisibleCharacters
                documents.setShowsInvisibleCharacters(document.id, isEnabled: next)
                EditorCommandTarget.focusedEditor?.applyDocumentVisualSettings()
            }

            Button(document.autoTrimTrailingWhitespace ? "Disable Auto Trim on Save" : "Enable Auto Trim on Save") {
                documents.setAutoTrimTrailingWhitespace(
                    document.id,
                    isEnabled: !document.autoTrimTrailingWhitespace
                )
            }

            Divider()

            Button("Go to Line…") {
                promptGoToLine()
            }

            Button("Duplicate Line") {
                EditorCommandTarget.focusedEditor?.duplicateCurrentLines()
            }

            Button("Delete Line") {
                EditorCommandTarget.focusedEditor?.deleteCurrentLines()
            }

            Divider()

            Button("Trim Trailing Spaces") {
                EditorCommandTarget.focusedEditor?.trimTrailingWhitespace()
            }

            Button("Sort Lines") {
                EditorCommandTarget.focusedEditor?.sortSelectedLines()
            }

            Button("Remove Duplicate Lines") {
                EditorCommandTarget.focusedEditor?.removeDuplicateSelectedLines()
            }

            Button("Convert MAC Address Format") {
                EditorCommandTarget.focusedEditor?.convertSelectedMACAddressFormat()
            }

            Divider()

            Menu("Language") {
                Button("Detect from Extension") {
                    documents.resetLanguageFromFile(document.id)
                }
                Divider()
                ForEach(LanguageDetector.supportedLanguages) { language in
                    Toggle(
                        language.displayName,
                        isOn: choiceBinding(document.language == language.id) {
                            documents.setLanguage(document.id, language: language.id)
                        }
                    )
                }
            }
        }
    }

    private func lineEndingMenu(for document: Document) -> some View {
        StatusMenu(label: document.lineEnding.displayName, secondary: true) {
            ForEach(TextLineEnding.allCases) { lineEnding in
                Toggle(
                    lineEnding.displayName,
                    isOn: choiceBinding(document.lineEnding == lineEnding) {
                        applyLineEnding(lineEnding, to: document)
                    }
                )
            }
        }
    }

    /// Mirrors `applyIndentation`. It used to convert through
    /// `focusedEditor`, which in compare mode is whichever pane has focus and
    /// not necessarily the document whose menu this is — so picking CRLF on the
    /// right pane's status bar rewrote the left pane's buffer. And with no
    /// editor at all (a background tab), nothing converted the text: the label
    /// changed and the file was saved with its old endings.
    private func applyLineEnding(_ lineEnding: TextLineEnding, to document: Document) {
        if let editor = EditorCommandTarget.editor(for: document.id) {
            editor.convertLineEndings(to: lineEnding)
        } else {
            let converted = TextContentTransforms.convertLineEndings(in: document.text, to: lineEnding)
            if converted != document.text {
                document.text = converted
                document.isDirty = true
                documents.scheduleDraftSave(for: document.id)
                documents.scheduleAutoSave(
                    for: document.id,
                    isEnabled: preferences.autoSaveEnabled,
                    delay: preferences.autoSaveDelay
                )
            }
        }
        documents.setLineEnding(document.id, lineEnding: lineEnding)
    }

    private func indentationMenu(for document: Document) -> some View {
        StatusMenu(label: document.indentation.displayName, secondary: true) {
            ForEach(TextIndentation.allCases) { indentation in
                Toggle(
                    indentation.displayName,
                    isOn: choiceBinding(document.indentation == indentation) {
                        applyIndentation(indentation, to: document)
                    }
                )
            }
        }
    }

    private func applyIndentation(_ indentation: TextIndentation, to document: Document) {
        if let editor = EditorCommandTarget.editor(for: document.id) {
            editor.convertIndentation(to: indentation)
        } else {
            let converted = TextContentTransforms.convertIndentation(in: document.text, to: indentation)
            if converted != document.text {
                document.text = converted
                document.isDirty = true
                documents.scheduleDraftSave(for: document.id)
                documents.scheduleAutoSave(
                    for: document.id,
                    isEnabled: preferences.autoSaveEnabled,
                    delay: preferences.autoSaveDelay
                )
            }
            document.indentation = indentation
        }
        documents.setIndentation(document.id, indentation: indentation)
    }

    private func encodingMenu(for document: Document) -> some View {
        StatusMenu(label: encodingLabel(for: document), secondary: true) {
            ForEach(TextEncoding.allCases) { encoding in
                if encoding.startsMenuSection {
                    Divider()
                }
                Toggle(
                    encoding.displayName,
                    isOn: choiceBinding(document.encoding == encoding) {
                        applyEncoding(encoding, to: document)
                    }
                )
            }

            Divider()

            Button(document.hasBOM ? "Disable BOM on Save" : "Write BOM on Save") {
                documents.setBOM(document.id, hasBOM: !document.hasBOM)
            }
        }
    }

    private func applyEncoding(_ encoding: TextEncoding, to document: Document) {
        if document.url != nil, !document.isDirty {
            documents.reopenDocument(document.id, with: encoding)
        } else {
            documents.setEncoding(document.id, encoding: encoding)
        }
    }

    private func encodingLabel(for document: Document) -> String {
        if document.encoding == .utf8WithBOM {
            return document.hasBOM ? "UTF-8 BOM" : "UTF-8"
        }
        if document.hasBOM, document.encoding == .utf8 {
            return "UTF-8 BOM"
        }
        return document.encoding.displayName
    }

    private func promptGoToLine() {
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        alert.informativeText = "Enter a line number."
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
        field.placeholderString = "Line"
        field.stringValue = "\(cursor.line)"
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn,
              let line = Int(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }
        EditorCommandTarget.focusedEditor?.goToLine(line)
    }

    private func choiceBinding(_ isSelected: Bool, select: @escaping () -> Void) -> Binding<Bool> {
        Binding(
            get: { isSelected },
            set: { shouldSelect in
                if shouldSelect {
                    select()
                }
            }
        )
    }

    private func timeLabel(_ date: Date) -> String {
        Self.statusTimeFormatter.string(from: date)
    }

    private static let statusTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

private struct StatusMenu<Content: View>: View {
    let label: String
    var secondary: Bool = false
    private let content: () -> Content

    init(
        label: String,
        secondary: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.label = label
        self.secondary = secondary
        self.content = content
    }

    var body: some View {
        Menu {
            content()
        } label: {
            StatusItem(label: label, secondary: secondary)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .fixedSize()
    }
}

private struct StatusItem: View {
    let label: String
    var color: Color = .primary
    var secondary: Bool = false

    var body: some View {
        Text(label)
            .foregroundStyle(secondary ? Color.secondary : color)
            .padding(.horizontal, 10)
            .frame(height: 22)
    }
}

private struct StatusDivider: View {
    var body: some View {
        Divider()
            .frame(height: 12)
            .padding(.vertical, 5)
    }
}
