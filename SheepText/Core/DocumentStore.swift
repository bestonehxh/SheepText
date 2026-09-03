//
//  DocumentStore.swift
//  Owns the set of open Document objects, plus save/open operations,
//  the recent-files list, and manual save/open operations.
//

import Foundation
import AppKit
import OSLog
import NetworkHighlightKit
import Observation
import UniformTypeIdentifiers

extension URL {
    /// One definition of "the same file" for the whole document layer.
    ///
    /// `standardizedFileURL` resolves `.`, `..` and a trailing slash but NOT
    /// symlinks, and on macOS `/tmp`, `/var` and `/etc` are all symlinks — so
    /// opening `/tmp/notes.txt` after `/private/tmp/notes.txt` compared unequal
    /// and gave two tabs onto one file, each overwriting the other's save.
    /// Everything that asks "is this the document I already have?" goes through
    /// this.
    nonisolated var canonicalFileURL: URL {
        resolvingSymlinksInPath().standardizedFileURL
    }
}

@Observable
@MainActor
final class DocumentStore {
    /// Ceiling for the synchronous open-time highlight below. This work happens
    /// on the main actor via `queue.sync` so the first frame of a newly opened
    /// document is already colored — but it is a hard stall, and it can also
    /// queue behind whatever else the syntax queue is doing. Kept low enough
    /// that the stall stays imperceptible; larger files fall back to the normal
    /// asynchronous highlight, same as they always did in large-file mode.
    private static let initialHighlightPrecomputeUTF16Limit = 40_000

    private(set) var documents: [Document] = [] {
        didSet { persistSession() }
    }
    var activeDocumentID: Document.ID? {
        didSet { persistSession() }
    }
    var compareLeftDocumentID: Document.ID?
    var compareRightDocumentID: Document.ID?

    /// Recent files list (most-recent first). Capped at `recentLimit`.
    /// Persisted to UserDefaults.
    private(set) var recentFiles: [URL] = []
    private let recentLimit = 20
    private let recentKey   = "sheeptext.recentFiles"
    private let sessionOpenFilesKey = "sheeptext.session.openFiles"
    private let sessionActiveFileKey = "sheeptext.session.activeFile"
    private var isRestoringSession = false
    /// `restoreSessionTabs` runs once per launch; see its doc comment for why
    /// the guard is on this and not on `documents.isEmpty`.
    private var hasRestoredSession = false
    private var isCheckingExternalChanges = false
    private var draftSaveTasks: [Document.ID: Task<Void, Never>] = [:]
    private var draftSaveRevisions: [Document.ID: UUID] = [:]
    private var autoSaveTasks: [Document.ID: Task<Void, Never>] = [:]
    /// draftID → the revision this process last wrote to disk, so
    /// `deleteDraftFiles` can name the files instead of scanning the directory.
    /// `removeOlderDraftFiles` runs after every write, so this revision names the
    /// only files that exist for that draft.
    private var lastWrittenDraftRevisions: [UUID: UUID] = [:]

    var activeDocument: Document? {
        documents.first(where: { $0.id == activeDocumentID })
    }

    var compareLeftDocument: Document? {
        guard let id = compareLeftDocumentID else { return nil }
        return documents.first(where: { $0.id == id })
    }

    var compareRightDocument: Document? {
        guard let id = compareRightDocumentID else { return nil }
        return documents.first(where: { $0.id == id })
    }

    var isCompareMode: Bool {
        compareLeftDocument != nil && compareRightDocument != nil
    }

    private func containsDocument(_ id: Document.ID?) -> Bool {
        guard let id else { return false }
        return documents.contains(where: { $0.id == id })
    }

    private func normalizeCompareState() {
        if !containsDocument(compareLeftDocumentID) {
            compareLeftDocumentID = nil
        }
        if !containsDocument(compareRightDocumentID) {
            compareRightDocumentID = nil
        }
        if compareLeftDocumentID == compareRightDocumentID {
            compareRightDocumentID = nil
        }
    }

    init() {
        loadRecentFiles()
    }

    // MARK: - Open

    /// Open a file from disk. Encoding is detected automatically.
    /// If the document is already open, just focuses its tab.
    @discardableResult
    func open(
        url: URL,
        rememberRecent: Bool = true,
        showError: Bool = true,
        preferences: AppPreferences? = nil
    ) -> Document? {
        let preferences = preferences ?? AppPreferences.current
        let accessibleURL = SecurityScopedResourceAccess.prepare(
            url,
            bookmarkKey: SecurityScopedResourceAccess.fileBookmarksKey,
            shouldRemember: rememberRecent
        )

        if let existing = documents.first(where: { $0.url?.canonicalFileURL == accessibleURL.canonicalFileURL }) {
            activeDocumentID = existing.id
            if rememberRecent {
                addRecent(accessibleURL)
            }
            return existing
        }

        let fileByteCount = fileSize(for: accessibleURL)
        if showError,
           preferences?.warnsWhenOpeningLargeFiles ?? true,
           let fileByteCount,
           fileByteCount >= LargeFilePolicy.hugeFileByteThreshold,
           !presentHugeFileAlert(for: accessibleURL, byteCount: fileByteCount) {
            return nil
        }

        let decoded: DecodedFile
        do {
            // Manual-encoding path. It goes through TextFileIO.decode(data:as:)
            // rather than String(data:encoding:) so it gets the same BOM answer
            // and the same binary verdict as the automatic path — it used to
            // guess `writesBOMByDefault` (losing a real UTF-8 BOM on save) and
            // to leave `looksBinary` false, which skipped the guard below.
            if preferences?.detectsEncodingAutomatically == false,
               let data = try? Data(contentsOf: accessibleURL),
               let defaultEncoding = preferences?.defaultEncoding,
               let manual = TextFileIO.decode(data: data, as: defaultEncoding) {
                decoded = manual
            } else {
                decoded = try TextFileIO.read(url: accessibleURL)
            }
        } catch {
            if showError {
                NSAlert.show(message: "Cannot open \(accessibleURL.lastPathComponent): \(error.localizedDescription)", style: .warning)
            }
            return nil
        }

        // The app claims `public.data` in AppInfo.plist, so it is offered as the
        // handler for files that are not text at all — and `TextFileIO.decode`
        // never fails, its last resort is Windows-1252. Opening a binary then
        // editing and saving rewrites it as mangled text, destroying the
        // original. Ask first.
        if showError, decoded.looksBinary, !presentBinaryFileAlert(for: accessibleURL) {
            return nil
        }

        let doc = Document(
            url: accessibleURL,
            initialText: decoded.text,
            encoding: decoded.encoding,
            hasBOM: decoded.hadBOM,
            byteCount: decoded.byteCount ?? fileByteCount
        )
        if preferences?.detectsSyntaxByFileExtension == false {
            doc.language = preferences?.defaultLanguage ?? "plaintext"
        }
        applyDocumentDefaults(from: preferences, to: doc, preserveDetectedFormat: true)
        // Restoring a session opens every remembered tab in a row, and this parse is
        // synchronous — ten tabs meant ten full-file parses stacked up before the first
        // paint. Only the tab the user actually lands on needs its highlight ready up
        // front; restoreSessionTabs primes that one once it knows which it is, and the
        // rest fall back to the editor's own lazy highlight on first switch.
        if !isRestoringSession {
            precomputeInitialHighlight(for: doc, preferences: preferences)
        }
        doc.accessibleURL = accessibleURL
        captureDiskState(of: accessibleURL, into: doc)
        documents.append(doc)
        activeDocumentID = doc.id
        if rememberRecent {
            addRecent(accessibleURL)
        }
        return doc
    }

    private func precomputeInitialHighlight(for doc: Document, preferences: AppPreferences?) {
        guard !doc.isLargeFileModeActive else { return }

        let language = NetworkConfigLanguage.engineLanguage(
            for: HighlightOverrides.shared.resolvedLanguage(
                for: doc.url,
                defaultLanguage: doc.language
            ),
            vendor: doc.networkVendor
        )
        guard SyntaxEngine.supportsHighlighting(language) else { return }

        let textLength = (doc.text as NSString).length
        guard textLength > 0 else { return }
        guard textLength <= Self.initialHighlightPrecomputeUTF16Limit else { return }

        // No appearance in here any more: runs carry style ids, so one
        // precomputed list is correct in light and dark alike.
        guard let result = SyntaxEngine.shared.runsImmediately(
            text: doc.text,
            language: language,
            documentID: doc.id
        ) else { return }

        doc.precomputedSyntaxHighlight = PrecomputedSyntaxHighlight(
            language: language,
            utf16Length: textLength,
            textHash: doc.text.hashValue,
            runs: result.runs
        )
    }

    func openExternalFileURLs(_ urls: [URL], preferences: AppPreferences? = nil) {
        let fileURLs = urls.filter { $0.isFileURL }
        guard !fileURLs.isEmpty else { return }

        removeBlankLaunchDocumentIfNeeded()
        for url in fileURLs {
            open(url: url, preferences: preferences)
        }
    }

    /// Re-open the active document with a different encoding. Useful when
    /// auto-detection picked the wrong one.
    func reopenDocument(_ id: Document.ID, with encoding: TextEncoding) {
        guard let doc = documents.first(where: { $0.id == id }),
              let url = doc.url else { return }
        let accessibleURL = SecurityScopedResourceAccess.prepare(
            url,
            bookmarkKey: SecurityScopedResourceAccess.fileBookmarksKey,
            shouldRemember: true
        )
        guard let data = try? Data(contentsOf: accessibleURL),
              let decoded = TextFileIO.decode(data: data, as: encoding) else {
            NSAlert.show(message: "Cannot decode file as \(encoding.displayName).", style: .warning)
            return
        }
        let text = decoded.text
        doc.text = text
        // This never set hasBOM at all, so re-opening a BOM'd file with an
        // explicit encoding dropped the BOM on the next save.
        doc.hasBOM = decoded.hadBOM
        // The document now matches the file, so this IS the save baseline. Leaving
        // the old value behind made the modified-since-save gutter bars diff the
        // freshly-loaded text against the previous contents and light up the whole
        // file. Same reasoning in reloadCleanOpenDocumentsFromDisk and
        // reloadDocumentFromDisk below.
        doc.savedText = text
        doc.encoding = encoding
        doc.lineEnding = TextLineEnding.detect(in: text)
        doc.indentation = TextIndentation.detect(in: text)
        doc.refreshLargeFileMetrics(byteCount: data.count)
        doc.isDirty = false
        doc.wasRecoveredFromDraft = false
        doc.url = accessibleURL
        doc.accessibleURL = accessibleURL
        captureDiskState(of: accessibleURL, into: doc)
        doc.externalChangeWarningDate = nil
        deleteDraft(for: doc)
    }

    @discardableResult
    func newUntitled(preferences: AppPreferences? = nil) -> Document {
        let preferences = preferences ?? AppPreferences.current
        let encoding = preferences?.defaultEncoding ?? .utf8
        let doc = Document(url: nil, initialText: "", encoding: encoding, hasBOM: encoding.writesBOMByDefault)
        applyDocumentDefaults(from: preferences, to: doc, preserveDetectedFormat: false)
        documents.append(doc)
        activeDocumentID = doc.id
        return doc
    }

    private func removeBlankLaunchDocumentIfNeeded() {
        guard documents.count == 1,
              let document = documents.first,
              document.url == nil,
              document.text.isEmpty,
              !document.isDirty,
              !document.wasRecoveredFromDraft
        else { return }

        for document in documents {
            SyntaxEngine.shared.discardSession(for: document.id)
            EditorHighlightCache.discard(for: document.id)
        }
        documents.removeAll()
        activeDocumentID = nil
    }

