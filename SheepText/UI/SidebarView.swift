//
//  SidebarView.swift
//  File tree sidebar with fast, full-width row hit targets.
//

import SwiftUI
import AppKit

struct SidebarView: View {

    enum Panel: Hashable {
        case files
        case search
    }

    @Binding var selectedPanel: Panel

    @Environment(WorkspaceStore.self) private var workspace
    @Environment(DocumentStore.self)  private var documents
    @State private var expandedFolders: Set<URL> = []
    @State private var selectedTreeURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            panelTabs
            Divider()
            if selectedPanel == .search {
                FindInFilesView()
            } else if let tree = workspace.tree {
                FileTreeView(
                    nodes: tree.children ?? [],
                    expandedFolders: $expandedFolders,
                    selectedURL: $selectedTreeURL,
                    activeURL: documents.activeDocument?.url
                ) { url in
                    _ = documents.open(url: url)
                }
                .onChange(of: workspace.rootURL) { _, _ in
                    expandedFolders.removeAll()
                    selectedTreeURL = nil
                }
                .onChange(of: documents.activeDocumentID) { _, _ in
                    selectedTreeURL = documents.activeDocument?.url
                }
            } else {
                emptyState
            }
        }
        .background(Color(nsColor: .bestTextSidebarBackground))
    }

    private var panelTabs: some View {
        HStack(spacing: 4) {
            panelButton(
                title: "Files",
                systemImage: "folder",
                isSelected: selectedPanel == .files
            ) {
                selectedPanel = .files
            }

            panelButton(
                title: "Search",
                systemImage: "magnifyingglass",
                isSelected: selectedPanel == .search
            ) {
                selectedPanel = .search
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(Color(nsColor: .bestTextSidebarBackground))
    }

    private func panelButton(
        title: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        SidebarPanelTabButton(
            title: title,
            systemImage: systemImage,
            isSelected: isSelected,
            action: action
        )
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "folder")
                .font(.largeTitle)
                .foregroundStyle(Color(nsColor: .bestTextFolderIcon))
            Text("No folder open")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            Text("You can work on individual files\nusing the + button in the tab bar,\nor open a folder here.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
                .font(.system(size: 11))
                .padding(.horizontal, 12)
            Button("Open Folder…") { workspace.promptOpenFolder() }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct FileTreeView: View {
    let nodes: [FileNode]
    @Binding var expandedFolders: Set<URL>
    @Binding var selectedURL: URL?
    let activeURL: URL?
    let onOpenFile: (URL) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(nodes) { node in
                    FileTreeNodeView(
                        node: node,
                        level: 0,
                        expandedFolders: $expandedFolders,
                        selectedURL: $selectedURL,
                        activeURL: activeURL,
                        onOpenFile: onOpenFile
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .bestTextSidebarBackground))
    }
}

private struct SidebarPanelTabButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(height: 16)

                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(isSelected ? Color(nsColor: .bestTextAccent) : Color(nsColor: .bestTextPrimaryForeground))
            .frame(maxWidth: .infinity, minHeight: 42)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tabBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color(nsColor: .bestTextAccent).opacity(0.22) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .onHover { isHovering = $0 }
        .help(title)
    }

    private var tabBackground: Color {
        if isSelected {
            return Color(nsColor: .bestTextSelectionBackground)
        }
        if isHovering {
            return Color(nsColor: .bestTextHoverBackground)
        }
        return Color.clear
    }
}

