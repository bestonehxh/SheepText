//
//  UIBridge.swift
//  Exposed to plugin JS as `ui`. All methods run on the main actor.
//

import Foundation
import AppKit
import JavaScriptCore
import UserNotifications

@objc protocol UIBridgeExports: JSExport {
    func showNotification(_ message: String, _ kind: String)
    func showStatusMessage(_ message: String)
}

@objc final class UIBridge: NSObject, UIBridgeExports {

    func showNotification(_ message: String, _ kind: String) {
        // Deliberately async even on the main thread: runModal() spins a nested
        // run loop, and a plugin should not have the modal come up in the middle
        // of its own JS frame.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let alert = NSAlert()
                alert.messageText = message
                switch kind {
                case "warning": alert.alertStyle = .warning
                case "error":   alert.alertStyle = .critical
                default:        alert.alertStyle = .informational
                }
                alert.runModal()
            }
        }
    }

    /// Transient one-line message for the status bar.
    ///
    /// Posts `.statusMessage`. **Nothing observes it yet** — `StatusBarView`
    /// needs a slot for it — so today this call is silent, which is why the
    /// contract is written down here rather than left implicit:
    ///
    ///   name:     `.statusMessage` ("sheeptext.ui.statusMessage")
    ///   object:   nil (app-wide, not per document or per window)
    ///   userInfo: `["message": String]` under `UIBridge.statusMessageKey`
    ///
    /// The method is kept rather than removed: the bundled hello-world plugin
    /// calls it, and the notification is the right shape for the observer —
    /// only the observer is missing.
    func showStatusMessage(_ message: String) {
        pluginMainAsync {
            NotificationCenter.default.post(
                name: .statusMessage,
                object: nil,
                userInfo: [UIBridge.statusMessageKey: message]
            )
        }
    }

    /// `userInfo` key carrying the `String` message of a `.statusMessage` post.
    nonisolated static let statusMessageKey = "message"
}

extension Notification.Name {
    static let statusMessage = Notification.Name("sheeptext.ui.statusMessage")
}
