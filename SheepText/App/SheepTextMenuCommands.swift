//
//  SheepTextMenuCommands.swift
//  Native macOS menu bar. Most items delegate to CommandRegistry so
//  plugins can override or extend them.
//

import SwiftUI
import AppKit

struct SheepTextMenuCommands: Commands {

    let palette: CommandPaletteController
    let workspace: WorkspaceStore
    let documents: DocumentStore
    /// Reopens the main window when the user closed it but the app kept
    /// running (e.g. only Settings is open) — otherwise these commands would
    /// mutate stores no window is showing.
    let ensureMainWindow: () -> Void

    var body: some Commands {

        // MARK: File
        CommandGroup(replacing: .newItem) {
            Button("New File") {
                ensureMainWindow()
                CommandBus.shared.execute("file.new")
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Open File…") {
                ensureMainWindow()
                for url in workspace.promptOpenFiles() {
                    documents.open(url: url)
                }
            }
            .keyboardShortcut("o", modifiers: .command)

            Button("Open Folder…") {
                ensureMainWindow()
                workspace.promptOpenFolder()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Menu("Open Recent Folder") {
                if workspace.recentWorkspaces.isEmpty {
                    Text("No Recent Folders")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(workspace.recentWorkspaces.enumerated()), id: \.offset) { index, url in
                        Button(url.lastPathComponent) {
                            ensureMainWindow()
                            workspace.openRecentWorkspace(at: index)
                        }
                    }
                    Divider()
                    Button("Clear Menu") {
                        workspace.clearRecentWorkspaces()
                    }
                }
            }

            Menu("Open Recent") {
                if documents.recentFiles.isEmpty {
                    Text("No Recent Files")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(documents.recentFiles.enumerated()), id: \.offset) { index, url in
                        Button(url.lastPathComponent) {
                            ensureMainWindow()
                            documents.openRecent(at: index)
                        }
                    }
                    Divider()
                    Button("Clear Menu") {
                        documents.clearRecentFiles()
                    }
                }
            }

            Divider()

            Button("Recovered Drafts…") {
                ensureMainWindow()
                NotificationCenter.default.post(name: .recoveredDraftsShow, object: nil)
            }

            Button("Show Drafts Folder") {
                documents.showDraftsFolder()
            }
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                if EditorCommandTarget.focusedEditor?.document?.autoTrimTrailingWhitespace == true {
                    EditorCommandTarget.focusedEditor?.trimTrailingWhitespace(markDirty: false)
                }
                if let id = documents.activeDocumentID { documents.save(id) }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(documents.activeDocument == nil)

            Button("Save All") {
                if EditorCommandTarget.focusedEditor?.document?.autoTrimTrailingWhitespace == true {
                    EditorCommandTarget.focusedEditor?.trimTrailingWhitespace(markDirty: false)
                }
                documents.saveAllDirty()
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(!documents.documents.contains { $0.isDirty })

            Button("Save As…") {
                if EditorCommandTarget.focusedEditor?.document?.autoTrimTrailingWhitespace == true {
                    EditorCommandTarget.focusedEditor?.trimTrailingWhitespace(markDirty: false)
                }
                if let id = documents.activeDocumentID { documents.saveAs(id) }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(documents.activeDocument == nil)

            Divider()

            Button("Close Tab") {
                if let id = documents.activeDocumentID { documents.close(id) }
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(documents.activeDocument == nil)

            Button("Close Other Tabs") {
                documents.closeOtherTabs()
            }
            .disabled(documents.documents.count <= 1 || documents.activeDocument == nil)

            Button("Close Saved Tabs") {
                documents.closeSavedTabs()
            }
            .disabled(!documents.documents.contains { !$0.isDirty })

            Button("Close All Tabs") {
                documents.closeAllTabs()
            }
            .keyboardShortcut("w", modifiers: [.command, .option])
            .disabled(documents.documents.isEmpty)
        }

        // MARK: Edit — multi-cursor + Find
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Add Next Occurrence") {
                CommandBus.shared.execute("selection.addNextMatch")
            }
            .keyboardShortcut("d", modifiers: .command)

            Button("Select All Occurrences") {
                CommandBus.shared.execute("selection.addAllMatches")
            }
            .keyboardShortcut("d", modifiers: [.command, .control, .option])
        }

        // Find & Replace — its own top-level submenu under Edit.
        CommandMenu("Find") {
            Button("Find…") {
                NotificationCenter.default.post(name: .findBarShow, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)

            Button("Find and Replace…") {
                NotificationCenter.default.post(name: .findBarShowWithReplace, object: nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .option])

            Button("Find in Files…") {
                NotificationCenter.default.post(name: .findInFilesShow, object: nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])

            Divider()

            Button("Find Next") {
                NotificationCenter.default.post(name: .findBarNext, object: nil)
            }
            .keyboardShortcut("g", modifiers: .command)

            Button("Find Previous") {
                NotificationCenter.default.post(name: .findBarPrevious, object: nil)
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])

        }

        // MARK: Tools
        CommandMenu("Tools") {
            Button("Command Palette…") {
                palette.show()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Divider()

            Button("Convert to Uppercase") {
                NSApp.sendAction(#selector(EditorTextView.convertSelectionToUppercase), to: nil, from: nil)
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(documents.activeDocument == nil)

            Button("Convert to Lowercase") {
                NSApp.sendAction(#selector(EditorTextView.convertSelectionToLowercase), to: nil, from: nil)
            }
            .keyboardShortcut("u", modifiers: [.command, .option])
            .disabled(documents.activeDocument == nil)

            Button("Convert to Title Case") {
                NSApp.sendAction(#selector(EditorTextView.convertSelectionToTitlecase), to: nil, from: nil)
            }
            .disabled(documents.activeDocument == nil)

            Button("Convert MAC Address Format") {
                CommandBus.shared.execute("text.convertMACAddressFormat")
            }
            .disabled(documents.activeDocument == nil)

            Divider()

            Button("Go to Line…") {
                CommandBus.shared.execute("text.gotoLine")
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(documents.activeDocument == nil)

            Button("Duplicate Line") {
                CommandBus.shared.execute("text.duplicateLine")
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(documents.activeDocument == nil)

            Button("Delete Line") {
                CommandBus.shared.execute("text.deleteLine")
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(documents.activeDocument == nil)

            Button("Trim Trailing Spaces") {
                CommandBus.shared.execute("text.trimTrailingWhitespace")
            }
            .disabled(documents.activeDocument == nil)

            Button("Sort Lines") {
                CommandBus.shared.execute("text.sortLines")
            }
            .disabled(documents.activeDocument == nil)

            Button("Remove Duplicate Lines") {
                CommandBus.shared.execute("text.removeDuplicateLines")
            }
            .disabled(documents.activeDocument == nil)

            Button("Toggle Word Wrap") {
                CommandBus.shared.execute("text.toggleWordWrap")
            }
            .disabled(documents.activeDocument == nil)

            Toggle("Show Line Numbers", isOn: Binding(
                get: { AppPreferences.current?.showsLineNumbers ?? true },
                set: { AppPreferences.current?.showsLineNumbers = $0 }
            ))

            Button("Toggle Invisible Characters") {
                CommandBus.shared.execute("text.toggleInvisibles")
            }
            .disabled(documents.activeDocument == nil)

            Divider()

            Button("Select Tab to Compare…") {
                CommandBus.shared.execute("compare.selectTab")
            }

            Button("Compare with Right Tab") {
                CommandBus.shared.execute("compare.withActive")
            }

            Button("Select File to Compare…") {
                CommandBus.shared.execute("compare.withFile")
            }

            Button("Exit Compare Mode") {
                CommandBus.shared.execute("compare.clear")
            }
        }

    }
}

@MainActor
enum EditorCommandTarget {
    private static let editors = NSHashTable<EditorTextView>.weakObjects()
    static weak var activeEditor: EditorTextView?

    static func register(_ editor: EditorTextView) {
        editors.add(editor)
        activeEditor = editor
    }

    static var focusedEditor: EditorTextView? {
        if let editor = NSApp.keyWindow?.firstResponder as? EditorTextView {
            register(editor)
            return editor
        }
        return activeEditor
    }

    static func editor(for documentID: Document.ID) -> EditorTextView? {
        if let editor = focusedEditor, editor.document?.id == documentID {
            return editor
        }
        if let editor = editors.allObjects.first(where: { $0.document?.id == documentID }) {
            activeEditor = editor
            return editor
        }
        return nil
    }
}

/// Minimal singleton bridge so menu items can dispatch to the CommandRegistry
/// without passing it through the environment (menus don't have one).
@MainActor
final class CommandBus {
    static let shared = CommandBus()
    weak var registry: CommandRegistry?

    func execute(_ id: String, _ args: [Any] = []) {
        registry?.execute(id, args: args)
    }
}

// Find-bar notifications — the editor listens and shows/hides its bar.
extension Notification.Name {
    static let findBarShow            = Notification.Name("sheeptext.findBar.show")
    static let findBarShowWithReplace = Notification.Name("sheeptext.findBar.showWithReplace")
    static let findBarHide            = Notification.Name("sheeptext.findBar.hide")
    static let findBarNext            = Notification.Name("sheeptext.findBar.next")
    static let findBarPrevious        = Notification.Name("sheeptext.findBar.previous")
}
