//
//  SidebarView.swift
//  File tree sidebar with fast, full-width row hit targets.
//
//  Full-height column: it owns the traffic-light row, so everything inside
//  starts below `trafficLightGap`. Folders are set as letterpress section
//  headers and files carry an extension chip instead of an icon — see
//  Letterpress.swift for why.
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
    @Environment(AppPreferences.self) private var preferences
    @State private var expandedFolders: Set<URL> = []
    @State private var selectedTreeURL: URL?
    /// Mirrors the tab bar's own fullscreen tracking so the gap changes DURING
    /// the system transition rather than popping after it.
    @State private var isFullScreen = false

    /// The titlebar strip this column sits under. Controls placed INSIDE it do
    /// not reliably receive clicks — verified by driving the real app: the
    /// switcher was dead there as a Button and as an onTapGesture, clipped and
    /// unclipped, and came alive the moment it moved below the strip. The tab
    /// bar works there only because it is a plain view, not a control target.
    /// SheepTerm's sidebar keeps its search field below the same gap for the
    /// same reason. macOS hides the lights in fullscreen, so the strip shrinks.
    private var trafficLightGap: CGFloat {
        isFullScreen ? 0 : SheepTextChromeMetrics.topBarHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            panelSwitcher

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
        .background { ChromeBackground(zone: .sidebar) }
        // Filtered to THIS column's own window, and seeded from it rather than
        // from NSApp.keyWindow — which is another window entirely when two are
        // open, and nil whenever the app is not active.
        .trackingHostWindowFullScreen($isFullScreen)
    }

    /// Two words, no buttons, no icons, no tile — the same letterpress
    /// treatment as the tabs, and it stays put in both panels so switching
    /// never moves the rest of the column.
    ///
    /// It shares its band with the traffic lights and is exactly as tall as
    /// the tab bar next to it, so the window has ONE top band with one bottom
    /// rule running across it, not two stacked rows of different heights.
    private var panelSwitcher: some View {
        VStack(spacing: 0) {
            // The titlebar strip itself: traffic lights only, and draggable
            // like a real titlebar. Its bottom rule lines up with the tab
            // bar's, so the window still reads as one band across the top.
            Color.clear
                .frame(height: trafficLightGap)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .overlay(alignment: .bottom) {
                    // An overlay does NOT collapse with a zero-height host, so
                    // in fullscreen (gap 0) this rule used to keep drawing at
                    // y≈0 while the tab bar's rule sat at y=30 — a stray
                    // hairline across the sidebar, breaking the one-band /
                    // one-rule invariant this strip exists to hold.
                    if trafficLightGap > 0 {
                        Rectangle()
                            .fill(preferences.chromeStyle.separator)
                            .frame(height: 1)
                    }
                }
                .animation(.easeOut(duration: 0.18), value: isFullScreen)

            HStack(spacing: 16) {
                switchItem("Files", panel: .files)
                switchItem("Search", panel: .search)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 26)
        }
    }

    private func switchItem(_ title: String, panel: Panel) -> some View {
        // fixedSize: these two words keep their width no matter how narrow the
        // sidebar is dragged — they are the column's only navigation.
        let isOn = selectedPanel == panel
        return PressLabel(text: title, size: 10, emphasized: isOn,
                          color: isOn ? Color(nsColor: .bestTextAccent) : nil)
            .fixedSize()
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture { selectedPanel = panel }
            .help(panel == .search ? "Find in Files (⇧⌘F)" : "Files")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "folder")
                .chromeSymbol(size: 30, weight: .regular)
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

/// Everything a row needs that is the SAME for every row, resolved once per
/// tree render instead of once per row.
///
/// `FileTreeNodeView` carries closures and bindings, so SwiftUI can never prove
/// two instances equal: any parent invalidation (a tab switch, opening a
/// document, entering compare) re-runs the body of every instantiated row. At
/// ~5000 files, standardizing the selected / active / compare URLs inside each
/// row meant thousands of `standardizedFileURL` calls per tab switch. Reading
/// `preferences.chromeStyle` in each row also registered 5000 separate
/// `@Observable` dependencies on preferences.
private struct FileTreeContext {
    let selectedURL: URL?
    let activeURL: URL?
    /// BOTH compare sides. Only the left one used to be tracked, so entering
    /// compare mode marked one of the two files in the tree and left the other
    /// looking untouched — while the tab bar badged both.
    let compareLeftURL: URL?
    let compareRightURL: URL?
    let hoverFill: Color
    let onOpenFile: (URL) -> Void
}

struct FileTreeView: View {
    @Environment(DocumentStore.self) private var documents
    @Environment(AppPreferences.self) private var preferences

    let nodes: [FileNode]
    @Binding var expandedFolders: Set<URL>
    @Binding var selectedURL: URL?
    let activeURL: URL?
    let onOpenFile: (URL) -> Void

