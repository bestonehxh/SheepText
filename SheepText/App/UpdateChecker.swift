//
//  UpdateChecker.swift
//  Checks https://github.com/bestonehxh/SheepText/releases/latest for a newer version.
//

import AppKit

@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    private var isChecking = false

    /// Call with silent=true on launch (no alert when already up-to-date).
    /// Call with silent=false from the menu item (always shows result).
    func checkForUpdates(silent: Bool = false) {
        guard !isChecking else { return }
        isChecking = true
        Task {
            defer { self.isChecking = false }
            do {
                let release = try await Self.fetchLatestRelease()
                self.present(release, silent: silent)
            } catch {
                if !silent {
                    self.presentError(error)
                }
            }
        }
    }

    // MARK: - Private

    private static func fetchLatestRelease() async throws -> GitHubRelease {
        let url = URL(string: "https://api.github.com/repos/bestonehxh/SheepText/releases/latest")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private func present(_ release: GitHubRelease, silent: Bool) {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let latest  = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))

        if isNewer(latest, than: current) {
            let alert = NSAlert()
            alert.messageText     = "Update Available"
            alert.informativeText = "SheepText \(latest) is available (you have \(current))."
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: release.htmlURL) {
                NSWorkspace.shared.open(url)
            }
        } else if !silent {
            let alert = NSAlert()
            alert.messageText     = "You're Up to Date"
            alert.informativeText = "SheepText \(current) is the latest version."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText     = "Update Check Failed"
        alert.informativeText = "Could not reach GitHub. Check your internet connection.\n\n\(error.localizedDescription)"
        alert.runModal()
    }

    private func isNewer(_ latest: String, than current: String) -> Bool {
        let a = latest.split(separator: ".").compactMap { Int($0) }
        let b = current.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(a.count, b.count) {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String
    let name: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case name
    }
}
