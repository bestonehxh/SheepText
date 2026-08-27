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

    func showStatusMessage(_ message: String) {
        pluginMainAsync {
            NotificationCenter.default.post(
                name: .statusMessage,
                object: nil,
                userInfo: ["message": message]
            )
        }
    }
}

extension Notification.Name {
    static let statusMessage = Notification.Name("sheeptext.ui.statusMessage")
}
