// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
//  Atmos offline play. A game that is already installed starts without waiting on
//  the network: with no connection (or with Offline mode on), Play skips the
//  checks that can only time out there (the Steam Cloud check before a start,
//  Steam's launch configuration lookup) and Madeira Dock asks Valve's client for
//  its offline logon straight away (DockOffline). Saves that changed on both
//  sides are still never overwritten: the next online sync compares them as
//  usual, and a conflict found earlier still holds the start.
//
//  "Prepare for offline" does the network part ahead of time while there is a
//  connection: it stores each installed Steam game's launch configuration and
//  syncs its saves, so the first start on a plane is the same as at home.
//

import Foundation
import Network
import SwiftUI

enum OfflinePlay {
    /// Settings › Offline play: treat the device as offline even with a connection.
    static let forcedKey = "atmosOfflineMode"
    static var forced: Bool { UserDefaults.standard.bool(forKey: forcedKey) }

    private static let monitor = NWPathMonitor()
    private static let lock = NSLock()
    private static var seenPath = false
    private static var down = false
    private static var started = false

    /// Starts the path monitor; called at app start, again harmlessly.
    static func begin() {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { path in
            lock.lock(); seenPath = true; down = path.status != .satisfied; lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "atmos.offline.path", qos: .utility))
    }

    /// No usable network path right now. False until the first path report.
    static var networkDown: Bool {
        begin()
        lock.lock(); defer { lock.unlock() }
        return seenPath && down
    }

    /// Starts skip network-only checks: no connection, or Offline mode is on.
    static var active: Bool { forced || networkDown }

    /// One log line per reason per app run, so a library full of starts stays readable.
    private static var logged = Set<String>()
    static func note(_ what: String) {
        lock.lock(); let first = logged.insert(what).inserted; lock.unlock()
        if first { LogStore.shared.log("[offline] \(what) (\(forced ? "Offline mode" : "no network"))") }
    }
}

/// "Prepare for offline": launch configurations and saves, fetched while online.
@MainActor
final class OfflinePrep: ObservableObject {
    static let shared = OfflinePrep()
    static let lastKey = "atmosOfflinePreparedAt"

    @Published private(set) var running = false
    @Published private(set) var progress: (done: Int, total: Int) = (0, 0)
    @Published private(set) var result: String?

    var lastPrepared: Date? {
        let t = UserDefaults.standard.double(forKey: Self.lastKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    func run() {
        guard !running else { return }
        guard !OfflinePlay.active else { result = "Connect to the internet first, then prepare."; return }
        guard SteamSignIn.isSignedIn else { result = "Sign in to Steam first (Settings › Steam and Dock)."; return }
        let games = MadeiraDock.games(drive: MadeiraDock.drive).filter(\.installed)
        guard !games.isEmpty else { result = "No installed Steam games to prepare."; return }
        running = true; result = nil; progress = (0, games.count)
        LogStore.shared.log("[offline] preparing \(games.count) installed Steam game(s) for offline play")
        Task { @MainActor in
            var configured = 0
            for game in games {
                if let launches = await SteamOwnedLibrary.shared.launchOptions(appID: game.id), !launches.isEmpty { configured += 1 }
                if SteamOwnedLibrary.cloudEnabled { await SteamOwnedLibrary.shared.syncCloud(game.id) }
                progress.done += 1
            }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastKey)
            running = false
            result = "\(games.count) game\(games.count == 1 ? "" : "s") ready. Launch settings stored for \(configured)."
            LogStore.shared.log("[offline] prepared games=\(games.count) launch-configs=\(configured)")
        }
    }
}

/// Settings › Offline play.
struct OfflinePlaySettingsSection: View {
    @AppStorage(OfflinePlay.forcedKey) private var forced = false
    @ObservedObject private var prep = OfflinePrep.shared
    @State private var networkDown = OfflinePlay.networkDown

    var body: some View {
        Section {
            LabeledContent("Network") {
                Label(networkDown ? "Offline" : "Online", systemImage: networkDown ? "wifi.slash" : "wifi")
                    .foregroundStyle(networkDown ? Color.orange : Color.green)
            }
            Toggle("Offline mode", isOn: $forced)
        } footer: {
            Text("Installed games start without waiting for Steam Cloud or Steam's servers. Atmos does this automatically with no connection; turn Offline mode on for poor connections. Saves sync the next time you are online.")
        }
        Section {
            Button {
                prep.run()
            } label: {
                HStack {
                    Label("Prepare for offline", systemImage: "arrow.down.circle")
                    Spacer()
                    if prep.running {
                        ProgressView().controlSize(.small)
                        Text("\(prep.progress.done)/\(prep.progress.total)").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(prep.running)
            if let result = prep.result {
                Text(result).font(.footnote).foregroundStyle(.secondary)
            } else if let last = prep.lastPrepared {
                LabeledContent("Last prepared") { Text(last, style: .relative) }
            }
        } footer: {
            Text("Stores each installed Steam game's launch settings and syncs its saves now. Start each Steam game once while online so Steam can sign in offline later.")
        }
        .task {
            while !Task.isCancelled {
                networkDown = OfflinePlay.networkDown
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}