    // MARK: - Close

    /// Close a tab. If the document is dirty, prompts the user first.
    /// Returns `true` if the close happened (user confirmed or doc was clean).
    ///
    /// **The one close path.** There used to be a second, copy-pasted one
    /// (`requestCloseTabFromUI`), and the two had already drifted: only this one
    /// consulted `askBeforeClosingUnsavedDocuments`, so a user who turned that
    /// preference off still got the prompt from the tab-bar ✕, "Close Other
    /// Tabs" and "Close All Tabs" — everything except ⌘W.
    @discardableResult
    func close(_ id: Document.ID) -> Bool {
        guard let doc = documents.first(where: { $0.id == id }) else { return true }

        if doc.isDirty && (AppPreferences.current?.askBeforeClosingUnsavedDocuments ?? true) {
            let choice = presentUnsavedChangesAlert(for: doc)
            switch choice {
            case .save:
                // If untitled, prompt for location. If that cancels, abort close.
                if doc.url == nil {
                    guard promptSaveAs(doc) else { return false }
                } else {
                    do { try saveNow(doc) } catch {
                        NSAlert.show(message: "Save failed: \(error.localizedDescription)", style: .critical)
                        return false
                    }
                }
            case .discard:
                break
            case .cancel:
                return false
            }
        }

        let wasActive = activeDocumentID == id
        let nextActiveID = wasActive
            ? documents.last(where: { $0.id != id })?.id
            : activeDocumentID

        if compareLeftDocumentID == id { compareLeftDocumentID = nil }
        if compareRightDocumentID == id { compareRightDocumentID = nil }

        deleteDraft(for: doc)
        // Fold state is kept in a process-wide table so it survives the editor
        // view being rebuilt on a tab switch; nothing else ever removes it.
        FoldingManager.discardSavedFolds(for: doc.id.uuidString)
        // Same story for the incremental-parse session, which pins the full
        // text, a syntax tree copy and the last attributed string.
        SyntaxEngine.shared.discardSession(for: doc.id)
        EditorHighlightCache.discard(for: doc.id)
        documents.removeAll { $0.id == id }
        if wasActive {
            activeDocumentID = nextActiveID
        }
        normalizeCompareState()
        return true
    }

    func closeAllTabs() {
        for id in documents.map(\.id) {
            guard requestCloseTabFromUI(id) else { break }
        }
    }

    func closeSavedTabs() {
        for id in documents.filter({ !$0.isDirty }).map(\.id) {
            _ = requestCloseTabFromUI(id)
        }
    }

    func closeOtherTabs() {
        guard let activeID = activeDocumentID else { return }
        for id in documents.map(\.id) where id != activeID {
            guard requestCloseTabFromUI(id) else { break }
        }
        if containsDocument(activeID) {
            activeDocumentID = activeID
        }
    }

    // MARK: - Compare

