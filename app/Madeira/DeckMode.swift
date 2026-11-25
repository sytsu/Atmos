// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
//  Atmos Deck Mode: Valve's Steam client in Big Picture as the phone's handheld
//  home, after iDeck (github.com/kuscholar/iDeck, GPL-3.0-or-later), built on the
//  Big Picture launch Madeira already has (LibraryEntry.bigPictureEntry: C:\
//  big-picture.bat in the Wine desktop, its own Steam folder, the 32-bit client
//  kept once installed). Deck Mode is a runtime switch instead of a build flag:
//  it puts Big Picture beside Desktop and in the controller's focus order, shows
//  what is still missing before it can start, and can start it (or the last game
//  played) as soon as Atmos opens. In the session, the floating menu every game
//  has is the Deck button: keyboard, touch controls, Back+Start or Home for the menu.
//

import SwiftUI

enum DeckMode {
    static let enabledKey = "atmosDeckMode"
    static let startKey = "atmosStartAction"
    private static let lastAutoStartKey = "atmosAutoStartAt"

    /// Big Picture is offered: Deck Mode is on, or the build has MADEIRA_BIG_PICTURE_UI.
    static var enabled: Bool { LibraryEntry.bigPictureShown || UserDefaults.standard.bool(forKey: enabledKey) }

    /// What starts when Atmos opens.
    enum StartAction: String, CaseIterable, Identifiable {
        case none, bigPicture, lastGame
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: return "Library"
            case .bigPicture: return "Big Picture"
            case .lastGame: return "Last game played"
            }
        }
    }
    static var startAction: StartAction {
        StartAction(rawValue: UserDefaults.standard.string(forKey: startKey) ?? "") ?? .none
    }

    /// Big Picture's interface (the client and its web helper) has been downloaded once.
    static var interfaceInstalled: Bool {
        guard let folder = LibraryEntry.bigPictureFolder else { return false }
        return FileManager.default.fileExists(atPath: "\(folder.unix)/bin/cef/cef.win7/steamwebhelper.exe")
    }

    private static var startTaken = false
    /// The entry to start as Atmos opens, at most once per app run. Nil for the
    /// library, or when the last automatic start was moments ago: a start that
    /// ends the app at once must not trap it in a loop.
    @MainActor static func takeStartEntry(from entries: [LibraryEntry]) -> LibraryEntry? {
        guard !startTaken else { return nil }
        startTaken = true
        let action = startAction
        guard action != .none else { return nil }
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: lastAutoStartKey)
        if last > 0, now - last >= 0, now - last < 20 {
            LogStore.shared.log("[deck] automatic start skipped: the previous one was \(Int(now - last)) s ago")
            return nil
        }
        let entry: LibraryEntry?
        switch action {
        case .none:
            entry = nil
        case .bigPicture:
            entry = enabled && LibraryEntry.steamClientInstalled
                ? (entries.first { $0.bigPicture == true } ?? .bigPictureEntry) : nil
        case .lastGame:
            entry = entries.filter { $0.desktop != true && $0.lastPlayed != nil }
                .max { ($0.lastPlayed ?? .distantPast) < ($1.lastPlayed ?? .distantPast) }
        }
        guard let entry else {
            LogStore.shared.log("[deck] automatic start (\(action.rawValue)): nothing to start")
            return nil
        }
        UserDefaults.standard.set(now, forKey: lastAutoStartKey)
        LogStore.shared.log("[deck] automatic start (\(action.rawValue)): \(entry.title)")
        return entry
    }
}

/// Settings › Deck Mode.
struct DeckModeSettingsSection: View {
    @AppStorage(DeckMode.enabledKey) private var enabled = false
    @AppStorage(DeckMode.startKey) private var start = DeckMode.StartAction.none.rawValue
    @ObservedObject private var jitState = LibraryJITState.shared
    @ObservedObject private var controller = LibraryController.shared

    var body: some View {
        Section {
            Toggle(isOn: $enabled) {
                Label("Deck Mode", systemImage: "gamecontroller")
            }
        } footer: {
            Text("Adds Big Picture beside Desktop: Steam's own controller interface, full screen, for a handheld feel. Inspired by iDeck.")
        }
        if enabled || LibraryEntry.bigPictureShown {
            Section {
                check("Signed in to Steam", SteamSignIn.isSignedIn, fix: "Settings › Steam and Dock")
                check("Steam components installed", LibraryEntry.steamClientInstalled, fix: "Prepare Madeira Dock in Settings › Steam and Dock")
                check("Big Picture interface", DeckMode.interfaceInstalled, fix: "Downloads from Valve on the first start", optional: true)
                check("JIT", jitState.enabled, fix: "Turns on when you start", optional: true)
                check("Controller", controller.connected, fix: "Touch works too", optional: true)
            } header: { Text("Ready to play") }
        }
        Section {
            Picker("When Atmos opens", selection: $start) {
                ForEach(DeckMode.StartAction.allCases.filter { $0 != .bigPicture || enabled || LibraryEntry.bigPictureShown }) {
                    Text($0.title).tag($0.rawValue)
                }
            }
        } footer: {
            Text("Big Picture or your last game starts as soon as Atmos opens, once JIT is on. Opening a shortcut or a game link still starts that instead.")
        }
    }

    private func check(_ title: String, _ ok: Bool, fix: String, optional: Bool = false) -> some View {
        LabeledContent {
            if !ok { Text(fix).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: ok ? "checkmark.circle.fill" : optional ? "circle.dashed" : "exclamationmark.circle.fill")
                    .foregroundStyle(ok ? Color.green : optional ? Color.secondary : Color.orange)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(ok ? "Done" : fix)
    }
}
