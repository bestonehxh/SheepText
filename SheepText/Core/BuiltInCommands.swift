//
//  BuiltInCommands.swift
//  All commands the core ships with. Plugins can override by registering
//  the same id (last writer wins).
//

import Foundation
import AppKit

@MainActor
enum BuiltInCommands {

    static func registerAll(
        into registry: CommandRegistry,
        workspace: WorkspaceStore,
        documents: DocumentStore,
        palette: CommandPaletteController
    ) {
        // Wire up the menu-bar bridge.
        CommandBus.shared.registry = registry

        // File
        registry.register(id: "file.open", title: "File: Open Folder…") { _ in
            workspace.promptOpenFolder()
        }
        registry.register(id: "workspace.clearRecent", title: "Workspace: Clear Recent Folders") { _ in
            workspace.clearRecentWorkspaces()
        }
        registry.register(id: "file.openFiles", title: "File: Open File…") { _ in
            for url in workspace.promptOpenFiles() {
                documents.open(url: url)
            }
        }
        registry.register(id: "file.new", title: "File: New") { _ in
            documents.newUntitled()
        }
        registry.register(id: "file.save", title: "File: Save") { _ in
            guard let id = saveTargetDocumentID(documents) else { return }
            trimDocumentIfNeeded(id, in: documents)
            documents.save(id)
        }
        registry.register(id: "file.saveAll", title: "File: Save All") { _ in
            trimAllDirtyDocumentsIfNeeded(in: documents)
            documents.saveAllDirty()
        }
        registry.register(id: "file.saveAs", title: "File: Save As…") { _ in
            guard let id = saveTargetDocumentID(documents) else { return }
            trimDocumentIfNeeded(id, in: documents)
            documents.saveAs(id)
        }
        registry.register(id: "file.close", title: "File: Close Tab") { _ in
            guard let id = documents.activeDocumentID else { return }
            _ = documents.close(id)
        }
        registry.register(id: "file.closeAll", title: "File: Close All Tabs  ⌥⌘W") { _ in
            documents.closeAllTabs()
        }
        registry.register(id: "file.closeSaved", title: "File: Close Saved Tabs") { _ in
            documents.closeSavedTabs()
        }
        registry.register(id: "file.closeOther", title: "File: Close Other Tabs") { _ in
            documents.closeOtherTabs()
        }
        registry.register(id: "file.recoveredDrafts", title: "File: Recovered Drafts…") { _ in
            NotificationCenter.default.post(name: .recoveredDraftsShow, object: nil)
        }
        registry.register(id: "file.showDraftsFolder", title: "File: Show Drafts Folder") { _ in
            documents.showDraftsFolder()
        }

        // Find
        registry.register(id: "find.show",            title: "Find: Find…  ⌘F") { _ in
            NotificationCenter.default.post(name: .findBarShow, object: nil)
        }
        registry.register(id: "find.showWithReplace", title: "Find: Find and Replace…  ⌘⌥F") { _ in
            NotificationCenter.default.post(name: .findBarShowWithReplace, object: nil)
        }
        registry.register(id: "find.next",            title: "Find: Find Next  ⌘G") { _ in
            NotificationCenter.default.post(name: .findBarNext, object: nil)
        }
        registry.register(id: "find.previous",        title: "Find: Find Previous  ⌘⇧G") { _ in
            NotificationCenter.default.post(name: .findBarPrevious, object: nil)
        }

        // Selection (multi-cursor)
        // Dispatched to the focused editor, not broadcast. A broadcast reached
        // EVERY live EditorTextView — both compare panes at once — so ⌘D added a
        // cursor in the pane the user was not looking at as well.
        registry.register(id: "selection.addNextMatch", title: "Selection: Add Next Match  ⌘D") { _ in
            EditorCommandTarget.focusedEditor?.addNextMatch()
        }
        registry.register(id: "selection.addAllMatches", title: "Selection: Add All Matches  ⌘⌃⌥D") { _ in
            EditorCommandTarget.focusedEditor?.addAllMatches()
        }
        registry.register(id: "selection.uppercase",  title: "Selection: Convert to Uppercase  ⇧⌘U") { _ in
            EditorCommandTarget.focusedEditor?.convertSelectionToUppercase()
        }
        registry.register(id: "selection.lowercase",  title: "Selection: Convert to Lowercase  ⌥⌘U") { _ in
            EditorCommandTarget.focusedEditor?.convertSelectionToLowercase()
        }
        registry.register(id: "selection.titlecase", title: "Selection: Convert to Title Case") { _ in
            EditorCommandTarget.focusedEditor?.convertSelectionToTitlecase()
        }

        // Text tools
        registry.register(id: "text.gotoLine", title: "Text: Go to Line…  ⌘L") { _ in
            promptGoToLine()
        }
        registry.register(id: "text.toggleWordWrap", title: "Text: Toggle Word Wrap") { _ in
            EditorCommandTarget.focusedEditor?.toggleWordWrap()
        }
        registry.register(id: "text.toggleLineNumbers", title: "Text: Toggle Line Numbers") { _ in
            AppPreferences.current?.showsLineNumbers.toggle()
        }
        registry.register(id: "text.toggleInvisibles", title: "Text: Toggle Invisible Characters") { _ in
            EditorCommandTarget.focusedEditor?.toggleInvisibleCharacters()
        }
        registry.register(id: "text.trimTrailingWhitespace", title: "Text: Trim Trailing Spaces") { _ in
            EditorCommandTarget.focusedEditor?.trimTrailingWhitespace()
        }
        registry.register(id: "text.duplicateLine", title: "Text: Duplicate Line  ⇧⌘D") { _ in
            EditorCommandTarget.focusedEditor?.duplicateCurrentLines()
        }
        registry.register(id: "text.deleteLine", title: "Text: Delete Line  ⇧⌘K") { _ in
            EditorCommandTarget.focusedEditor?.deleteCurrentLines()
        }
        registry.register(id: "text.sortLines", title: "Text: Sort Lines") { _ in
            EditorCommandTarget.focusedEditor?.sortSelectedLines()
        }
        registry.register(id: "text.removeDuplicateLines", title: "Text: Remove Duplicate Lines") { _ in
            EditorCommandTarget.focusedEditor?.removeDuplicateSelectedLines()
        }
        registry.register(id: "text.convertMACAddressFormat", title: "Text: Convert MAC Address Format") { _ in
            EditorCommandTarget.focusedEditor?.convertSelectedMACAddressFormat()
        }
        registry.register(id: "text.lineEndingsLF", title: "Text: Convert Line Endings to LF") { _ in
            EditorCommandTarget.focusedEditor?.convertLineEndings(to: .lf)
        }
        registry.register(id: "text.lineEndingsCRLF", title: "Text: Convert Line Endings to CRLF") { _ in
            EditorCommandTarget.focusedEditor?.convertLineEndings(to: .crlf)
        }
        registry.register(id: "text.convertIndentSpaces2", title: "Text: Convert Indentation to Spaces: 2") { _ in
            EditorCommandTarget.focusedEditor?.convertIndentation(to: .spaces2)
        }
        registry.register(id: "text.convertIndentSpaces4", title: "Text: Convert Indentation to Spaces: 4") { _ in
            EditorCommandTarget.focusedEditor?.convertIndentation(to: .spaces4)
        }
        registry.register(id: "text.convertIndentTabs", title: "Text: Convert Indentation to Tabs") { _ in
            EditorCommandTarget.focusedEditor?.convertIndentation(to: .tabs)
        }
        registry.register(id: "search.findInFiles", title: "Search: Find in Files…  ⇧⌘F") { _ in
            NotificationCenter.default.post(name: .findInFilesShow, object: nil)
        }

        // Palette
        registry.register(id: "palette.show", title: "Command Palette: Show") { _ in
            palette.show()
        }

        // Compare
        registry.register(id: "compare.selectTab", title: "Compare: Select Tab to Compare") { _ in
            documents.selectTabToCompare()
        }
        registry.register(id: "compare.withActive", title: "Compare: Compare with Right Tab") { _ in
            documents.compareWithActiveDocument()
        }
        registry.register(id: "compare.withFile", title: "Compare: Select File to Compare") { _ in
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            documents.selectFileToCompare(url)
        }
        registry.register(id: "compare.clear", title: "Compare: Exit Compare Mode") { _ in
            documents.clearCompareMode()
        }

    }