    /// Shows a picker of all other open tabs and compares the active tab (LEFT)
    /// against the one the user selects (RIGHT).
    func selectTabToCompare() {
        guard let activeID = activeDocumentID,
              let activeDoc = activeDocument else {
            NSAlert.show(message: "No active tab to compare.", style: .warning)
            return
        }

        let others = documents.filter { $0.id != activeID }
        guard !others.isEmpty else {
            NSAlert.show(message: "Open another tab first.", style: .warning)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Select Tab to Compare"
        alert.informativeText = "Compare \"\(activeDoc.displayName)\" with:"
        alert.addButton(withTitle: "Compare")
        alert.addButton(withTitle: "Cancel")

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        for doc in others { popup.addItem(withTitle: doc.displayName) }
        alert.accessoryView = popup

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let idx = popup.indexOfSelectedItem
        guard idx >= 0, idx < others.count else { return }

        compareLeftDocumentID  = activeID
        compareRightDocumentID = others[idx].id
    }

    func compareWithActiveDocument() {
        normalizeCompareState()
        guard let activeID = activeDocumentID,
              let activeIndex = documents.firstIndex(where: { $0.id == activeID })
        else {
            NSAlert.show(message: "No active tab to compare.", style: .warning)
            return
        }

        // Active tab = LEFT. Right = the next tab to the right in the tab bar (index+1).
        // e.g. Tab 3 active → LEFT=3, RIGHT=4
        // If active is the last tab, fall back to the previous tab (index-1).
        compareLeftDocumentID = activeID

        if activeIndex < documents.count - 1 {
            compareRightDocumentID = documents[activeIndex + 1].id
        } else if activeIndex > 0 {
            compareRightDocumentID = documents[activeIndex - 1].id
        } else {
            compareLeftDocumentID = nil
            NSAlert.show(
                message: "Open another tab first, then run Compare with Right Tab again.",
                style: .warning
            )
        }
    }

    /// Opens a file picker. Active tab = LEFT, selected file = RIGHT.
    func selectFileToCompare(_ url: URL) {
        normalizeCompareState()
        guard let leftID = activeDocumentID else {
            NSAlert.show(message: "No active tab to compare from.", style: .warning)
            return
        }

        guard let right = open(url: url, preferences: AppPreferences.current) else { return }
        guard leftID != right.id else {
            NSAlert.show(message: "Cannot compare a file with itself.", style: .warning)
            return
        }

        compareLeftDocumentID = leftID
        compareRightDocumentID = right.id
        activeDocumentID = leftID
    }

    func clearCompareMode() {
        compareLeftDocumentID = nil
        compareRightDocumentID = nil
    }

    // MARK: - Tab order

    func moveDocument(id: Document.ID, to targetIndex: Int) {
        guard let sourceIndex = documents.firstIndex(where: { $0.id == id }) else { return }
        let clampedTarget = max(0, min(targetIndex, documents.count - 1))
        guard sourceIndex != clampedTarget else { return }

        let doc = documents.remove(at: sourceIndex)
        documents.insert(doc, at: clampedTarget)
        activeDocumentID = doc.id
    }

    func reorderDocuments(matching orderedIDs: [Document.ID]) {
        guard !orderedIDs.isEmpty else { return }
        let currentIDs = documents.map(\.id)
        guard currentIDs != orderedIDs else { return }

        var byID: [Document.ID: Document] = [:]
        for document in documents {
            byID[document.id] = document
        }

        var reordered = orderedIDs.compactMap { byID[$0] }
        let orderedSet = Set(orderedIDs)
        reordered.append(contentsOf: documents.filter { !orderedSet.contains($0.id) })

        guard reordered.map(\.id) != currentIDs else { return }
        documents = reordered
    }

    // MARK: - Save

    /// Save the active document. If it has no URL, prompts for location.
    func save(_ id: Document.ID) {
        guard let doc = documents.first(where: { $0.id == id }) else { return }
        if doc.url == nil {
            _ = promptSaveAs(doc)
            return
        }
        do { try saveNow(doc) } catch {
            NSAlert.show(message: "Save failed: \(error.localizedDescription)", style: .critical)
        }
    }

    /// Save every dirty tab. Untitled documents prompt for a destination.
    @discardableResult
    func saveAllDirty() -> Int {
        var savedCount = 0
        var failures: [String] = []

        for doc in documents where doc.isDirty {
            if doc.url == nil {
                if promptSaveAs(doc) {
                    savedCount += 1
                }
                continue
            }

            do {
                try saveNow(doc)
                savedCount += 1
            } catch {
                failures.append("\(doc.displayName): \(error.localizedDescription)")
            }
        }

        if !failures.isEmpty {
            NSAlert.show(
                message: "Some files could not be saved:\n\(failures.joined(separator: "\n"))",
                style: .critical
            )
        }

        return savedCount
    }

    /// Save As — always prompts, regardless of whether the doc has a URL.
    func saveAs(_ id: Document.ID) {
        guard let doc = documents.first(where: { $0.id == id }) else { return }
        _ = promptSaveAs(doc)
    }

    /// Save the active document with a different encoding.
    func saveWithEncoding(_ id: Document.ID, encoding: TextEncoding) {
        guard let doc = documents.first(where: { $0.id == id }) else { return }
        doc.encoding = encoding
        doc.hasBOM = encoding.writesBOMByDefault
        save(id)
    }

    func setEncoding(_ id: Document.ID, encoding: TextEncoding) {
        guard let doc = documents.first(where: { $0.id == id }) else { return }
        doc.encoding = encoding
        doc.hasBOM = encoding.writesBOMByDefault
        scheduleDraftSaveIfDirty(for: doc)
    }

    func setLanguage(_ id: Document.ID, language: String) {
        guard let doc = documents.first(where: { $0.id == id }) else { return }
        doc.language = LanguageDetector.normalizedLanguage(language)
        scheduleDraftSaveIfDirty(for: doc)
        NotificationCenter.default.post(name: .syntaxHighlightSettingsDidChange, object: nil)
    }

    func resetLanguageFromFile(_ id: Document.ID) {
        guard let doc = documents.first(where: { $0.id == id }) else { return }
        // A language chosen from the extension is not a vendor chosen by hand:
        // drop the manual pin so the fingerprint gets to speak again.
        doc.networkVendorIsManual = false
        doc.language = LanguageDetector.detect(for: doc.url)
        doc.refreshDetectedNetworkVendor()
        scheduleDraftSaveIfDirty(for: doc)
        NotificationCenter.default.post(name: .syntaxHighlightSettingsDidChange, object: nil)
    }

    /// The user's pick from the vendor badge. Wins over detection, and is
    /// remembered for the document exactly like the language is.
    func setNetworkVendor(_ id: Document.ID, vendor: Vendor) {
        guard let doc = documents.first(where: { $0.id == id }) else { return }
        doc.networkVendorIsManual = true
        doc.networkVendor = vendor
        scheduleDraftSaveIfDirty(for: doc)
        NotificationCenter.default.post(name: .syntaxHighlightSettingsDidChange, object: nil)
    }

    /// The language menu's network entries: one click sets BOTH the language
    /// and the family. `vendor == nil` is "Network config, auto-detect" — the
    /// document becomes a network config and the fingerprint (or the
    /// extension fallback) names the family; a vendor pins it by hand.
    func setNetworkLanguage(_ id: Document.ID, vendor: Vendor?) {
        guard let doc = documents.first(where: { $0.id == id }) else { return }
        if let vendor {
            // Pin first: `language`'s didSet re-detects, and a manual pick
            // must not be overwritten by that pass.
            doc.networkVendorIsManual = true
            doc.networkVendor = vendor
            doc.language = NetworkConfigLanguage.id
        } else {
            doc.networkVendorIsManual = false
            doc.language = NetworkConfigLanguage.id
            doc.refreshDetectedNetworkVendor()
        }
        scheduleDraftSaveIfDirty(for: doc)
        NotificationCenter.default.post(name: .syntaxHighlightSettingsDidChange, object: nil)
    }

    /// "Auto-detect": forget the manual pick and fingerprint the file again.
    func resetNetworkVendorFromContent(_ id: Document.ID) {
        guard let doc = documents.first(where: { $0.id == id }) else { return }
        doc.networkVendorIsManual = false
        doc.refreshDetectedNetworkVendor()
        scheduleDraftSaveIfDirty(for: doc)
        NotificationCenter.default.post(name: .syntaxHighlightSettingsDidChange, object: nil)
    }

    func setIndentation(_ id: Document.ID, indentation: TextIndentation) {
        guard let doc = documents.first(where: { $0.id == id }) else { return }
        doc.indentation = indentation
        scheduleDraftSaveIfDirty(for: doc)
    }

    func setLineEnding(_ id: Document.ID, lineEnding: TextLineEnding) {
        guard let doc = documents.first(where: { $0.id == id }) else { return }
        doc.lineEnding = lineEnding
        scheduleDraftSaveIfDirty(for: doc)
    }

    func setShowsInvisibleCharacters(_ id: Document.ID, isEnabled: Bool) {
        guard let doc = documents.first(where: { $0.id == id }) else { return }
        doc.showsInvisibleCharacters = isEnabled
        scheduleDraftSaveIfDirty(for: doc)
    }

    func setWordWrap(_ id: Document.ID, isEnabled: Bool) {
        guard let doc = documents.first(where: { $0.id == id }) else { return }
        doc.wordWrap = isEnabled
        scheduleDraftSaveIfDirty(for: doc)
    }

    func setAutoTrimTrailingWhitespace(_ id: Document.ID, isEnabled: Bool) {
        guard let doc = documents.first(where: { $0.id == id }) else { return }
        doc.autoTrimTrailingWhitespace = isEnabled
        scheduleDraftSaveIfDirty(for: doc)
    }

    func setBOM(_ id: Document.ID, hasBOM: Bool) {
        guard let doc = documents.first(where: { $0.id == id }) else { return }
        doc.hasBOM = hasBOM
        if doc.encoding == .utf8, hasBOM {
            doc.encoding = .utf8WithBOM
        } else if doc.encoding == .utf8WithBOM, !hasBOM {
            doc.encoding = .utf8
        }
        scheduleDraftSaveIfDirty(for: doc)
    }

    private func applyDocumentDefaults(
        from preferences: AppPreferences?,
        to document: Document,
        preserveDetectedFormat: Bool
    ) {
        guard let preferences else { return }
        if !preserveDetectedFormat {
            document.language = preferences.defaultLanguage
            document.lineEnding = preferences.defaultLineEnding
            document.indentation = preferences.defaultIndentation
        }
        document.wordWrap = preferences.wordWrapByDefault
        document.showsInvisibleCharacters = preferences.showsInvisibleCharactersByDefault
    }

    func reloadCleanOpenDocumentsFromDisk(urls: Set<URL>) {
        let canonicalURLs = Set(urls.map(\.canonicalFileURL))
        for doc in documents {
            guard let url = doc.url,
                  canonicalURLs.contains(url.canonicalFileURL),
                  !doc.isDirty
            else { continue }
            let accessibleURL = SecurityScopedResourceAccess.prepare(
                url,
                bookmarkKey: SecurityScopedResourceAccess.fileBookmarksKey,
                shouldRemember: false
            )
            guard let decoded = try? TextFileIO.read(url: accessibleURL) else { continue }

            doc.text = decoded.text
            doc.savedText = decoded.text
            doc.encoding = decoded.encoding
            doc.hasBOM = decoded.hadBOM
            doc.lineEnding = TextLineEnding.detect(in: decoded.text)
            doc.indentation = TextIndentation.detect(in: decoded.text)
            doc.refreshLargeFileMetrics(byteCount: decoded.byteCount)
            doc.url = accessibleURL
            doc.accessibleURL = accessibleURL
            doc.language = LanguageDetector.detect(for: accessibleURL)
            captureDiskState(of: accessibleURL, into: doc)
            doc.externalChangeWarningDate = nil
            deleteDraft(for: doc)

            NotificationCenter.default.post(
                name: .documentReloadedFromDisk,
                object: nil,
                userInfo: ["documentID": doc.id]
            )
        }
    }

    /// Synchronous write to the document's current URL. Throws on I/O error.
    /// Everything a save needs, snapshotted on the main actor so the bytes can
    /// be written from anywhere.
    private struct SavePayload {
        let url: URL
        let data: Data
        let text: String
        /// `Document.revision` at the moment the bytes were encoded. The auto
        /// save write happens off the main actor, so this is what says whether
        /// the document the continuation finds is still the one we encoded.
        let revision: Int
    }

    /// Resolve the security scope and encode. Split out of `saveNow` so auto
    /// save can share exactly this logic instead of keeping a second copy of it.
    ///
    /// **This does not modify the document.** It used to apply the trailing
    /// whitespace trim by assigning `doc.text`, and auto save calls it without
    /// going through the editor — so three seconds after the user stopped
    /// typing, `updateNSView` found `viewText != document.text`, replaced the
    /// text view's whole string and threw away the undo stack, the folds and the
    /// caret position. The trim is a manual-save step now; see
    /// `applyManualSaveTransforms`.
    ///
    /// - Parameter rememberBookmark: false on the auto-save path. Remembering
    ///   rewrites the entire security-scoped bookmark dictionary in
    ///   UserDefaults, which does not need to happen every few seconds for a
    ///   file whose bookmark was already stored when it was opened.
    private func prepareSave(_ doc: Document, rememberBookmark: Bool = true) throws -> SavePayload? {
        guard let url = doc.url else { return nil }
        let accessibleURL = SecurityScopedResourceAccess.prepare(
            url,
            bookmarkKey: SecurityScopedResourceAccess.fileBookmarksKey,
            shouldRemember: rememberBookmark
        )
        doc.accessibleURL = accessibleURL
        let data = try TextFileIO.encode(
            text: doc.text,
            as: doc.encoding,
            writeBOM: doc.hasBOM
        )
        return SavePayload(url: accessibleURL, data: data, text: doc.text, revision: doc.revision)
    }

    /// The on-save transforms that mutate the document. Manual saves only —
    /// never the auto-save path, which must not touch `doc.text` behind the
    /// editor's back (see `prepareSave`).
    ///
    /// ⌘S / ⌘⌥S / ⌘⇧S already trim through the focused editor before calling in
    /// here, but they trim the *focused* document, which in compare mode is not
    /// necessarily the one being saved — and `close`, "Save All" and the
    /// quit-time save have no editor step at all. Routing every manual save
    /// through this makes the trim follow the document rather than the focus.
    private func applyManualSaveTransforms(_ doc: Document) {
        guard doc.autoTrimTrailingWhitespace else { return }
        if let editor = EditorCommandTarget.editor(for: doc.id) {
            // Through the editor when there is one, so the change is undoable
            // and the view's storage stays the source of truth.
            editor.trimTrailingWhitespace(markDirty: false)
            return
        }
        let trimmed = TextContentTransforms.trimTrailingWhitespace(
            in: doc.text,
            lineEnding: doc.lineEnding
        )
        if trimmed != doc.text { doc.text = trimmed }
    }

    /// Document bookkeeping that follows a successful write.
    private func commitSave(_ doc: Document, payload: SavePayload, isAutoSave: Bool = false) {
        doc.isDirty = false
        doc.wasRecoveredFromDraft = false
        doc.url = payload.url
        doc.savedText = payload.text
        // One stat, three consumers: large-file metrics, and the mtime/size pair
        // the external-change poll compares against.
        captureDiskState(of: payload.url, into: doc)
        doc.refreshLargeFileMetrics(byteCount: doc.diskFileSize)
        doc.externalChangeWarningDate = nil
        // An auto save is not the user opening a file, so it does not belong in
        // Open Recent — and rewriting that list means a UserDefaults write every
        // few seconds while typing.
        if !isAutoSave {
            addRecent(payload.url)
        }
        deleteDraft(for: doc)
        NotificationCenter.default.post(
            name: .documentDidSave,
            object: nil,
            userInfo: ["documentID": doc.id]
        )
    }

    private func saveNow(_ doc: Document) throws {
        applyManualSaveTransforms(doc)
        guard let payload = try prepareSave(doc) else { return }
        try TextFileIO.writeData(payload.data, to: payload.url)
        commitSave(doc, payload: payload)
    }

    /// Show an NSSavePanel and, if the user confirms, write and update the
    /// document's URL. Returns true if the save happened.
    /// Pre-fills the filename; appends date+counter if that name already
    /// exists in the panel's initial directory, so the user never has to
    /// manually resolve a conflict.
    @discardableResult
    /// A file or folder was renamed or moved on disk **outside** the save path.
    ///
    /// The sidebar's rename used to just assign `document.url`, which is the one
    /// thing that is not enough:
    ///
    /// - the security-scoped bookmark is keyed by path, so the old path's
    ///   bookmark was still the only one stored and the next launch could not
    ///   reopen the file at all (sandbox);
    /// - `accessibleURL` still pointed at the old path, so the 4-second
    ///   external-change poll stat-ed a file that no longer existed;
    /// - `diskModificationDate` / `diskFileSize` still described the old file,
    ///   so the first poll after a rename could fire a spurious "changed on
    ///   disk" alert;
    /// - the recents list and the restore-session list still held the old path.
    ///
    /// Renaming a FOLDER moves every document inside it, so open URLs are
    /// matched by path prefix as well as by identity.
    func documentDidMove(from oldURL: URL, to newURL: URL) {
        let oldCanonical = oldURL.canonicalFileURL
        let newCanonical = newURL.canonicalFileURL
        guard oldCanonical != newCanonical else { return }

        // Path components, not a string prefix: "/proj-secrets" starts with
        // "/proj" and is a different directory. Same rule as FSBridge's scope check.
        let oldComponents = oldCanonical.pathComponents
        func movedURL(for url: URL) -> URL? {
            let canonical = url.canonicalFileURL
            if canonical == oldCanonical { return newURL }
            let components = canonical.pathComponents
            guard components.count > oldComponents.count,
                  Array(components.prefix(oldComponents.count)) == oldComponents
            else { return nil }
            return components
                .dropFirst(oldComponents.count)
                .reduce(newURL) { $0.appendingPathComponent($1) }
        }

        var didMoveAnyDocument = false
        for doc in documents {
            guard let url = doc.url, let moved = movedURL(for: url) else { continue }

            // Re-remember the bookmark under the NEW path before anything reads
            // it back: `prepare` stores it keyed by the path it resolves.
            let accessible = SecurityScopedResourceAccess.prepare(
                moved,
                bookmarkKey: SecurityScopedResourceAccess.fileBookmarksKey,
                shouldRemember: true
            )

            doc.url = accessible
            doc.accessibleURL = accessible
            // The file did not change, only its name — but the stats were taken
            // through the old path, and a rename touches the parent directory's
            // mtime on some filesystems. Re-read them so the poll starts level.
            captureDiskState(of: accessible, into: doc)
            doc.externalChangeWarningDate = nil
            // Same rule Save As uses: the extension only picks the language when
            // the user has left extension-based detection on.
            if AppPreferences.current?.detectsSyntaxByFileExtension ?? true {
                doc.language = LanguageDetector.detect(for: accessible)
            }
            didMoveAnyDocument = true
        }

        // Recents are a plain path list; rewrite any entry under the old path.
        var rewroteRecents = false
        var updatedRecents: [URL] = []
        for url in recentFiles {
            if let moved = movedURL(for: url) {
                rewroteRecents = true
                updatedRecents.append(moved)
            } else {
                updatedRecents.append(url)
            }
        }
        if rewroteRecents {
            // Keep it de-duplicated: the destination name may already be listed.
            var seen = Set<URL>()
            recentFiles = updatedRecents.filter { seen.insert($0.canonicalFileURL).inserted }
            persistRecentFiles()
        }

        if didMoveAnyDocument {
            // documents/activeDocumentID did not change identity, so neither
            // didSet fired — persist the new paths explicitly.
            persistSession()
        }
    }

    private func promptSaveAs(_ doc: Document) -> Bool {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.text]
        let initialDir = panel.directoryURL
            ?? FileManager.default.homeDirectoryForCurrentUser
        panel.nameFieldStringValue = uniqueFileName(for: defaultSaveName(for: doc), in: initialDir)
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return false }
        let url = urlByAddingDefaultTextExtensionIfNeeded(selectedURL)
        // Routed through prepareSave/commitSave rather than keeping a second,
        // drifting copy of the save logic. doc.url has to move first (that is
        // what prepareSave encodes for) and is put back if the write fails, so
        // a cancelled/failed Save As leaves the document exactly as it was.
        let previousURL = doc.url
        doc.url = url
        do {
            applyManualSaveTransforms(doc)
            guard let payload = try prepareSave(doc) else {
                doc.url = previousURL
                return false
            }
            try TextFileIO.writeData(payload.data, to: payload.url)
            // Only when the preference says the extension picks the language.
            // This used to re-detect unconditionally, so Save As threw away an
            // explicit language choice — and did it even for users who had
            // turned extension-based detection off.
            if AppPreferences.current?.detectsSyntaxByFileExtension ?? true {
                doc.language = LanguageDetector.detect(for: payload.url)
            }
            commitSave(doc, payload: payload)
            persistSession()
            return true
        } catch {
            doc.url = previousURL
            NSAlert.show(message: "Save failed: \(error.localizedDescription)", style: .critical)
            return false
        }
    }

    private func defaultSaveName(for doc: Document) -> String {
        let name = doc.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = name.isEmpty ? "Untitled" : name
        guard (fallback as NSString).pathExtension.isEmpty else { return fallback }
        return "\(fallback).txt"
    }

    private func urlByAddingDefaultTextExtensionIfNeeded(_ url: URL) -> URL {
        guard url.pathExtension.isEmpty else { return url }
        return url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent, isDirectory: false)
            .appendingPathExtension("txt")
    }

    /// Returns `name` if it doesn't exist in `dir`, otherwise appends
    /// `-YYYYMMDD-N` (incrementing N) until a free name is found.
    private func uniqueFileName(for name: String, in dir: URL) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appendingPathComponent(name).path) else { return name }
        let ns   = name as NSString
        let ext  = ns.pathExtension
        let base = ns.deletingPathExtension
        let date = { () -> String in
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; return f.string(from: Date())
        }()
        var counter = 1
        while true {
            let candidate = ext.isEmpty
                ? "\(base)-\(date)-\(counter)"
                : "\(base)-\(date)-\(counter).\(ext)"
            if !fm.fileExists(atPath: dir.appendingPathComponent(candidate).path) {
                return candidate
            }
            counter += 1
        }
    }

    private enum UnsavedChoice { case save, discard, cancel }

    private func presentUnsavedChangesAlert(for doc: Document) -> UnsavedChoice {
        let alert = NSAlert()
        alert.messageText = "Save changes to \"\(doc.displayName)\"?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .save
        case .alertSecondButtonReturn: return .discard
        default:                        return .cancel
        }
    }

    private func presentDiscardChangesAlert(for doc: Document) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Close \"\(doc.displayName)\"?"
        alert.informativeText = "Unsaved changes will be lost."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    func applicationShouldTerminate() -> NSApplication.TerminateReply {
        if AppPreferences.current?.askBeforeClosingUnsavedDocuments ?? true {
            for doc in documents where doc.isDirty {
                let choice = presentUnsavedChangesAlert(for: doc)
                switch choice {
                case .save:
                    if doc.url == nil {
                        guard promptSaveAs(doc) else { return .terminateCancel }
                    } else {
                        do {
                            try saveNow(doc)
                        } catch {
                            NSAlert.show(message: "Save failed: \(error.localizedDescription)", style: .critical)
                            return .terminateCancel
                        }
                    }
                case .discard:
                    deleteDraft(for: doc)
                    doc.isDirty = false
                case .cancel:
                    return .terminateCancel
                }
            }
        }

        flushDirtyDraftsImmediately()
        return .terminateNow
    }

    // MARK: - Recent files

    func openRecent(at index: Int) {
        guard recentFiles.indices.contains(index) else { return }
        _ = open(url: recentFiles[index])
    }

    func clearRecentFiles() {
        recentFiles.removeAll()
        persistRecentFiles()
    }

    private func addRecent(_ url: URL) {
        recentFiles.removeAll { $0 == url }
        recentFiles.insert(url, at: 0)
        if recentFiles.count > recentLimit {
            recentFiles = Array(recentFiles.prefix(recentLimit))
        }
        persistRecentFiles()
    }

    private func loadRecentFiles() {
        guard let paths = UserDefaults.standard.array(forKey: recentKey) as? [String] else { return }
        recentFiles = paths.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func persistRecentFiles() {
        let paths = recentFiles.map(\.path)
        UserDefaults.standard.set(paths, forKey: recentKey)
    }

    private func persistSession() {
        guard !isRestoringSession else { return }
        let defaults = UserDefaults.standard
        let paths = documents.compactMap { $0.url?.path }
        defaults.set(paths, forKey: sessionOpenFilesKey)

        if let activePath = activeDocument?.url?.path {
            defaults.set(activePath, forKey: sessionActiveFileKey)
        } else {
            defaults.removeObject(forKey: sessionActiveFileKey)
        }
    }

    // MARK: - Draft recovery

    func showDraftsFolder() {
        try? FileManager.default.createDirectory(
            at: draftsDirectory,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(draftsDirectory)
    }

    func recoveredDrafts() -> [RecoveredDraft] {
        decodedDraftRecords().map { record in
            let snapshot = record.snapshot
            return RecoveredDraft(
                id: record.draftID,
                displayName: snapshot.displayName,
                originalPath: snapshot.originalPath,
                encodingName: TextEncoding(rawValue: snapshot.encoding)?.displayName ?? snapshot.encoding,
                languageName: LanguageDetector.displayName(for: snapshot.language),
                savedAt: snapshot.savedAt,
                characterCount: record.text.count,
                preview: Self.previewText(from: record.text)
            )
        }
    }

    @discardableResult
    func openRecoveredDraft(_ draftID: RecoveredDraft.ID) -> Document? {
        guard let record = decodedDraftRecords().first(where: { $0.draftID == draftID }),
              let doc = restoreDraft(snapshot: record.snapshot, text: record.text)
        else { return nil }
        activeDocumentID = doc.id
        return doc
    }

    func deleteRecoveredDraft(_ draftID: RecoveredDraft.ID) {
        deleteDraftFiles(for: draftID)
    }

    func revealRecoveredDraft(_ draftID: RecoveredDraft.ID) {
        guard let record = decodedDraftRecords().first(where: { $0.draftID == draftID }) else {
            showDraftsFolder()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([record.metadataURL])
    }

    func scheduleAutoSave(for id: Document.ID, isEnabled: Bool, delay: TimeInterval) {
        autoSaveTasks[id]?.cancel()
        autoSaveTasks[id] = nil

        guard isEnabled,
              delay > 0,
              let doc = documents.first(where: { $0.id == id }),
              doc.isDirty,
              doc.url != nil
        else { return }

        autoSaveTasks[id] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }

            self?.performAutoSave(for: id)
        }
    }

    private func performAutoSave(for id: Document.ID) {
        // The pref can be switched off while this task is already sleeping, and
        // nothing cancels it — so it is re-read here rather than trusted from
        // when the task was scheduled.
        guard AppPreferences.current?.autoSaveEnabled ?? false else {
            autoSaveTasks[id] = nil
            return
        }
        guard let doc = documents.first(where: { $0.id == id }),
              doc.isDirty,
              doc.url != nil
        else {
            autoSaveTasks[id] = nil
            return
        }

        let payload: SavePayload?
        do {
            payload = try prepareSave(doc, rememberBookmark: false)
        } catch {
            autoSaveTasks[id] = nil
            Logger.app.error("Auto save failed for \(doc.displayName): \(error.localizedDescription)")
            return
        }
        guard let payload else {
            autoSaveTasks[id] = nil
            return
        }

        let name = doc.displayName
        // The atomic replace is the slow half and it needs nothing from the
        // main actor, so it runs off it. Auto save fires on a timer while the
        // user is typing; it used to write the whole file inline.
        autoSaveTasks[id] = Task { [weak self] in
            guard !Task.isCancelled else { return }
            do {
                try await Task.detached(priority: .utility) {
                    try TextFileIO.writeData(payload.data, to: payload.url)
                }.value
            } catch {
                self?.autoSaveTasks[id] = nil
                Logger.app.error("Auto save failed for \(name): \(error.localizedDescription)")
                return
            }

            guard let self, !Task.isCancelled else { return }
            self.autoSaveTasks[id] = nil
            guard let doc = self.documents.first(where: { $0.id == id }) else { return }

            // The bytes are on disk at payload.url. Whether they are still THIS
            // document's bytes is two questions:
            //   - is payload.url still the document's file? A Save As that ran
            //     while the write was in flight moved it, and commitSave would
            //     have set doc.url back to the old path.
            //   - is the text still the text we encoded? `revision` is bumped by
            //     `text.didSet`, so this catches an edit-and-edit-back too,
            //     which a string comparison does not.
            let isSameFile = doc.url?.canonicalFileURL == payload.url.canonicalFileURL
            guard isSameFile, doc.revision == payload.revision else {
                // Leave the document dirty; the next scheduleAutoSave writes the
                // new text. But the file's mtime moved because *we* wrote it —
                // without adopting it, the 4 s disk poll reports the app's own
                // auto save as an external change and offers to reload, which
                // discards the user's edits.
                if isSameFile {
                    self.captureDiskState(of: payload.url, into: doc)
                }
                return
            }
            self.commitSave(doc, payload: payload, isAutoSave: true)
            doc.lastAutoSavedAt = Date()
        }
    }

    func scheduleDraftSave(for id: Document.ID) {
        guard AppPreferences.current?.backupDocumentsWhileEditing ?? true else { return }
        guard let doc = documents.first(where: { $0.id == id }) else { return }
        scheduleDraftSaveIfDirty(for: doc)
    }

    private func scheduleDraftSaveIfDirty(for doc: Document) {
        guard AppPreferences.current?.backupDocumentsWhileEditing ?? true else {
            deleteDraft(for: doc)
            return
        }
        if !doc.isDirty {
            deleteDraft(for: doc)
            return
        }

        let id = doc.id
        let revisionID = UUID()
        draftSaveTasks[id]?.cancel()
        draftSaveRevisions[id] = revisionID
        draftSaveTasks[id] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_500_000_000)
            } catch {
                return
            }

            guard let self,
                  let payload = self.draftPayload(for: id, revisionID: revisionID)
            else { return }

            await Task.detached(priority: .utility) {
                Self.writeDraftPayload(payload)
            }.value

            self.cleanupDraftAfterWrite(
                documentID: id,
                draftID: payload.draftID,
                revisionID: payload.revisionID
            )
        }
    }

    private func draftPayload(for id: Document.ID, revisionID: UUID) -> DraftPayload? {
        guard let doc = documents.first(where: { $0.id == id }), doc.isDirty else { return nil }
        let draftID = doc.draftID
        let urls = draftURLs(for: draftID, revisionID: revisionID)
        let snapshot = DraftSnapshot(
            id: draftID.uuidString,
            revisionID: revisionID.uuidString,
            displayName: doc.displayName,
            originalPath: doc.url?.path,
            encoding: doc.encoding.rawValue,
            hasBOM: doc.hasBOM,
            language: doc.language,
            networkVendor: doc.networkVendor.rawValue,
            networkVendorIsManual: doc.networkVendorIsManual,
            indentation: doc.indentation.rawValue,
            lineEnding: doc.lineEnding.rawValue,
            showsInvisibleCharacters: doc.showsInvisibleCharacters,
            wordWrap: doc.wordWrap,
            autoTrimTrailingWhitespace: doc.autoTrimTrailingWhitespace,
            wasActive: activeDocumentID == doc.id,
            savedAt: Date(),
            textFileName: urls.text.lastPathComponent
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let snapshotData = try? encoder.encode(snapshot) else { return nil }
        return DraftPayload(
            draftID: draftID,
            revisionID: revisionID,
            snapshotData: snapshotData,
            text: doc.text,
            draftsDirectory: draftsDirectory,
            metadataURL: urls.metadata,
            textURL: urls.text
        )
    }

    private func cleanupDraftAfterWrite(documentID: Document.ID, draftID: UUID, revisionID: UUID) {
        guard let doc = documents.first(where: { $0.id == documentID }),
              doc.draftID == draftID,
              doc.isDirty
        else {
            deleteDraftFiles(for: draftID)
            return
        }

        guard draftSaveRevisions[documentID] == revisionID else { return }
        lastWrittenDraftRevisions[draftID] = revisionID
        doc.lastDraftSavedAt = Date()
        draftSaveTasks[documentID] = nil
        draftSaveRevisions[documentID] = nil
        removeOlderDraftFiles(for: draftID, keeping: revisionID)
    }

    func flushDirtyDraftsImmediately() {
        guard AppPreferences.current?.backupDocumentsWhileEditing ?? true else { return }
        for doc in documents where doc.isDirty {
            writeDraftImmediately(for: doc)
        }
    }

    private func writeDraftImmediately(for doc: Document) {
        let revisionID = UUID()
        draftSaveTasks[doc.id]?.cancel()
        draftSaveTasks[doc.id] = nil
        draftSaveRevisions[doc.id] = revisionID

        guard let payload = draftPayload(for: doc.id, revisionID: revisionID) else {
            draftSaveRevisions[doc.id] = nil
            return
        }

        Self.writeDraftPayload(payload)
        cleanupDraftAfterWrite(
            documentID: doc.id,
            draftID: payload.draftID,
            revisionID: payload.revisionID
        )
    }

    private func deleteDraft(for doc: Document) {
        draftSaveTasks[doc.id]?.cancel()
        draftSaveTasks[doc.id] = nil
        draftSaveRevisions[doc.id] = nil
        autoSaveTasks[doc.id]?.cancel()
        autoSaveTasks[doc.id] = nil
        deleteDraftFiles(for: doc.draftID)
    }

    /// Every save — including every auto save, so every few seconds while the
    /// user types — ends in here. When this process wrote the draft we know both
    /// of its filenames, so it is two `unlink`s instead of enumerating the whole
    /// drafts directory. Drafts left by a previous launch have no remembered
    /// revision and still take the scan.
    private func deleteDraftFiles(for draftID: UUID) {
        if let revisionID = lastWrittenDraftRevisions.removeValue(forKey: draftID) {
            let urls = draftURLs(for: draftID, revisionID: revisionID)
            try? FileManager.default.removeItem(at: urls.metadata)
            try? FileManager.default.removeItem(at: urls.text)
            return
        }

        let prefix = draftID.uuidString
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: draftsDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        for url in urls where url.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func removeOlderDraftFiles(for draftID: UUID, keeping revisionID: UUID) {
        let prefix = draftID.uuidString
        let currentPrefix = "\(draftID.uuidString)-\(revisionID.uuidString)"
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: draftsDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        for url in urls where url.lastPathComponent.hasPrefix(prefix) && !url.lastPathComponent.hasPrefix(currentPrefix) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func draftURLs(for draftID: UUID, revisionID: UUID) -> (metadata: URL, text: URL) {
        let base = "\(draftID.uuidString)-\(revisionID.uuidString)"
        return (
            draftsDirectory.appendingPathComponent("\(base).json", isDirectory: false),
            draftsDirectory.appendingPathComponent("\(base).txt", isDirectory: false)
        )
    }

    private var draftsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("SheepText", isDirectory: true)
            .appendingPathComponent("Drafts", isDirectory: true)
    }

    private nonisolated static func writeDraftPayload(_ payload: DraftPayload) {
        do {
            try FileManager.default.createDirectory(
                at: payload.draftsDirectory,
                withIntermediateDirectories: true
            )
            try payload.text.write(to: payload.textURL, atomically: true, encoding: .utf8)
            try payload.snapshotData.write(to: payload.metadataURL, options: .atomic)
        } catch {
            // Drafts are best-effort safety files. Normal save/open flows should
            // never be interrupted by a failed recovery write.
        }
    }

    private nonisolated static func previewText(from text: String) -> String {
        if text.count <= 8_000 {
            return text
        }
        return String(text.prefix(8_000)) + "\n..."
    }

    /// One `stat` per open document, on a background thread.
    ///
    /// This runs every four seconds from a timer in `MainWindowView`. It used to
    /// do all of it on the main actor, and the expensive part was not the stat:
    /// it called `SecurityScopedResourceAccess.prepare` per document, which
    /// copied the whole bookmark dictionary out of UserDefaults and resolved a
    /// bookmark — four seconds later, again, forever. The accessible URL is
    /// captured once when the document is opened, reloaded or saved
    /// (`Document.accessibleURL`), so the poll is now just the stats, and only
    /// documents whose file actually moved come back to the main actor.
    func checkForExternalChanges() {
        guard !isCheckingExternalChanges, !documents.isEmpty else { return }

        let probes: [DiskProbe] = documents.compactMap { doc in
            guard let url = doc.accessibleURL ?? doc.url else { return nil }
            return DiskProbe(id: doc.id, url: url)
        }
        guard !probes.isEmpty else { return }

        isCheckingExternalChanges = true
        Task { [weak self] in
            let states = await Task.detached(priority: .utility) {
                probes.map { probe in
                    let values = try? probe.url.resourceValues(
                        forKeys: [.contentModificationDateKey, .fileSizeKey]
                    )
                    return DiskState(
                        id: probe.id,
                        url: probe.url,
                        modificationDate: values?.contentModificationDate,
                        fileSize: values?.fileSize
                    )
                }
            }.value

            guard let self else { return }
            defer { self.isCheckingExternalChanges = false }
            self.applyDiskStates(states)
        }
    }

    private func applyDiskStates(_ states: [DiskState]) {
        for state in states {
            guard let doc = documents.first(where: { $0.id == state.id }),
                  let currentModificationDate = state.modificationDate
            else { continue }

            guard let knownModificationDate = doc.diskModificationDate else {
                doc.diskModificationDate = currentModificationDate
                doc.diskFileSize = state.fileSize
                continue
            }

            // `!=`, not "moved forward by more than a quarter second". A
            // `git checkout`, `cp -p` or `rsync -t` restores the *old* mtime, so
            // the file changed under the editor and the poll said nothing. The
            // size is checked too, for a same-second rewrite of a different
            // length.
            let changed = currentModificationDate != knownModificationDate
                || (state.fileSize != nil && state.fileSize != doc.diskFileSize)
            guard changed else { continue }

            if doc.isDirty {
                handleDirtyDocumentChangedOnDisk(
                    doc,
                    url: state.url,
                    modificationDate: currentModificationDate,
                    fileSize: state.fileSize
                )
            } else {
                reloadDocumentFromDisk(doc, url: state.url, modificationDate: currentModificationDate)
            }
        }
    }

    private nonisolated struct DiskProbe: Sendable {
        let id: Document.ID
        let url: URL
    }

    private nonisolated struct DiskState: Sendable {
        let id: Document.ID
        let url: URL
        let modificationDate: Date?
        let fileSize: Int?
    }

    /// One stat for both values, recorded together — the external-change poll
    /// compares them as a pair.
    private func captureDiskState(of url: URL, into doc: Document) {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        doc.diskModificationDate = values?.contentModificationDate
        doc.diskFileSize = values?.fileSize
    }

    private func handleDirtyDocumentChangedOnDisk(
        _ doc: Document,
        url: URL,
        modificationDate: Date,
        fileSize: Int?
    ) {
        if doc.externalChangeWarningDate == modificationDate { return }
        doc.externalChangeWarningDate = modificationDate

        let alert = NSAlert()
        alert.messageText = "\"\(doc.displayName)\" changed on disk."
        alert.informativeText = "This tab has unsaved edits. Reloading will discard your changes; keeping your edits may overwrite the disk version when you save."
        alert.addButton(withTitle: "Keep My Changes")
        alert.addButton(withTitle: "Reload from Disk")
        alert.alertStyle = .warning

        switch alert.runModal() {
        case .alertSecondButtonReturn:
            reloadDocumentFromDisk(doc, url: url, modificationDate: modificationDate)
        default:
            doc.diskModificationDate = modificationDate
            doc.diskFileSize = fileSize
        }
    }

    private func reloadDocumentFromDisk(_ doc: Document, url: URL, modificationDate: Date) {
        guard let decoded = try? TextFileIO.read(url: url) else { return }

        doc.text = decoded.text
        doc.savedText = decoded.text
        doc.encoding = decoded.encoding
        doc.hasBOM = decoded.hadBOM
        doc.lineEnding = TextLineEnding.detect(in: decoded.text)
        doc.indentation = TextIndentation.detect(in: decoded.text)
        doc.refreshLargeFileMetrics(byteCount: decoded.byteCount)
        doc.url = url
        doc.accessibleURL = url
        doc.language = LanguageDetector.detect(for: url)
        // `language` may not have changed, so its didSet may not have fired —
        // but the TEXT did, and the vendor is read off the text.
        doc.refreshDetectedNetworkVendor()
        doc.isDirty = false
        doc.wasRecoveredFromDraft = false
        captureDiskState(of: url, into: doc)
        doc.externalChangeWarningDate = nil
        deleteDraft(for: doc)

        NotificationCenter.default.post(
            name: .documentReloadedFromDisk,
            object: nil,
            userInfo: ["documentID": doc.id]
        )
    }

    private func fileSize(for url: URL) -> Int? {
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileSizeKey]) {
            return values.fileSize ?? values.totalFileSize
        }
        return nil
    }

    /// Returns true when the user chose to open it anyway. Defaults to Cancel:
    /// the destructive outcome here is silent and unrecoverable, so it should
    /// not be one Return keypress away.
    private func presentBinaryFileAlert(for url: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = "\(url.lastPathComponent) does not look like a text file."
        alert.informativeText = "It contains bytes that text files do not. SheepText can show it, but the contents will be mangled, and saving would overwrite the original with that mangled text."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open Anyway")
        alert.alertStyle = .warning
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func presentHugeFileAlert(for url: URL, byteCount: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Open large file?"
        alert.informativeText = "\(url.lastPathComponent) is \(LargeFilePolicy.byteCountLabel(byteCount)). SheepText will open it in Large File Mode with syntax highlighting and live compare refresh disabled."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Re-open last session's tabs and recover any drafts.
    ///
    /// **Contract (this is what makes launch-with-a-file work).** Launch order
    /// is: `restoreSessionTabs()` first, `openExternalFileURLs(_:)` second, even
    /// when the app was launched by double-clicking a file in Finder. So this
    /// must be safe to call with documents already open and must not clobber the
    /// stored session:
    ///
    ///   - It restores only tabs that are not already open. `open(url:)` dedupes
    ///     by `canonicalFileURL`, so a launch file that is also in the session
    ///     ends up as one tab either way.
    ///   - It does not persist while restoring. `documents.didSet` and
    ///     `activeDocumentID.didSet` both call `persistSession`, which is
    ///     suppressed by `isRestoringSession`; it persists once at the end. That
    ///     is why the guard is on "already restored", not on "no documents":
    ///     opening a launch file first used to overwrite the whole remembered
    ///     session with that one path before this ever ran.
    ///   - It never steals focus from a tab the caller has already made active,
    ///     unless it recovered a draft that was active when the app quit.
    ///
    /// Calling it twice is a no-op.
    func restoreSessionTabs() {
        guard !hasRestoredSession else { return }
        hasRestoredSession = true

        let defaults = UserDefaults.standard
        let paths = defaults.stringArray(forKey: sessionOpenFilesKey) ?? []
        let alreadyOpen = Set(documents.compactMap { $0.url?.canonicalFileURL })
        let preexistingActiveID = activeDocumentID

        var seen = Set<String>()
        let urls = paths.compactMap { path -> URL? in
            guard !seen.contains(path) else { return nil }
            seen.insert(path)

            let url = SecurityScopedResourceAccess.restore(
                path: path,
                bookmarkKey: SecurityScopedResourceAccess.fileBookmarksKey
            )
            guard !alreadyOpen.contains(url.canonicalFileURL) else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else { return nil }
            return url
        }

        isRestoringSession = true
        for url in urls {
            _ = open(url: url, rememberRecent: false, showError: false)
        }

        let recoveredActiveID = restoreDrafts()

        if let recoveredActiveID {
            activeDocumentID = recoveredActiveID
        } else if let preexistingActiveID, containsDocument(preexistingActiveID) {
            // A launch file (or anything else the caller opened first) keeps the
            // focus it was given; the session's tabs come back behind it.
            activeDocumentID = preexistingActiveID
        } else if let activePath = defaults.string(forKey: sessionActiveFileKey),
           let active = documents.first(where: { $0.url?.path == activePath }) {
            activeDocumentID = active.id
        } else {
            activeDocumentID = documents.last?.id
        }

        if let active = documents.first(where: { $0.id == activeDocumentID }) {
            precomputeInitialHighlight(for: active, preferences: nil)
        }

        isRestoringSession = false
        persistSession()
    }

    private func restoreDrafts() -> Document.ID? {
        var activeRecoveredID: Document.ID?
        for record in decodedDraftRecords().reversed() {
            guard let doc = restoreDraft(snapshot: record.snapshot, text: record.text) else { continue }

            if record.snapshot.wasActive {
                activeRecoveredID = doc.id
            }
        }

        return activeRecoveredID
    }

    private func decodedDraftRecords() -> [DraftRecord] {
        let directory = draftsDirectory
        guard let metadataURLs = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter({ $0.pathExtension == "json" }) else {
            return []
        }

        let decoder = JSONDecoder()
        var latestByID: [UUID: DraftRecord] = [:]
        for metadataURL in metadataURLs {
            guard let data = try? Data(contentsOf: metadataURL),
                  let snapshot = try? decoder.decode(DraftSnapshot.self, from: data),
                  let draftID = UUID(uuidString: snapshot.id)
            else { continue }

            let textURL = directory.appendingPathComponent(snapshot.textFileName, isDirectory: false)
            guard let text = try? String(contentsOf: textURL, encoding: .utf8) else { continue }

            let record = DraftRecord(
                draftID: draftID,
                snapshot: snapshot,
                text: text,
                metadataURL: metadataURL
            )

            if let existing = latestByID[draftID], existing.snapshot.savedAt >= snapshot.savedAt {
                continue
            }
            latestByID[draftID] = record
        }

        return latestByID.values.sorted { $0.snapshot.savedAt > $1.snapshot.savedAt }
    }

    @discardableResult
    private func restoreDraft(snapshot: DraftSnapshot, text: String) -> Document? {
        guard let draftID = UUID(uuidString: snapshot.id) else { return nil }
        let encoding = TextEncoding(rawValue: snapshot.encoding) ?? .utf8
        let indentation = TextIndentation(rawValue: snapshot.indentation) ?? .defaultValue
        let lineEnding = TextLineEnding(rawValue: snapshot.lineEnding) ?? .lf
        let originalURL = snapshot.originalPath.map { URL(fileURLWithPath: $0) }
        let restoredURL = originalURL.flatMap { url -> URL? in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else { return nil }
            return SecurityScopedResourceAccess.restore(
                path: url.path,
                bookmarkKey: SecurityScopedResourceAccess.fileBookmarksKey
            )
        }

        let doc: Document
        let isNewDocument: Bool
        if let existing = documents.first(where: { $0.draftID == draftID }) {
            doc = existing
            isNewDocument = false
        } else if let restoredURL,
                  let existing = documents.first(where: { $0.url?.canonicalFileURL == restoredURL.canonicalFileURL }) {
            doc = existing
            doc.url = restoredURL
            isNewDocument = false
        } else {
            doc = Document(
                id: draftID,
                url: restoredURL,
                initialText: text,
                encoding: encoding,
                hasBOM: snapshot.hasBOM
            )
            documents.append(doc)
            isNewDocument = true
        }

        doc.draftID = draftID
        doc.text = text

        if isNewDocument {
            // Document.init seeds savedText from initialText, which here is the
            // DRAFT — so the gutter would compare the recovered text against
            // itself and show no unsaved-change bars at all. The baseline the user
            // wants is what is actually on disk. nil (no bars) when the file is
            // gone or unreadable, which is the honest answer.
            doc.savedText = restoredURL.flatMap { try? TextFileIO.read(url: $0).text }
        }
        // Documents reused from the session restore already carry the on-disk text
        // as their baseline — leave it alone.
        doc.encoding = encoding
        doc.hasBOM = snapshot.hasBOM
        doc.language = snapshot.language
        // Order matters: `language`'s didSet re-detects, so the remembered pick
        // is applied after it.
        if let manual = snapshot.networkVendorIsManual, manual,
           let raw = snapshot.networkVendor, let vendor = Vendor(rawValue: raw) {
            doc.networkVendorIsManual = true
            doc.networkVendor = vendor
        } else {
            doc.networkVendorIsManual = false
            doc.refreshDetectedNetworkVendor()
        }
        doc.indentation = indentation
        doc.lineEnding = lineEnding
        doc.showsInvisibleCharacters = snapshot.showsInvisibleCharacters
        doc.wordWrap = snapshot.wordWrap
        doc.autoTrimTrailingWhitespace = snapshot.autoTrimTrailingWhitespace
        doc.isDirty = true
        doc.wasRecoveredFromDraft = true
        doc.lastDraftSavedAt = snapshot.savedAt
        doc.lastAutoSavedAt = nil
        doc.refreshLargeFileMetrics(byteCount: nil)
        doc.accessibleURL = doc.url
        if let url = doc.url { captureDiskState(of: url, into: doc) } else { doc.diskModificationDate = nil }
        doc.externalChangeWarningDate = nil
        return doc
    }

    /// Kept as the name the UI calls; it is `close` now. See `close` for why
    /// the second copy of the close logic that used to live here is gone.
    @discardableResult
    func requestCloseTabFromUI(_ id: Document.ID) -> Bool {
        close(id)
    }
}

struct RecoveredDraft: Identifiable, Hashable {
    let id: UUID
    let displayName: String
    let originalPath: String?
    let encodingName: String
    let languageName: String
    let savedAt: Date
    let characterCount: Int
    let preview: String

    var pathDisplay: String {
        guard let originalPath else { return "Untitled draft" }
        let url = URL(fileURLWithPath: originalPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            let name = url.lastPathComponent.isEmpty ? "Original file" : url.lastPathComponent
            return "\(name) (original file unavailable)"
        }
        return originalPath
    }
}

private struct DraftRecord {
    let draftID: UUID
    let snapshot: DraftSnapshot
    let text: String
    let metadataURL: URL
}

private struct DraftSnapshot: Codable, Sendable {
    let id: String
    let revisionID: String?
    let displayName: String
    let originalPath: String?
    let encoding: String
    let hasBOM: Bool
    let language: String
    /// Both optional so a draft written before the `network_config` merge still
    /// decodes — the synthesized decoder throws on a MISSING key, and a draft is
    /// the one thing here that outlives a version bump.
    let networkVendor: String?
    let networkVendorIsManual: Bool?
    let indentation: String
    let lineEnding: String
    let showsInvisibleCharacters: Bool
    let wordWrap: Bool
    let autoTrimTrailingWhitespace: Bool
    let wasActive: Bool
    let savedAt: Date
    let textFileName: String
}

private struct DraftPayload: Sendable {
    let draftID: UUID
    let revisionID: UUID
    let snapshotData: Data
    let text: String
    let draftsDirectory: URL
    let metadataURL: URL
    let textURL: URL
}

// MARK: - Document

nonisolated struct HighlightLanguage: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
}

