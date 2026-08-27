//
//  HighlightOverrides.swift
//  Plugin-configurable file-extension -> highlight language overrides.
//

import Foundation

@MainActor
final class HighlightOverrides {
    static let shared = HighlightOverrides()

    private var byExtension: [String: String] = [:]

    private init() {}

    func setLanguage(_ language: String, forFileExtension fileExtension: String) {
        let ext = normalizedExtension(fileExtension)
        guard !ext.isEmpty else { return }
        byExtension[ext] = normalizedLanguage(language)
        NotificationCenter.default.post(name: .syntaxHighlightSettingsDidChange, object: nil)
    }

    func clearLanguage(forFileExtension fileExtension: String) {
        let ext = normalizedExtension(fileExtension)
        guard !ext.isEmpty else { return }
        byExtension.removeValue(forKey: ext)
        NotificationCenter.default.post(name: .syntaxHighlightSettingsDidChange, object: nil)
    }

    func resolvedLanguage(for url: URL?, defaultLanguage: String) -> String {
        guard let ext = url?.pathExtension.lowercased(), !ext.isEmpty else {
            return defaultLanguage
        }
        return byExtension[ext] ?? defaultLanguage
    }

    private func normalizedExtension(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: ".", with: "")
    }

    private func normalizedLanguage(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? "plaintext" : trimmed
    }
}

extension Notification.Name {
    static let syntaxHighlightSettingsDidChange = Notification.Name("sheeptext.syntaxHighlight.settingsDidChange")
}
