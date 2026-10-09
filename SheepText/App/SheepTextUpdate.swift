//
//  SheepTextUpdate.swift
//  SheepText's half of the Sheep-family in-app updater: the ONLY file that ties
//  the generic updater in SheepText/Update/ (copied unchanged from SheepTerm
//  5.0, Oct 2026) to this app. Releases come from the public repository's
//  latest GitHub Release: `SheepText-<version>.zip` plus its Ed25519
//  `.zip.sig`, both made by the Sheep-family release.sh (/ship) from `.ship.conf`.
//
//  Replaces the old `UpdateChecker` (up to 3.8), which only opened the
//  release page in the browser.
//

import AppKit

extension UpdateConfig {
    /// The Ed25519 key whose private half is in the release Mac's login
    /// Keychain (service `signingKeychainService`, account `ed25519`, made once
    /// by SheepTerm's Tools/update-keygen.sh). `.ship.conf` carries the same
    /// value as UPDATE_SIGN_PUBLIC_KEY, and UpdaterTests fails when the two
    /// differ. One key per app: not SheepTerm's.
    nonisolated static let sheepText = UpdateConfig(
        appName: "SheepText",
        repository: "bestonehxh/SheepText",
        tagScheme: .semver,
        publicKeyBase64: "OHrxPBs1XLaNGZYAU+95S3YgU+akA3SEjOAltnypozU=",
        signingKeychainService: "Bestchaan.SheepText.update-signing"
    )
}

@MainActor
enum AppUpdater {
    static let shared = Updater(config: .sheepText, hooks: UpdateHooks(
        // The same Save / Don't Save / Cancel round ⌘Q runs for unsaved
        // documents (DocumentStore.applicationShouldTerminate), auto-save and
        // draft flushing included.
        confirmBeforeQuit: { SheepTextAppDelegate.confirmQuitForUpdate() },
        // Already answered: applicationShouldTerminate must not ask again.
        prepareForQuit: { SheepTextAppDelegate.quitAlreadyConfirmed = true },
        presenter: CenteredUpdatePresenter()  // centred (a plain NSAlert left-aligns Details)
    ))
}