nonisolated enum TextLineEnding: String, CaseIterable, Identifiable, Sendable {
    case lf
    case crlf
    case cr

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lf:   return "LF"
        case .crlf: return "CRLF"
        case .cr:   return "CR"
        }
    }

    var sequence: String {
        switch self {
        case .lf:   return "\n"
        case .crlf: return "\r\n"
        case .cr:   return "\r"
        }
    }

    /// How many line breaks are enough to call it. Past this the counts cannot
    /// change the answer in any real file, and this runs on open, on reload and
    /// on every indentation change — over the whole document.
    private static let lineEndingVoteLimit = 4096

    /// Byte state machine over the UTF-8 view.
    ///
    /// It used to call `NSString.character(at:)` in a loop, which is an
    /// objc_msgSend per UTF-16 unit across the whole file: 43 ms on 10 MB
    /// against 11.8 ms for the byte scan. `\r` and `\n` are single bytes that
    /// cannot appear inside a multi-byte UTF-8 sequence, so scanning bytes gives
    /// exactly the same counts.
    static func detect(in text: String) -> TextLineEnding {
        var lf = 0
        var crlf = 0
        var cr = 0
        var sawCR = false
        var breaks = 0

        for byte in text.utf8 {
            if sawCR {
                sawCR = false
                if byte == 0x0A {
                    crlf += 1
                    breaks += 1
                    if breaks >= Self.lineEndingVoteLimit { break }
                    continue
                }
                cr += 1
                breaks += 1
                if breaks >= Self.lineEndingVoteLimit { break }
            }
            if byte == 0x0D {
                sawCR = true
            } else if byte == 0x0A {
                lf += 1
                breaks += 1
                if breaks >= Self.lineEndingVoteLimit { break }
            }
        }
        if sawCR { cr += 1 }

        if crlf >= lf, crlf >= cr, crlf > 0 { return .crlf }
        if cr > lf, cr > 0 { return .cr }
        return .lf
    }
}

