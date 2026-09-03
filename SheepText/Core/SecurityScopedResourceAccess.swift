//
//  SecurityScopedResourceAccess.swift
//  Keeps sandbox file/folder permissions alive across app launches.
//

import Foundation

nonisolated enum SecurityScopedResourceAccess {
    static let fileBookmarksKey = "sheeptext.securityScoped.fileBookmarks"
    static let workspaceBookmarksKey = "sheeptext.securityScoped.workspaceBookmarks"

    /// **Invariant: the URL instance that started a scope is the one that must
    /// be used for I/O, and it is never released.**
    ///
    /// `startAccessingSecurityScopedResource()` grants access to the *instance*
    /// it was called on, not to the path. This table used to be a `Set<String>`
    /// of paths, so the second `prepare` of a path resolved a fresh bookmark,
    /// saw the path already listed, skipped `startAccessing` — and handed back a
    /// URL that had never been granted anything. It worked only because the
    /// first instance was still holding the scope open somewhere else in the
    /// process, and would have broken the moment we started balancing the calls
    /// with `stopAccessingSecurityScopedResource()`.
    ///
    /// Now the owning instance is stored and returned, so every caller does its
    /// I/O through a URL that actually holds the grant. Scopes are deliberately
    /// held for the lifetime of the process: the app can have the same file open
    /// in a tab, in Find in Files and in the disk-change poll at once, and there
    /// is no refcount that would make a balanced `stop` correct.
    private static let activeScopesLock = NSLock()
    nonisolated(unsafe) private static var activeScopes: [String: URL] = [:]

    static func prepare(_ url: URL, bookmarkKey: String, shouldRemember: Bool) -> URL {
        let path = url.standardizedFileURL.path

        // Already scoped: skip the bookmark dictionary decode entirely. That
        // decode is a UserDefaults dictionary copy plus a
        // URL(resolvingBookmarkData:) per call, and this is called per open
        // document every 4 seconds and per file in Find in Files.
        if let owner = activeScope(forPath: path) {
            if shouldRemember {
                remember(owner, bookmarkKey: bookmarkKey)
            }
            return owner
        }

        if let resolved = resolveBookmark(forPath: path, bookmarkKey: bookmarkKey) {
            let owner = startAccessing(resolved)
            if shouldRemember {
                remember(owner, bookmarkKey: bookmarkKey)
            }
            return owner
        }

        let owner = startAccessing(url)
        if shouldRemember {
            remember(owner, bookmarkKey: bookmarkKey)
        }
        return owner
    }

    static func restore(path: String, bookmarkKey: String) -> URL {
        if let owner = activeScope(forPath: path) { return owner }

        if let resolved = resolveBookmark(forPath: path, bookmarkKey: bookmarkKey) {
            return startAccessing(resolved)
        }

        return startAccessing(URL(fileURLWithPath: path))
    }

    private static func activeScope(forPath path: String) -> URL? {
        activeScopesLock.withLock { activeScopes[path] }
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

    /// Starts (or re-uses) the scope for this path and returns the URL instance
    /// that owns it — which may not be the one passed in. Do the I/O through the
    /// returned instance.
    @discardableResult
    static func startAccessing(_ url: URL) -> URL {
        let path = url.standardizedFileURL.path
        return activeScopesLock.withLock {
            if let owner = activeScopes[path] { return owner }

            if url.startAccessingSecurityScopedResource() {
                activeScopes[path] = url
            }
            return url
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
