//
//  PluginsView.swift
//  Simple installed-plugins view (Tabby-style entry from sidebar).
//

import SwiftUI
import AppKit

struct PluginsView: View {
    @Environment(PluginManager.self) private var plugins
    @State private var selectedPluginID: String?
    @State private var installErrorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if plugins.hosts.isEmpty {
                emptyState
            } else {
                List(selection: $selectedPluginID) {
                    ForEach(plugins.hosts, id: \.manifest.id) { host in
                        pluginRow(for: host)
                            .tag(host.manifest.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedPluginID = host.manifest.id
                            }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .bestTextPanelBackground))

                Divider()
                pluginDetail
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .bestTextPanelBackground))
        .onAppear {
            if selectedPluginID == nil {
                selectedPluginID = plugins.hosts.first?.manifest.id
            }
        }
        .onChange(of: plugins.hosts.count) { _, _ in
            if selectedHost == nil {
                selectedPluginID = plugins.hosts.first?.manifest.id
            }
        }
        .alert("Plugin Install Failed", isPresented: Binding(
            get: { installErrorMessage != nil },
            set: { shown in
                if !shown { installErrorMessage = nil }
            }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(installErrorMessage ?? "Unknown error.")
        }
    }

    private var header: some View {
        HStack {
            Text("Plugins")
                .font(.title3.weight(.semibold))

            Spacer()

            Button("Open Folder") {
                PluginPaths.ensureExists()
                NSWorkspace.shared.open(PluginPaths.pluginsDir)
            }

            Button("Install…") {
                installPluginFromFolderPicker()
            }

            Button("Reload") {
                NotificationCenter.default.post(name: .reloadPlugins, object: nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "puzzlepiece.extension")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No plugins installed")
                .font(.system(size: 13, weight: .semibold))
            Text("Install plugins in:\n\(PluginPaths.pluginsDir.path)")
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
                .font(.system(size: 11))
                .padding(.horizontal, 12)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var selectedHost: PluginHost? {
        plugins.hosts.first(where: { $0.manifest.id == selectedPluginID })
    }

    @MainActor
    private func installPluginFromFolderPicker() {
        let panel = NSOpenPanel()
        panel.title = "Select Plugin Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await plugins.installPlugin(from: url)
            } catch {
                installErrorMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func pluginRow(for host: PluginHost) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(host.manifest.name)
                    .font(.headline)
                Spacer()
                Text(host.manifest.version)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(host.manifest.id)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var pluginDetail: some View {
        if let host = selectedHost {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(host.manifest.name)
                        .font(.headline)
                    Spacer()
                    Text("v\(host.manifest.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(host.manifest.id)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button("Open Plugin Folder") {
                        NSWorkspace.shared.open(host.folder)
                    }
                    Button("Copy Plugin ID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(host.manifest.id, forType: .string)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("Select a plugin")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