nonisolated enum TextIndentation: String, CaseIterable, Identifiable, Sendable {
    case spaces4
    case spaces2
    case spaces8
    case tabs

    static let defaultValue: TextIndentation = .spaces4

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .spaces2: return "Spaces: 2"
        case .spaces4: return "Spaces: 4"
        case .spaces8: return "Spaces: 8"
        case .tabs:    return "Tabs"
        }
    }

    var insertionString: String {
        switch self {
        case .spaces2: return "  "
        case .spaces4: return "    "
        case .spaces8: return "        "
        case .tabs:    return "\t"
        }
    }

    var unitWidth: Int {
        switch self {
        case .spaces2: return 2
        case .spaces4: return 4
        case .spaces8: return 8
        case .tabs:    return 4
        }
    }

    /// Lines sampled before deciding. Unchanged — only how they are reached is.
    private static let indentationSampleLines = 400

    static func detect(in text: String, allowSpaces2: Bool = false) -> TextIndentation {
        var tabLines = 0
        var space2Lines = 0
        var space4Lines = 0
        var space8Lines = 0

        // Only the first 400 lines are ever looked at, but this used to reach
        // them with `text.components(separatedBy: "\n").prefix(400)` — which
        // splits the ENTIRE file into an array of Strings first, then throws all
        // but 400 of them away. 80.9 ms on a 10 MB file, on the main actor,
        // inside `Document.init`, i.e. on every open.
        //
        // Forward scan over the UTF-8 view instead, stopping at line 400. `\n`,
        // `\r`, space and tab are all single bytes that cannot occur inside a
        // multi-byte sequence, and only the leading whitespace of each line is
        // inspected, so the counts are identical to the old ones.
        var lines = 0
        var spaces = 0
        var sawTab = false
        var inLeadingWhitespace = true

        func finishLine() {
            if sawTab {
                tabLines += 1
            } else if spaces >= 8, spaces % 8 == 0 {
                space8Lines += 1
            } else if spaces >= 4, spaces % 4 == 0 {
                space4Lines += 1
            } else if spaces >= 2, spaces % 2 == 0 {
                space2Lines += 1
            }
            lines += 1
            spaces = 0
            sawTab = false
            inLeadingWhitespace = true
        }

        for byte in text.utf8 {
            if byte == 0x0A {   // end of line
                finishLine()
                if lines >= Self.indentationSampleLines { break }
                continue
            }
            guard inLeadingWhitespace else { continue }
            switch byte {
            case 0x09:                       // tab
                sawTab = true
                inLeadingWhitespace = false
            case 0x20:                       // space
                spaces += 1
            default:
                // Includes the \r of a CRLF pair, which is not indentation and
                // ends the leading run exactly as the old Character loop did.
                inLeadingWhitespace = false
            }
        }
        // `components(separatedBy:)` yields a final (possibly empty) element
        // after the last newline; count it the same way.
        if lines < Self.indentationSampleLines { finishLine() }

        let spaceLines = space2Lines + space4Lines + space8Lines
        if tabLines > spaceLines { return .tabs }
        if space8Lines > space4Lines, space8Lines > space2Lines { return .spaces8 }
        if allowSpaces2, space2Lines > space4Lines { return .spaces2 }
        return Self.defaultValue
    }
}