private struct FileTreeNodeView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(DocumentStore.self) private var documents

    let node: FileNode
    let level: Int
    @Binding var expandedFolders: Set<URL>
    @Binding var selectedURL: URL?
    let activeURL: URL?
    let onOpenFile: (URL) -> Void

    @State private var isHovering = false

    private var normalizedURL: URL { node.url.standardizedFileURL }
    private var isExpanded: Bool { expandedFolders.contains(normalizedURL) }
    private var hasChildren: Bool { !(node.children ?? []).isEmpty }

    private var isSelected: Bool {
        if let selectedURL {
            return selectedURL.standardizedFileURL == normalizedURL
        }
        return !node.isDirectory && activeURL?.standardizedFileURL == normalizedURL
    }

    private var isCompareLeft: Bool {
        !node.isDirectory &&
        documents.compareLeftDocument?.url?.standardizedFileURL == normalizedURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            row

            if node.isDirectory, isExpanded {
                ForEach(node.children ?? []) { child in
                    FileTreeNodeView(
                        node: child,
                        level: level + 1,
                        expandedFolders: $expandedFolders,
                        selectedURL: $selectedURL,
                        activeURL: activeURL,
                        onOpenFile: onOpenFile
                    )
                }
            }
        }
    }

    private var row: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .opacity(node.isDirectory && hasChildren ? 1 : 0)
                .frame(width: 12, height: 18)

            Image(systemName: node.isDirectory ? "folder" : fileIconName(for: node.name))
                .font(.system(size: node.isDirectory ? 13 : 12, weight: .regular))
                .foregroundStyle(
                    Color(nsColor: node.isDirectory ? .bestTextFolderIcon : .bestTextFileIcon)
                )
                .frame(width: 17)

            Text(node.name)
                .font(.system(size: 13, weight: (isSelected || isCompareLeft) ? .semibold : .regular))
                .foregroundStyle(
                    Color(nsColor: isCompareLeft ? .editorModifiedAmber : .bestTextPrimaryForeground)
                )
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(level) * 18)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle()
                    .fill(Color(nsColor: .bestTextAccent))
                    .frame(width: 2)
                    .padding(.vertical, 3)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: handleClick)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open") {
                handleClick()
            }

            Divider()

            Button("New File") {
                createFile()
            }

            Button("New Folder") {
                createFolder()
            }

            Divider()

            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            }

            Button("Copy Path") {
                copyPath()
            }

            Divider()

            Button("Rename...") {
                renameNode()
            }

            Button("Delete") {
                deleteNode()
            }
        }
    }

    private var rowBackground: some ShapeStyle {
        if isCompareLeft {
            return Color(nsColor: .editorModifiedAmber).opacity(0.16)
        }
        if isSelected {
            return Color(nsColor: .bestTextSelectionBackground)
        }
        if isHovering {
            return Color(nsColor: .bestTextHoverBackground)
        }
        return Color.clear
    }

    private func toggleFolder() {
        guard node.isDirectory, hasChildren else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if isExpanded {
                expandedFolders.remove(normalizedURL)
            } else {
                expandedFolders.insert(normalizedURL)
            }
        }
    }

    private func handleClick() {
        selectedURL = normalizedURL
        if node.isDirectory {
            toggleFolder()
        } else {
            let url = node.url
            DispatchQueue.main.async {
                onOpenFile(url)
            }
        }
    }

    private var targetDirectory: URL {
        node.isDirectory ? node.url : node.url.deletingLastPathComponent()
    }

    private func createFile() {
        guard let url = workspace.createFile(in: targetDirectory) else {
            showFileAlert("Cannot create file.")
            return
        }
        selectedURL = url.standardizedFileURL
        if node.isDirectory {
            expandedFolders.insert(normalizedURL)
        }
        onOpenFile(url)
    }

    private func createFolder() {
        guard let url = workspace.createFolder(in: targetDirectory) else {
            showFileAlert("Cannot create folder.")
            return
        }
        selectedURL = url.standardizedFileURL
        if node.isDirectory {
            expandedFolders.insert(normalizedURL)
        }
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.url.path, forType: .string)
    }

    private func renameNode() {
        guard let newName = promptName(
            title: "Rename",
            message: node.name,
            value: node.name
        ) else { return }

        guard let newURL = workspace.rename(node.url, to: newName) else {
            showFileAlert("Cannot rename \"\(node.name)\".")
            return
        }
        selectedURL = newURL.standardizedFileURL
        if !node.isDirectory,
           let document = documents.documents.first(where: { $0.url?.standardizedFileURL == normalizedURL }) {
            document.url = newURL
        }
    }

    private func deleteNode() {
        let alert = NSAlert()
        alert.messageText = "Delete \"\(node.name)\"?"
        alert.informativeText = "The item will be moved to the Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard workspace.trash(node.url) else {
            showFileAlert("Cannot delete \"\(node.name)\".")
            return
        }
        selectedURL = nil
    }

    private func promptName(title: String, message: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = value
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    private func showFileAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func fileIconName(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift":                         return "swift"
        case "js", "ts", "jsx", "tsx":        return "curlybraces"
        case "py":                            return "chevron.left.slash.chevron.right"
        case "md":                            return "doc.richtext"
        case "json", "yml", "yaml":           return "list.bullet.indent"
        case "png", "jpg", "jpeg", "gif":     return "photo"
        default:                              return "doc"
        }
    }
}