    var body: some View {
        let context = FileTreeContext(
            selectedURL: selectedURL?.standardizedFileURL,
            activeURL: activeURL?.standardizedFileURL,
            compareLeftURL: documents.compareLeftDocument?.url?.standardizedFileURL,
            compareRightURL: documents.compareRightDocument?.url?.standardizedFileURL,
            hoverFill: preferences.chromeStyle.hoverFill,
            onOpenFile: onOpenFile
        )

        // No ChromeBackground here: the whole sidebar column already sits on
        // one, and a second behind-window NSVisualEffectView nested inside it
        // is fully occluded — a blur/sample pass paid per composite for
        // nothing.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(Self.flatten(nodes, expandedFolders: expandedFolders)) { row in
                    FileTreeNodeView(
                        node: row.node,
                        level: row.level,
                        expandedFolders: $expandedFolders,
                        selectedURL: $selectedURL,
                        context: context
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 14)
        }
    }

    /// One visible row: the node and how deep it sits.
    struct Row: Identifiable {
        let node: FileNode
        let level: Int
        var id: URL { node.url }
    }

    /// Depth-first walk of the *expanded* tree, produced once per render.
    ///
    /// The rows used to nest: the outer `LazyVStack` held only the roots, and
    /// each row rendered its own children in a plain `VStack`/`ForEach`. A
    /// LazyVStack is lazy in its OWN children only, so as soon as a folder was
    /// open every descendant row was built and laid out whether or not it was
    /// anywhere near the viewport — opening a `node_modules` meant thousands of
    /// row bodies, hover trackers and context menus per render pass.
    ///
    /// Flattened, the LazyVStack sees every visible row directly and builds only
    /// the ones on screen. Geometry is unchanged: sibling spacing was 1 in both
    /// the outer and the inner stack, and each row still carries its own
    /// `.padding(.top, 12)` for a folder header, so the flattened list lays out
    /// exactly like the nested one did.
    static func flatten(_ nodes: [FileNode], expandedFolders: Set<URL>) -> [Row] {
        var rows: [Row] = []
        func walk(_ nodes: [FileNode], level: Int) {
            for node in nodes {
                rows.append(Row(node: node, level: level))
                guard node.isDirectory,
                      expandedFolders.contains(node.url.standardizedFileURL),
                      let children = node.children
                else { continue }
                walk(children, level: level + 1)
            }
        }
        walk(nodes, level: 0)
        return rows
    }
}

private struct FileTreeNodeView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(DocumentStore.self) private var documents

    let node: FileNode
    let level: Int
    @Binding var expandedFolders: Set<URL>
    @Binding var selectedURL: URL?
    let context: FileTreeContext

    /// Stored, not computed: this used to be a `var` that four other computed
    /// properties each re-evaluated, so one body ran `standardizedFileURL`
    /// about five times. `FileNode` is declared in `Core/WorkspaceStore.swift`,
    /// so caching it on the node at scan time is the better fix and belongs in
    /// that file; this is the in-file half.
    private let normalizedURL: URL

    @State private var isHovering = false

    init(node: FileNode,
         level: Int,
         expandedFolders: Binding<Set<URL>>,
         selectedURL: Binding<URL?>,
         context: FileTreeContext) {
        self.node = node
        self.level = level
        self._expandedFolders = expandedFolders
        self._selectedURL = selectedURL
        self.context = context
        self.normalizedURL = node.url.standardizedFileURL
    }

    private var isExpanded: Bool { expandedFolders.contains(normalizedURL) }
    private var hasChildren: Bool { !(node.children ?? []).isEmpty }

    private var isSelected: Bool {
        if let selected = context.selectedURL {
            return selected == normalizedURL
        }
        return !node.isDirectory && context.activeURL == normalizedURL
    }

    /// Either side of a comparison. Named for what it means to the row — this
    /// file is in the current comparison — rather than for which pane it is in;
    /// both are drawn the same amber way.
    private var isInCompare: Bool {
        guard !node.isDirectory else { return false }
        return context.compareLeftURL == normalizedURL
            || context.compareRightURL == normalizedURL
    }

    /// One row only. Descendants are siblings in the flattened list the parent
    /// `FileTreeView` builds — see `FileTreeView.flatten`.
    var body: some View {
        row
            // Outside `row` on purpose: inside, it stretched the row's
            // highlight upward and the label stopped being centred in it.
            .padding(.top, node.isDirectory ? 12 : 0)
    }

    @ViewBuilder
    private var row: some View {
        HStack(spacing: 9) {
            if node.isDirectory {
                // A folder is a section header, full stop: no icon, no
                // disclosure triangle. Clicking the header opens and closes
                // it, and the files listed under it are the disclosure.
                PressLabel(text: node.name, size: 10,
                           emphasized: isExpanded,
                           color: Color(nsColor: .bestTextSecondaryForeground))
                    .opacity(isExpanded ? 1 : 0.68)
            } else {
                ExtensionChip(filename: node.name, isEmphasized: isSelected || isInCompare)

                Text(pressBaseName(node.name))
                    .font(.system(size: 12,
                                  weight: (isSelected || isInCompare) ? .semibold : .regular))
                    .foregroundStyle(Color(nsColor: isInCompare
                                           ? .editorModifiedAmber
                                           : (isSelected ? .bestTextAccent : .bestTextPrimaryForeground)))
                    .lineLimit(1)
                    // Middle: source files share long prefixes AND suffixes
                    // (CompareDisplayBuilder / CompareBlockSplice), so both
                    // ends have to survive.
                    .truncationMode(.middle)
                    .help(node.name)
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(level) * 14)
        .padding(.horizontal, 8)
        .padding(.vertical, node.isDirectory ? 4 : 4.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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

    private var rowBackground: Color {
        if isInCompare {
            return Color(nsColor: .editorModifiedAmber).opacity(0.16)
        }
        // Selection is carried by the accent ink and the chip's border — the
        // fill would be a slab, which is the thing this design is avoiding.
        if isHovering {
            return context.hoverFill
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
                context.onOpenFile(url)
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
        context.onOpenFile(url)
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
        // Not `document.url = newURL`: that leaves the security-scoped bookmark,
        // the accessible URL the disk poll stats through, the recorded disk
        // state, the recents list and the restored session all pointing at the
        // old path. Renaming a FOLDER moves everything under it, which the store
        // handles by prefix-matching, so this call is made either way.
        documents.documentDidMove(from: node.url, to: newURL)
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

}
