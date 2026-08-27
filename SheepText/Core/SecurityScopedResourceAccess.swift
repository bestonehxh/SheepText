//
//  SecurityScopedResourceAccess.swift
//  Keeps sandbox file/folder permissions alive across app launches.
//

import Foundation

nonisolated enum SecurityScopedResourceAccess {
    static let fileBookmarksKey = "sheeptext.securityScoped.fileBookmarks"
    static let workspaceBookmarksKey = "sheeptext.securityScoped.workspaceBookmarks"

    private static let activePathsLock = NSLock()
    nonisolated(unsafe) private static var activePaths = Set<String>()

    static func prepare(_ url: URL, bookmarkKey: String, shouldRemember: Bool) -> URL {
        let path = url.standardizedFileURL.path

        if let resolved = resolveBookmark(forPath: path, bookmarkKey: bookmarkKey) {
            startAccessing(resolved)
            if shouldRemember {
                remember(resolved, bookmarkKey: bookmarkKey)
            }
            return resolved
        }

        startAccessing(url)
        if shouldRemember {
            remember(url, bookmarkKey: bookmarkKey)
        }
        return url
    }

    static func restore(path: String, bookmarkKey: String) -> URL {
        if let resolved = resolveBookmark(forPath: path, bookmarkKey: bookmarkKey) {
            startAccessing(resolved)
            return resolved
        }

        let url = URL(fileURLWithPath: path)
        startAccessing(url)
        return url
    }

    static func remember(_ url: URL, bookmarkKey: String) {
        guard let data = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }

        var bookmarks = storedBookmarks(for: bookmarkKey)
        bookmarks[url.standardizedFileURL.path] = data
        UserDefaults.standard.set(bookmarks, forKey: bookmarkKey)
    }

    @discardableResult
    static func startAccessing(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return activePathsLock.withLock {
            guard !activePaths.contains(path) else { return true }

            let didStart = url.startAccessingSecurityScopedResource()
            if didStart {
                activePaths.insert(path)
            }
            return didStart
        }
    }

    private static func resolveBookmark(forPath path: String, bookmarkKey: String) -> URL? {
        guard let data = storedBookmarks(for: bookmarkKey)[path] else { return nil }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }

        if isStale {
            remember(url, bookmarkKey: bookmarkKey)
        }
        return url
    }

    private static func storedBookmarks(for key: String) -> [String: Data] {
        guard let raw = UserDefaults.standard.dictionary(forKey: key) else { return [:] }

        var bookmarks: [String: Data] = [:]
        for (path, value) in raw {
            if let data = value as? Data {
                bookmarks[path] = data
            }
        }
        return bookmarks
    }
}
