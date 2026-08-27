//
//  CommandPaletteView.swift
//  Fuzzy-searchable overlay bound to ⌘⇧P.
//
//  Scoring: a simple subsequence match with a bonus for prefix hits,
//  camelCase boundaries, and recency. Plenty good for thousands of
//  commands; a proper fzf-style matcher is a nice-to-have later.
//

import SwiftUI
import Observation

@Observable
@MainActor
final class CommandPaletteController {
    var isVisible: Bool = false
    var query: String = ""

    func show() { isVisible = true }
    func hide() { isVisible = false; query = "" }
    func toggle() { isVisible ? hide() : show() }
}

struct CommandPaletteView: View {

    @Environment(CommandPaletteController.self) private var palette
    @Environment(CommandRegistry.self)          private var commands
    @FocusState private var isFocused: Bool
    @State private var selectedIndex = 0

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            TextField("Type a command…", text: bindingQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .padding(12)
                .focused($isFocused)
                .onAppear { isFocused = true }
                .onExitCommand { palette.hide() }
                .onSubmit { runSelectedMatch() }
            Divider()
            // Results
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(limitedMatches.enumerated()), id: \.element.id) { index, entry in
                        Button {
                            run(entry)
                        } label: {
                            PaletteRow(
                                title: entry.title,
                                subtitle: paletteSubtitle(for: entry),
                                isSelected: index == selectedIndex
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 560)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .bestTextPanelBackground))
                .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .bestTextBorder))
        )
        .onMoveCommand(perform: moveSelection)
        .onChange(of: palette.query) { _, _ in selectedIndex = 0 }
        .onChange(of: limitedMatches.count) { _, count in
            selectedIndex = min(selectedIndex, max(0, count - 1))
        }
    }

    private var bindingQuery: Binding<String> {
        Binding(get: { palette.query }, set: { palette.query = $0 })
    }

    private var matches: [CommandRegistry.Entry] {
        let all = commands.list()
        guard !palette.query.isEmpty else {
            return all.sorted {
                let leftBoost = commands.recencyBoost(for: $0.id)
                let rightBoost = commands.recencyBoost(for: $1.id)
                if leftBoost != rightBoost { return leftBoost > rightBoost }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
        return all
            .map {
                let titleScore = score(query: palette.query, against: $0.title)
                let idScore = score(query: palette.query, against: $0.id)
                let matchScore = max(titleScore, idScore)
                return ($0, matchScore, matchScore + commands.recencyBoost(for: $0.id))
            }
            .filter { $0.1 > 0 }
            .sorted { $0.2 > $1.2 }
            .map    { $0.0 }
    }

    private var limitedMatches: [CommandRegistry.Entry] {
        Array(matches.prefix(200))
    }

    private func runSelectedMatch() {
        let entries = limitedMatches
        guard !entries.isEmpty else { return }
        let index = min(selectedIndex, entries.count - 1)
        run(entries[index])
    }

    private func run(_ entry: CommandRegistry.Entry) {
        palette.hide()
        commands.execute(entry.id)
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let count = limitedMatches.count
        guard count > 0 else { return }
        switch direction {
        case .down:
            selectedIndex = min(selectedIndex + 1, count - 1)
        case .up:
            selectedIndex = max(selectedIndex - 1, 0)
        default:
            break
        }
    }

    private func paletteSubtitle(for entry: CommandRegistry.Entry) -> String {
        var parts = [entry.id]
        switch entry.source {
        case .builtIn:
            parts.append("Built-in")
        case .plugin(let pluginID):
            parts.append(pluginID)
        }
        return parts.joined(separator: "  ")
    }

    /// Subsequence match with small positional bonuses. Higher = better.
    private func score(query: String, against title: String) -> Int {
        let q = query.lowercased()
        let t = title.lowercased()
        var qi = q.startIndex
        var ti = t.startIndex
        var matches = 0
        var bonus = 0
        var consecutive = 0
        while qi < q.endIndex && ti < t.endIndex {
            if q[qi] == t[ti] {
                matches += 1
                consecutive += 1
                bonus += consecutive * 2
                // Boundary bonus (start of word)
                if ti == t.startIndex || t[t.index(before: ti)] == " " {
                    bonus += 5
                }
                qi = q.index(after: qi)
            } else {
                consecutive = 0
            }
            ti = t.index(after: ti)
        }
        guard qi == q.endIndex else { return 0 } // all query chars must match
        return matches * 10 + bonus
    }
}

private struct PaletteRow: View {
    let title: String
    let subtitle: String
    let isSelected: Bool

    @State private var isHovering = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                Text(subtitle).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            isSelected
                ? Color(nsColor: .bestTextSelectionBackground)
                : (isHovering ? Color(nsColor: .bestTextHoverBackground) : Color.clear)
        )
        .onHover { isHovering = $0 }
    }
}
