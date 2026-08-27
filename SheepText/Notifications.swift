import Foundation

nonisolated private struct MainActorNotification: @unchecked Sendable {
    let value: Notification
}

extension NotificationCenter {
    /// Foundation does not express that an `.main` operation queue is the main
    /// actor. Centralize that Objective-C interoperability boundary here.
    @discardableResult
    @MainActor
    func addMainActorObserver(
        forName name: Notification.Name?,
        object obj: (any AnyObject)?,
        queue: OperationQueue = .main,
        using block: @escaping @MainActor @Sendable (Notification) -> Void
    ) -> NSObjectProtocol {
        precondition(queue === OperationQueue.main)
        return addObserver(forName: name, object: obj, queue: queue) { notification in
            let notification = MainActorNotification(value: notification)
            MainActor.assumeIsolated {
                block(notification.value)
            }
        }
    }
}

extension Notification.Name {
    static let editorNewDocument = Notification.Name("sheeptext.editor.newDocument")
    static let documentReloadedFromDisk = Notification.Name("sheeptext.document.reloadedFromDisk")
    static let editorAppearanceDidChange = Notification.Name("sheeptext.editor.appearanceDidChange")
    static let findInFilesShow = Notification.Name("sheeptext.findInFiles.show")
    static let recoveredDraftsShow = Notification.Name("sheeptext.recoveredDrafts.show")
    static let showDraftsFolder = Notification.Name("sheeptext.drafts.showFolder")
    static let reloadPlugins = Notification.Name("sheeptext.developer.reloadPlugins")
}