nonisolated enum TextContentTransforms {
    static func normalizeLineEndingsToLF(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    static func convertLineEndings(in text: String, to lineEnding: TextLineEnding) -> String {
        normalizeLineEndingsToLF(text).replacingOccurrences(of: "\n", with: lineEnding.sequence)
    }

    static func trimTrailingWhitespace(in text: String, lineEnding: TextLineEnding) -> String {
        let normalized = normalizeLineEndingsToLF(text)
        let hasFinalNewline = normalized.hasSuffix("\n")
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if hasFinalNewline, !lines.isEmpty {
            lines.removeLast()
        }

        let trimmed = lines.map { line in
            String(line.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed())
        }
        return trimmed.joined(separator: lineEnding.sequence) + (hasFinalNewline ? lineEnding.sequence : "")
    }

    static func convertIndentation(in text: String, to indentation: TextIndentation) -> String {
        let normalized = normalizeLineEndingsToLF(text)
        let hasFinalNewline = normalized.hasSuffix("\n")
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if hasFinalNewline, !lines.isEmpty {
            lines.removeLast()
        }

        let sourceIndentation = TextIndentation.detect(in: text, allowSpaces2: true)
        let converted = lines.map {
            convertLeadingIndent(in: $0, from: sourceIndentation, to: indentation)
        }
        let lineEnding = TextLineEnding.detect(in: text)
        return converted.joined(separator: lineEnding.sequence) + (hasFinalNewline ? lineEnding.sequence : "")
    }

    static func sortLines(in text: String, lineEnding: TextLineEnding) -> String {
        transformLines(in: text, lineEnding: lineEnding) {
            $0.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }

    static func removeDuplicateLines(in text: String, lineEnding: TextLineEnding) -> String {
        transformLines(in: text, lineEnding: lineEnding) { lines in
            var seen = Set<String>()
            var result: [String] = []
            for line in lines where !seen.contains(line) {
                seen.insert(line)
                result.append(line)
            }
            return result
        }
    }

    private static func transformLines(
        in text: String,
        lineEnding: TextLineEnding,
        transform: ([String]) -> [String]
    ) -> String {
        let normalized = normalizeLineEndingsToLF(text)
        let hasFinalNewline = normalized.hasSuffix("\n")
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if hasFinalNewline, !lines.isEmpty {
            lines.removeLast()
        }
        return transform(lines).joined(separator: lineEnding.sequence) + (hasFinalNewline ? lineEnding.sequence : "")
    }

    private static func convertLeadingIndent(
        in line: String,
        from sourceIndentation: TextIndentation,
        to targetIndentation: TextIndentation
    ) -> String {
        let sourceWidth = max(sourceIndentation.unitWidth, 1)
        var columnCount = 0
        var tabLevels = 0
        var bodyStart = line.startIndex

        while bodyStart < line.endIndex {
            let character = line[bodyStart]
            if character == " " {
                columnCount += 1
            } else if character == "\t" {
                if sourceIndentation == .tabs {
                    tabLevels += 1
                } else {
                    columnCount += sourceWidth
                }
            } else {
                break
            }
            bodyStart = line.index(after: bodyStart)
        }

        let body = String(line[bodyStart...])
        let levels = tabLevels + columnCount / sourceWidth
        let extraSpaces = columnCount % sourceWidth

        switch targetIndentation {
        case .tabs:
            return String(repeating: "\t", count: levels)
                + String(repeating: " ", count: extraSpaces)
                + body
        case .spaces2:
            return String(repeating: " ", count: levels * targetIndentation.unitWidth + extraSpaces) + body
        case .spaces4:
            return String(repeating: " ", count: levels * targetIndentation.unitWidth + extraSpaces) + body
        case .spaces8:
            return String(repeating: " ", count: levels * targetIndentation.unitWidth + extraSpaces) + body
        }
    }
}

struct LargeFileMetrics {
    let byteCount: Int?
    let lineCount: Int
    let exceedsLineThreshold: Bool
}

enum LargeFilePolicy {
    static let byteThreshold = 10 * 1024 * 1024
    static let lineThreshold = 100_000
    static let characterThreshold = 1_000_000
    static let hugeFileByteThreshold = 100 * 1024 * 1024
    static let largeFindMatchLimit = 50_000

    static func metrics(for text: String, byteCount: Int?) -> LargeFileMetrics {
        let lineMetrics = lineCount(in: text, stopAfter: lineThreshold)
        return LargeFileMetrics(
            byteCount: byteCount,
            lineCount: lineMetrics.count,
            exceedsLineThreshold: lineMetrics.exceededLimit
        )
    }

    static func isLarge(byteCount: Int?, lineCount: Int, exceedsLineThreshold: Bool, textUTF16Count: Int) -> Bool {
        if let byteCount, byteCount >= byteThreshold { return true }
        if exceedsLineThreshold || lineCount >= lineThreshold { return true }
        return textUTF16Count >= characterThreshold
    }

    static func reason(byteCount: Int?, lineCount: Int, exceedsLineThreshold: Bool, textUTF16Count: Int) -> String? {
        if let byteCount, byteCount >= byteThreshold {
            return "\(byteCountLabel(byteCount)) on disk"
        }
        if exceedsLineThreshold || lineCount >= lineThreshold {
            return "\(lineCount.formatted())+ lines"
        }
        if textUTF16Count >= characterThreshold {
            return "\(textUTF16Count.formatted()) characters"
        }
        return nil
    }

    static func byteCountLabel(_ byteCount: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    /// Counts newlines over the UTF-8 view, not over Characters.
    ///
    /// `for character in text { character == "\n" }` never fires on a CRLF file:
    /// Swift treats "\r\n" as a single extended grapheme cluster, which is not
    /// equal to "\n". A 500 000-line CRLF file therefore reported ONE line and
    /// never entered large-file mode unless it also crossed the byte threshold.
    /// Scanning bytes also skips grapheme breaking, which is the expensive part.
    private static func lineCount(in text: String, stopAfter limit: Int) -> (count: Int, exceededLimit: Bool) {
        var count = 1
        for byte in text.utf8 where byte == 0x0A {
            count += 1
            if count > limit {
                return (count, true)
            }
        }
        return (count, false)
    }
}

@Observable
final class Document: Identifiable {
    let id: UUID
    var draftID: UUID
    var url: URL?
    var text: String {
        didSet {
            // `(text as NSString).length`, NOT `text.utf16.count`.
            //
            // The editor assigns a freshly bridged NSString here on every
            // keystroke (`fullText` → `textStorage.string`), and a bridged
            // string has no breadcrumb index yet — so `utf16.count` transcoded
            // the whole document to count it. Measured on Thai text (where the
            // UTF-16 and UTF-8 lengths differ, so there is no shortcut): 1.07 ms
            // per keystroke at 800 KB, 5.9 ms at 4 MB. The NSString length is a
            // stored field on the bridged object: 0.0001 ms. `init` was already
            // doing it this way.
            textUTF16Count = (text as NSString).length
            revision &+= 1
        }
    }

    /// Bumped on every assignment to `text`. Auto save encodes on the main actor
    /// and writes off it; the continuation compares this against the value it
    /// captured to know whether the document it finds is still the one it
    /// encoded. A string comparison cannot see an edit-and-edit-back, and on a
    /// large document it is not free either.
    ///
    /// @ObservationIgnored for the same reason as `textUTF16Count`: it changes
    /// on every keystroke and nothing renders it.
    @ObservationIgnored private(set) var revision: Int = 0

    /// UTF-16 length of `text`, refreshed once per assignment.
    ///
    /// `isLargeFileModeActive` needs it, and that property is read on every
    /// keystroke by the compare pipeline, once per gutter redraw, once per
    /// invisible-character draw, and from SwiftUI view bodies. Computing
    /// `text.utf16.count` at each of those was a full scan of the document for any
    /// non-ASCII text — i.e. for anything Thai, where the UTF-16 length is not the
    /// UTF-8 length and Swift has no O(1) shortcut.
    ///
    /// Deliberately @ObservationIgnored: this changes on every keystroke, and
    /// letting SwiftUI track it would re-evaluate every body that consults
    /// isLargeFileModeActive on every character typed — which is exactly the cost
    /// this is meant to remove. Large-file mode only ever flips on open, reload or
    /// save, and those paths also touch observable properties.
    @ObservationIgnored private(set) var textUTF16Count: Int = 0

    var isDirty: Bool = false
    var wasRecoveredFromDraft: Bool = false
    var lastDraftSavedAt: Date?
    var lastAutoSavedAt: Date?
    var language: String {
        didSet {
            guard language != oldValue else { return }
            refreshDetectedNetworkVendor()
        }
    }
    /// The device family `network_config` highlights this document as.
    ///
    /// Detection is a 64 KB byte scan of the head of the file, run wherever the
    /// language is decided. `networkVendorIsManual` is what makes the user's own
    /// pick stick: nothing re-detects over it until they ask for Auto again.
    var networkVendor: Vendor = .auto
    var networkVendorIsManual: Bool = false
    var encoding: TextEncoding
    var indentation: TextIndentation
    var lineEnding: TextLineEnding
    var fileByteCount: Int?
    var estimatedLineCount: Int
    var exceedsLargeLineThreshold: Bool
    var showsInvisibleCharacters: Bool = false
    var wordWrap: Bool = true
    var autoTrimTrailingWhitespace: Bool = false
    var diskModificationDate: Date?
    /// Size on disk as of `diskModificationDate`. The external-change poll
    /// compares both: an mtime-preserving rewrite (git checkout, cp -p, rsync -t)
    /// changes only this one.
    var diskFileSize: Int?
    /// The URL instance that holds this document's security scope, captured when
    /// it was opened, reloaded or saved. The 4-second disk poll stats through
    /// this instead of resolving a bookmark per document per tick.
    /// @ObservationIgnored: nothing renders it, and it moves with `url`.
    @ObservationIgnored var accessibleURL: URL?
    var externalChangeWarningDate: Date?
    var precomputedSyntaxHighlight: PrecomputedSyntaxHighlight?
    /// Whether the file had a BOM when read; preserved on save. For UTF-8
    /// files without a BOM, this stays false — don't add one silently.
    var hasBOM: Bool

    /// Tree-sitter tree, opaque here. Kept for future use by the Neon
    /// upgrade; unused today.
    var syntaxTreeHandle: SyntaxTreeHandle?

    /// Text at last save (or at open for disk files). nil for untitled docs.
    var savedText: String?

    init(id: UUID = UUID(), url: URL?, initialText: String, encoding: TextEncoding, hasBOM: Bool, byteCount: Int? = nil) {
        let metrics = LargeFilePolicy.metrics(for: initialText, byteCount: byteCount)
        self.id       = id
        self.draftID  = id
        self.url      = url
        self.text     = initialText
        self.textUTF16Count = (initialText as NSString).length
        self.language = LanguageDetector.detect(for: url)
        self.encoding = encoding
        self.hasBOM   = hasBOM
        self.indentation = TextIndentation.detect(in: initialText)
        self.lineEnding = TextLineEnding.detect(in: initialText)
        self.fileByteCount = metrics.byteCount
        self.estimatedLineCount = metrics.lineCount
        self.exceedsLargeLineThreshold = metrics.exceedsLineThreshold
        self.savedText = url != nil ? initialText : nil
        refreshDetectedNetworkVendor()
    }

    /// Re-run the vendor fingerprint. No-op once the user has picked a vendor
    /// by hand, and for any document that is not a network config.
    ///
    /// Called from `init`, from `language`'s `didSet` and from the reload path —
    /// never from `text`'s `didSet`, which fires on every keystroke.
    func refreshDetectedNetworkVendor() {
        guard !networkVendorIsManual else { return }
        guard NetworkConfigLanguage.isNetworkConfig(language) else {
            networkVendor = .auto
            return
        }
        if let fixed = NetworkConfigLanguage.aliasVendor(for: language) {
            networkVendor = fixed
            return
        }
        networkVendor = NetworkConfigLanguage.detectVendor(in: text)
            ?? LanguageDetector.fallbackNetworkVendor(for: url)
    }

    /// The id the syntax engine is asked for: the language plus, for a network
    /// config, the vendor.
    var syntaxLanguage: String {
        NetworkConfigLanguage.engineLanguage(for: language, vendor: networkVendor)
    }

    var displayName: String {
        url?.lastPathComponent ?? "Untitled"
    }

    var isLargeFileModeActive: Bool {
        LargeFilePolicy.isLarge(
            byteCount: fileByteCount,
            lineCount: estimatedLineCount,
            exceedsLineThreshold: exceedsLargeLineThreshold,
            textUTF16Count: textUTF16Count
        )
    }

    var largeFileModeDetail: String? {
        LargeFilePolicy.reason(
            byteCount: fileByteCount,
            lineCount: estimatedLineCount,
            exceedsLineThreshold: exceedsLargeLineThreshold,
            textUTF16Count: textUTF16Count
        )
    }

    func refreshLargeFileMetrics(byteCount: Int?) {
        let metrics = LargeFilePolicy.metrics(for: text, byteCount: byteCount)
        fileByteCount = metrics.byteCount
        estimatedLineCount = metrics.lineCount
        exceedsLargeLineThreshold = metrics.exceedsLineThreshold
    }
}

struct PrecomputedSyntaxHighlight {
    let language: String
    let utf16Length: Int
    let textHash: Int
    let runs: [HighlightRun]
}

// MARK: - Language detection (unchanged from before)

enum LanguageDetector {
    static let supportedLanguages: [HighlightLanguage] = [
        HighlightLanguage(id: "plaintext", displayName: "Plain Text"),
        HighlightLanguage(id: "log", displayName: "Log"),
        HighlightLanguage(id: "swift", displayName: "Swift"),
        HighlightLanguage(id: "json", displayName: "JSON"),
        HighlightLanguage(id: "yaml", displayName: "YAML"),
        HighlightLanguage(id: "markdown", displayName: "Markdown"),
        HighlightLanguage(id: "html", displayName: "HTML"),
        HighlightLanguage(id: "css", displayName: "CSS"),
        HighlightLanguage(id: "javascript", displayName: "JavaScript"),
        HighlightLanguage(id: "typescript", displayName: "TypeScript"),
        HighlightLanguage(id: "python", displayName: "Python"),
        HighlightLanguage(id: "go", displayName: "Go"),
        HighlightLanguage(id: "rust", displayName: "Rust"),
        HighlightLanguage(id: "bash", displayName: "Shell"),
        HighlightLanguage(id: "ruby", displayName: "Ruby"),
        HighlightLanguage(id: "java", displayName: "Java"),
        HighlightLanguage(id: "c", displayName: "C"),
        HighlightLanguage(id: "csharp", displayName: "C#"),
        HighlightLanguage(id: "toml", displayName: "TOML"),
        HighlightLanguage(id: "xml", displayName: "XML"),
        HighlightLanguage(id: "elixir", displayName: "Elixir"),
        HighlightLanguage(id: "scala", displayName: "Scala"),
        HighlightLanguage(id: "haskell", displayName: "Haskell"),
        HighlightLanguage(id: "php", displayName: "PHP"),
        HighlightLanguage(id: "sql", displayName: "SQL"),
        HighlightLanguage(id: "diff", displayName: "Diff"),
        HighlightLanguage(id: "dockerfile", displayName: "Dockerfile"),
        // One entry for every device family. `cisco_ios` and `aruba_cx` are
        // still accepted as ids (they are vendor aliases) but they are not
        // separate languages any more: the vendor badge next to this menu is
        // where a family is chosen.
        HighlightLanguage(id: NetworkConfigLanguage.id,
                          displayName: NetworkConfigLanguage.displayName)
    ]

    /// The order the status bar lists device families in — the language menu's
    /// network section and the vendor badge both read it. Aruba CX first
    /// because that is the family this user works in most; the rest follow
    /// SheepTerm's `Vendor.allCases` order. `.auto` is not in here: the menus
    /// spell it "Auto-detect" and place it themselves.
    static let networkVendorMenuOrder: [Vendor] = [
        .arubaCX, .cisco, .arubaOS, .huawei, .comware,
        .juniper, .panos, .fortios, .gaia, .linux
    ]

    /// Languages other than `network_config`, for the lower half of the menu.
    static var nonNetworkLanguages: [HighlightLanguage] {
        supportedLanguages.filter { $0.id != NetworkConfigLanguage.id }
    }

    /// The vendor a network config falls back to when the fingerprint finds no
    /// signature. `.cfg`, `.ios` and `.cisco` meant `cisco_ios` in every release
    /// up to 1.3.6, and the package's signatures are deliberately long,
    /// unambiguous strings (`boot-start-marker`, `current configuration :`) — a
    /// saved fragment of interface blocks carries none of them. Without this a
    /// 15 000-line `.cfg` of `switchport` lines opened on `.auto`, lost the
    /// `vlan 306s` / `spanning-tree mode rpvsts` validators, and was a
    /// regression for exactly the files this language existed for. `.conf` and
    /// `.txt` stay on `.auto`: they never implied a vendor.
    ///
    /// This is still a DETECTED vendor: a Huawei banner in a `.cfg` wins, and the
    /// badge can change it.
    static func fallbackNetworkVendor(for url: URL?) -> Vendor {
        switch url?.pathExtension.lowercased() {
        case "cfg", "ios", "cisco": return .cisco
        default: return .auto
        }
    }

    static func detect(for url: URL?) -> String {
        let filename = url?.lastPathComponent.lowercased() ?? ""
        if filename == "dockerfile" || filename.hasPrefix("dockerfile.") {
            return "dockerfile"
        }

        guard let ext = url?.pathExtension.lowercased() else { return "plaintext" }
        switch ext {
        case "log", "cof", "config":     return "log"
        case "swift":                    return "swift"
        case "js", "mjs", "cjs", "jsx":  return "javascript"
        // "tsx" stays on the TypeScript grammar deliberately: a .tsx file is
        // TypeScript, and the tsx-specific grammar is not vendored. The JSX in
        // it highlights imperfectly, which is better than plain text.
        case "ts", "tsx":                return "typescript"
        case "py":                       return "python"
        case "go":                       return "go"
        case "rs":                       return "rust"
        case "rb":                       return "ruby"
        case "java":                     return "java"
        case "c", "h":                   return "c"
        case "cs":                       return "csharp"
        case "toml":                     return "toml"
        case "ex", "exs":                return "elixir"
        case "scala", "sc":              return "scala"
        case "hs", "lhs":                return "haskell"
        case "php", "phtml":             return "php"
        case "json":                     return "json"
        case "md", "markdown":           return "markdown"
        case "html", "htm":              return "html"
        case "css":                      return "css"
        case "xml":                      return "xml"
        case "sql":                      return "sql"
        case "diff", "patch":            return "diff"
        case "dockerfile":               return "dockerfile"
        case "yml", "yaml":              return "yaml"
        case "sh", "bash", "zsh":        return "bash"
        // `.txt` and `.conf` are here because that is what a saved `show run`
        // or `display current-configuration` actually gets called. With no
        // vendor signature the document stays on `.auto`, which colours only
        // literal values — addresses, masks, MACs, VLAN ids, state words — so a
        // plain text file still reads as plain text.
        case _ where NetworkConfigLanguage.fileExtensions.contains(ext):
            return NetworkConfigLanguage.id
        // Unambiguous vendor extensions keep their alias: the family is in the
        // filename, so there is nothing to fingerprint.
        case "cx", "aoscx", "aruba", "arubacx": return "aruba_cx"
        default:                         return "plaintext"
        }
    }

    static func displayName(for language: String) -> String {
        let normalized = normalizedLanguage(language)
        // The aliases are not in `supportedLanguages`, and `capitalized` would
        // render one as "Cisco_ios".
        if NetworkConfigLanguage.isNetworkConfig(normalized) {
            return NetworkConfigLanguage.displayName
        }
        return supportedLanguages.first(where: { $0.id == normalized })?.displayName
            ?? normalized.capitalized
    }

    static func normalizedLanguage(_ language: String) -> String {
        let normalized = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? "plaintext" : normalized
    }
}

/// Opaque handle for future Tree-sitter integration.
struct SyntaxTreeHandle {
    let pointer: OpaquePointer
}

// MARK: - NSAlert convenience

private extension NSAlert {
    @MainActor
    static func show(message: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = style
        alert.runModal()
    }
}
