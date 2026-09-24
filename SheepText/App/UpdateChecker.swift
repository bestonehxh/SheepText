//
//  UpdateChecker.swift
//  Checks https://github.com/bestonehxh/SheepText/releases/latest for a newer version.
//

import AppKit

@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    private var isChecking = false

    /// How long an automatic (launch-time) check stays satisfied. The menu
    /// item ignores this — an explicit "Check for Updates…" always checks.
    nonisolated static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    /// Launch-time entry point. Does nothing when the user turned automatic
    /// checks off, or when one already ran inside `automaticCheckInterval`.
    /// Records the attempt before starting it so a machine that is offline for
    /// a week does not hit GitHub on every single launch.
    func checkForUpdatesOnLaunchIfDue(preferences: AppPreferences, now: Date = Date()) {
        guard Self.isAutomaticCheckDue(
            enabled: preferences.checksForUpdatesAutomatically,
            lastCheck: preferences.lastAutomaticUpdateCheck,
            now: now
        ) else { return }
        preferences.lastAutomaticUpdateCheck = now
        checkForUpdates(silent: true)
    }

    /// Pure throttle predicate, split out so it can be tested without a network.
    nonisolated static func isAutomaticCheckDue(enabled: Bool, lastCheck: Date?, now: Date) -> Bool {
        guard enabled else { return false }
        guard let lastCheck else { return true }
        // A clock that moved backwards (timezone fix, NTP correction) leaves a
        // future timestamp behind; treat that as due rather than never-again.
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed < 0 || elapsed >= automaticCheckInterval
    }

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
        let url = URL(string: "https://api.github.com/repos/\(repositoryPath)/releases/latest")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        // The response used to be discarded, so a 403 body — which is what the
        // unauthenticated API answers after 60 requests an hour — went to the
        // decoder and came back as "could not reach GitHub".
        if let http = response as? HTTPURLResponse,
           let error = responseError(forStatusCode: http.statusCode) {
            throw error
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    /// `nil` for a status this app will read a release out of. Split out as a
    /// pure function so the rate-limit case can be tested without a network.
    nonisolated static func responseError(forStatusCode status: Int) -> UpdateCheckError? {
        switch status {
        case 200..<300: return nil
        case 403, 429:  return .rateLimited
        default:        return .badStatus(status)
        }
    }

    private func present(_ release: GitHubRelease, silent: Bool) {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let latest  = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))

        if Self.isNewer(latest, than: current) {
            let alert = NSAlert()
            alert.messageText     = "Update Available"
            alert.informativeText = "SheepText \(latest) is available (you have \(current))."
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(Self.downloadURL(htmlURL: release.htmlURL))
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
        // A rate limit is not a connection problem, and telling the user to
        // check their internet when GitHub is throttling them sends them
        // looking in the wrong place.
        if let updateError = error as? UpdateCheckError {
            alert.informativeText = updateError.errorDescription ?? "\(updateError)"
        } else {
            alert.informativeText = "Could not reach GitHub. Check your internet connection.\n\n\(error.localizedDescription)"
        }
        alert.runModal()
    }

    // MARK: - Where "Download" goes

    /// The repository the app updates from, as path components. The host check
    /// below compares components, not a string prefix, so
    /// `/bestonehxh/SheepTextEvil` cannot pass as `/bestonehxh/SheepText`.
    nonisolated static let repositoryPath = "bestonehxh/SheepText"

    /// Where "Download" goes when the release JSON does not name a page this
    /// app is willing to open.
    nonisolated static let releasesPageURL =
        URL(string: "https://github.com/\(repositoryPath)/releases/latest")!

    /// `html_url` out of the release JSON is a string this app did not write —
    /// it went straight to `NSWorkspace.open`, which honours `file://` and
    /// every registered custom scheme, and since 3.7 there is no sandbox around
    /// what that launches. Accept only an https page in this repository;
    /// anything else means the hard-coded releases page, which is always right
    /// even when it is not the exact release.
    nonisolated static func downloadURL(htmlURL: String) -> URL {
        guard let url = URL(string: htmlURL),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com"
        else { return releasesPageURL }

        // pathComponents of "/owner/repo/releases/..." is ["/", "owner", "repo", …].
        let expected = repositoryPath.split(separator: "/").map(String.init)
        let components = url.pathComponents.dropFirst()
        guard components.count >= expected.count,
              Array(components.prefix(expected.count)) == expected
        else { return releasesPageURL }

        return url
    }

    /// Compare two version strings.
    ///
    /// `compactMap { Int($0) }` was wrong twice over: it DROPPED any component
    /// that did not parse whole, so "1.3.5-beta.2" became `[1, 3, 2]` — a
    /// three-component version whose last component is the beta number, which
    /// compares as 1.3.2 and reports a *downgrade*. And "1.3.5 (17)" became
    /// `[1, 3]`, i.e. 1.3.0. Now the numeric core is taken up to the first
    /// "-", "+" or " ", and any component that still does not parse is 0 rather
    /// than absent, so positions never shift.
    ///
    /// A pre-release tag therefore compares equal to its release ("1.3.5-beta.2"
    /// is not newer than "1.3.5"), which is the conservative answer for an
    /// update prompt: we never push a user from a release onto a pre-release.
    nonisolated static func isNewer(_ latest: String, than current: String) -> Bool {
        let a = numericComponents(of: latest)
        let b = numericComponents(of: current)
        for i in 0..<max(a.count, b.count) {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }

    /// "1.3.5-beta.2" -> [1, 3, 5];  "1.3.5 (17)" -> [1, 3, 5];  "2.0" -> [2, 0].
    nonisolated private static func numericComponents(of version: String) -> [Int] {
        let core = version.prefix { $0 != "-" && $0 != "+" && $0 != " " }
        return core.split(separator: ".").map { Int($0) ?? 0 }
    }
}

enum UpdateCheckError: LocalizedError, Equatable {
    case rateLimited
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .rateLimited:
            return "GitHub is rate-limiting update checks from this network. Try again later."
        case .badStatus(let code):
            return "GitHub answered the update check with HTTP \(code)."
        }
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
