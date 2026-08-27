//
//  FindInFilesView.swift
//  Sidebar search panel for workspace-wide search.
//

import SwiftUI
import AppKit

struct FindInFilesView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(DocumentStore.self) private var documents

    @State private var query = ""
    @State private var replacement = ""
    @State private var caseSensitive = false
    @State private var wholeWord = false
    @State private var useRegex = false
    @State private var matches: [FindInFilesMatch] = []
    @State private var searchedFiles = 0
    @State private var skippedFiles = 0
    @State private var hitLimit = false
    @State private var errorMessage: String?
    @State private var replaceMessage: String?
    @State private var lastBackupURL: URL?
    /// True while a detached search/replace is in flight.
    @State private var isBusy = false
    /// The in-flight search or replace, so a new one can supersede it instead
    /// of racing its results into the view.
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            Divider()

            if workspace.rootURL == nil {
                emptyWorkspace
            } else if let errorMessage {
                messageView(errorMessage, systemImage: "exclamationmark.triangle")
            } else if matches.isEmpty {
                emptyResults
            } else {
                resultsList
            }
        }
        .onAppear {
            if !query.isEmpty {
                runSearch()
            }
        }
        .onChange(of: query) { _, _ in clearResults() }
        .onChange(of: caseSensitive) { _, _ in clearResults() }
        .onChange(of: wholeWord) { _, _ in clearResults() }
        .onChange(of: useRegex) { _, _ in clearResults() }
    }

    private var searchHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find in files", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit { runSearch() }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .bestTextInputBackground))
            )

            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .foregroundStyle(.secondary)
                TextField("Replace", text: $replacement)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .bestTextInputBackground))
            )

            HStack(spacing: 4) {
                SearchToggle(symbol: "textformat.size", help: "Case Sensitive", isOn: $caseSensitive)
                SearchToggle(symbol: "text.word.spacing", help: "Whole Word", isOn: $wholeWord)
                SearchToggle(symbol: "asterisk", help: "Regular Expression", isOn: $useRegex)

                Spacer()

                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                }

                Button {
                    runSearch()
                } label: {
                    Image(systemName: "arrow.forward")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isBusy || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workspace.rootURL == nil)
                .help("Search")

                Button("Replace All", action: replaceAll)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isBusy || matches.isEmpty || workspace.rootURL == nil)
                    .help("Replace all matches in the workspace")
            }

            if searchedFiles > 0 || skippedFiles > 0 || hitLimit {
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let replaceMessage {
                HStack(spacing: 6) {
                    Text(replaceMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let lastBackupURL {
                        Button("Reveal Backup") {
                            NSWorkspace.shared.open(lastBackupURL)
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(Color(nsColor: .bestTextPanelBackground))
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groupedResults, id: \.path) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) {
                            Image(systemName: "doc")
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            Text(group.path)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text("\(group.matches.count)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 9)
                        .padding(.bottom, 4)

                        ForEach(group.matches) { match in
                            Button {
                                open(match)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("\(match.lineNumber):\(match.column)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 52, alignment: .trailing)

                                    Text(match.preview.isEmpty ? " " : match.preview)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)

                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 10)
        }
    }

    private var emptyWorkspace: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "folder")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No folder open")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("Open Folder...") {
                workspace.promptOpenFolder()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyResults: some View {
        messageView(query.isEmpty ? "No search" : "No results", systemImage: "magnifyingglass")
    }

    private func messageView(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var groupedResults: [(path: String, matches: [FindInFilesMatch])] {
        let grouped = Dictionary(grouping: matches, by: \.relativePath)
        return grouped.keys.sorted().map { path in
            (path, grouped[path] ?? [])
        }
    }

    private var statusText: String {
        var parts = ["\(matches.count) matches", "\(searchedFiles) files"]
        if skippedFiles > 0 {
            parts.append("\(skippedFiles) skipped")
        }
        if hitLimit {
            parts.append("limited")
        }
        return parts.joined(separator: " | ")
    }

    /// Reading and regex-scanning every file under the workspace root used to run
    /// synchronously inside this view's call stack — i.e. on the main thread — so
    /// searching a large folder froze the whole app until it finished. The engine
    /// touches nothing main-actor-bound, so it runs detached and only the state
    /// assignment comes back here.
    @MainActor
    private func runSearch(clearingReplaceMessage: Bool = true) {
        guard let root = workspace.rootURL else { return }

        // A second search must not race the first one's results into the view.
        searchTask?.cancel()

        let tree = workspace.tree
        let options = searchOptions
        isBusy = true

        searchTask = Task { @MainActor in
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try FindInFilesEngine.search(root: root, tree: tree, options: options) }
            }.value

            guard !Task.isCancelled else { return }
            isBusy = false

            switch outcome {
            case .success(let summary):
                matches = summary.matches
                searchedFiles = summary.searchedFiles
                skippedFiles = summary.skippedFiles
                hitLimit = summary.hitLimit
                errorMessage = nil
                if clearingReplaceMessage { replaceMessage = nil }
            case .failure(let error):
                matches = []
                searchedFiles = 0
                skippedFiles = 0
                hitLimit = false
                errorMessage = error.localizedDescription
                if clearingReplaceMessage { replaceMessage = nil }
            }
        }
    }

    @MainActor
    private func replaceAll() {
        guard let root = workspace.rootURL, !matches.isEmpty else { return }

        let affectedURLs = Set(matches.map { $0.url.standardizedFileURL })
        let dirtyDocuments = documents.documents.filter { document in
            guard let url = document.url else { return false }
            return document.isDirty && affectedURLs.contains(url.standardizedFileURL)
        }

        guard dirtyDocuments.isEmpty else {
            showAlert(
                title: "Cannot Replace in Unsaved Files",
                message: "Save or close the matching unsaved tabs first: \(dirtyDocuments.map(\.displayName).joined(separator: ", "))",
                style: .warning
            )
            return
        }

        guard confirmReplace(matchCount: matches.count, fileCount: affectedURLs.count) else { return }

        // The confirmation alert is deliberately still synchronous and on main —
        // only the file rewriting moves off it.
        searchTask?.cancel()
        let tree = workspace.tree
        let options = searchOptions
        let replacementText = replacement
        isBusy = true

        searchTask = Task { @MainActor in
            let outcome = await Task.detached(priority: .userInitiated) {
                Result {
                    try FindInFilesEngine.replaceAll(
                        root: root,
                        tree: tree,
                        options: options,
                        replacement: replacementText
                    )
                }
            }.value

            guard !Task.isCancelled else { return }
            isBusy = false

            switch outcome {
            case .success(let summary):
                documents.reloadCleanOpenDocumentsFromDisk(urls: summary.changedURLs)
                lastBackupURL = summary.backupDirectory
                replaceMessage = "Replaced \(summary.replacementCount) matches in \(summary.changedURLs.count) files."
                // Refresh the hit list against the rewritten files, but keep the
                // "Replaced N matches" line — the old code got that for free
                // because the re-search was synchronous and ran BEFORE the message
                // was set. Now it lands afterwards and would clear it.
                runSearch(clearingReplaceMessage: false)
            case .failure(let error):
                errorMessage = error.localizedDescription
                replaceMessage = nil
                lastBackupURL = nil
            }
        }
    }

    private var searchOptions: FindInFilesOptions {
        FindInFilesOptions(
            query: query,
            caseSensitive: caseSensitive,
            wholeWord: wholeWord,
            useRegex: useRegex
        )
    }

    private func clearResults() {
        searchTask?.cancel()
        isBusy = false
        matches = []
        searchedFiles = 0
        skippedFiles = 0
        hitLimit = false
        errorMessage = nil
        replaceMessage = nil
        lastBackupURL = nil
    }

    private func confirmReplace(matchCount: Int, fileCount: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Replace in Files?"
        alert.informativeText = "Replace \(matchCount) matches in \(fileCount) files. Backup copies will be created before files are changed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.runModal()
    }

    private func open(_ match: FindInFilesMatch) {
        guard let document = documents.open(url: match.url) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            EditorCommandTarget.editor(for: document.id)?.goToLine(match.lineNumber)
        }
    }
}

private struct SearchToggle: View {
    let symbol: String
    let help: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
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