    /// The one document a save command acts on.
    ///
    /// ⌘S used to trim `EditorCommandTarget.focusedEditor`'s document and then
    /// save `activeDocumentID` — two different documents whenever the focused
    /// editor is not the active tab's, which is exactly the case in compare
    /// mode: focusing the RIGHT pane and pressing ⌘S trimmed the right buffer
    /// and wrote the left file. Every save path now resolves the target once
    /// and both trims and saves that.
    ///
    /// The focused editor wins over `activeDocumentID` because it is what the
    /// user is actually typing in.
    static func saveTargetDocumentID(_ documents: DocumentStore) -> Document.ID? {
        if let focused = EditorCommandTarget.focusedEditor?.document?.id,
           documents.documents.contains(where: { $0.id == focused }) {
            return focused
        }
        return documents.activeDocumentID
    }

    /// Apply the document's on-save trim, through its editor when one is on
    /// screen so the change lands in that view's undo stack and its text
    /// storage stays in sync.
    ///
    /// `DocumentStore.prepareSave` no longer trims — otherwise auto save would
    /// silently rewrite text the user did not ask it to touch — so a manual
    /// save has to do it here, for the document being saved.
    static func trimDocumentIfNeeded(_ id: Document.ID, in documents: DocumentStore) {
        guard let doc = documents.documents.first(where: { $0.id == id }),
              doc.autoTrimTrailingWhitespace
        else { return }

        if let editor = EditorCommandTarget.editor(for: id) {
            editor.trimTrailingWhitespace(markDirty: false)
        } else {
            // Background tab with no live text view: transform the model
            // directly. Nothing is displaying it, so there is no storage to
            // keep in step.
            doc.text = TextContentTransforms.trimTrailingWhitespace(
                in: doc.text,
                lineEnding: doc.lineEnding
            )
        }
    }

    /// Save All writes every dirty document, so every dirty document with the
    /// option on gets trimmed — not just the focused one.
    static func trimAllDirtyDocumentsIfNeeded(in documents: DocumentStore) {
        for doc in documents.documents where doc.isDirty {
            trimDocumentIfNeeded(doc.id, in: documents)
        }
    }

    private static func promptGoToLine() {
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        alert.informativeText = "Enter a line number."
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
        field.placeholderString = "Line"
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn,
              let line = Int(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }
        EditorCommandTarget.focusedEditor?.goToLine(line)
    }
}
