// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
//  Game details › Game files: a game's folder and its save and settings folders,
//  browsed and edited in the app, plus a small mod manager.
//
//  - Text files (configs, scripts, logs) open in an editor that keeps the file's
//    encoding, byte-order mark and line endings. The first save keeps a copy of
//    the original in Documents/Atmos Backups, which Restore Original puts back.
//  - Deleted files are moved to Atmos Backups, never erased.
//  - Mods: files and folders chosen in Files are merged into the game's folder.
//    Names match what is already there regardless of case (Windows games expect
//    that, and iOS's file system is case-sensitive). Every file a mod replaces is
//    kept, so removing the mod restores the game exactly.
//

import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: Model

/// A folder the browser can show: its top (the browser never goes above it), a
/// stable key for its backups and mods, and its title.
struct GameFilesPlace: Hashable {
    let root: URL
    let key: String
    let title: String
}

struct GameFileItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date?
    var id: String { url.path }
}

enum GameFiles {
    static let documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let backupsRoot = documents.appendingPathComponent("Atmos Backups", isDirectory: true)
    static let modsRoot = documents.appendingPathComponent("Atmos Mods", isDirectory: true)
    /// Larger text files are not opened in the editor.
    static let editLimit = 2 * 1024 * 1024

    static let textExtensions: Set<String> = [
        "ini", "cfg", "conf", "config", "cnf", "txt", "json", "jsonc", "xml", "lua", "yaml", "yml", "toml",
        "log", "properties", "prefs", "csv", "tsv", "bat", "cmd", "md", "inf", "vdf", "acf", "nfo", "reg",
        "html", "htm", "js", "css", "py", "sh", "ltx", "sii", "cs", "hlsl", "fx", "shader", "glsl", "lst",
        "manifest", "plist", "srt", "ass", "lang", "loc", "settings", "mcmeta", "ron", "gd", "tres", "tscn",
    ]

    static func isText(_ url: URL) -> Bool { textExtensions.contains(url.pathExtension.lowercased()) }

    /// A file name safe for one folder level, readable, and unique per path.
    static func key(for relativePath: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in relativePath.lowercased().utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        let last = relativePath.split(separator: "/").last.map(String.init) ?? "drive_c"
        let clean = String(last.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" }.map(Character.init))
        return (clean.isEmpty ? "game" : String(clean.prefix(40))) + "-" + String(hash & 0xffff_ffff, radix: 16)
    }

    /// The game's folder under drive_c (GameIniFiles.gameFolder's result).
    static func gamePlace(gameFolder: String, title: String) -> GameFilesPlace {
        let folder = gameFolder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return GameFilesPlace(root: LibraryModel.drive.appendingPathComponent(folder, isDirectory: true),
                              key: key(for: folder), title: title)
    }

    /// Where Windows games keep saves and settings, for every prefix user that has them.
    static func userPlaces() -> [GameFilesPlace] {
        let fm = FileManager.default
        let users = LibraryModel.drive.appendingPathComponent("users", isDirectory: true)
        let names = ((try? fm.contentsOfDirectory(atPath: users.path)) ?? []).filter { $0 != "Public" && !$0.hasPrefix(".") }.sorted()
        let folders = [("Documents/My Games", "My Games"), ("Saved Games", "Saved Games"),
                       ("AppData/Local", "AppData Local"), ("AppData/Roaming", "AppData Roaming"), ("Documents", "Documents")]
        var places: [GameFilesPlace] = []
        for user in names {
            for (path, title) in folders {
                let url = users.appendingPathComponent(user, isDirectory: true).appendingPathComponent(path, isDirectory: true)
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                let relative = "users/\(user)/\(path)"
                places.append(GameFilesPlace(root: url, key: key(for: relative), title: names.count > 1 ? "\(title) (\(user))" : title))
            }
        }
        return places
    }

    /// The folder's contents, folders first, then by name as Finder sorts.
    static func list(_ folder: URL) throws -> [GameFileItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [])
        return urls.compactMap { url -> GameFileItem? in
            let name = url.lastPathComponent
            guard name != ".DS_Store" else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            return GameFileItem(url: url, name: name, isDirectory: values?.isDirectory ?? false,
                                size: Int64(values?.fileSize ?? 0), modified: values?.contentModificationDate)
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// The Files app at this folder (it lives in Atmos's Documents, which Files shows).
    static func openInFiles(_ folder: URL) {
        let path = folder.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? folder.path
        if let url = URL(string: "shareddocuments://" + path) { UIApplication.shared.open(url) }
    }

    /// The original of `relative`, kept the first time it is saved from the editor.
    static func originalCopy(_ place: GameFilesPlace, _ relative: String) -> URL {
        backupsRoot.appendingPathComponent(place.key, isDirectory: true)
            .appendingPathComponent("originals", isDirectory: true).appendingPathComponent(relative)
    }

    /// Moves a file or folder into Atmos Backups instead of erasing it.
    static func moveToBackups(_ item: URL, place: GameFilesPlace, relative: String) throws {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dest = backupsRoot.appendingPathComponent(place.key, isDirectory: true)
            .appendingPathComponent("deleted", isDirectory: true).appendingPathComponent(stamp, isDirectory: true)
            .appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: item, to: dest)
        LogStore.shared.log("[game-files] moved \(relative) to Atmos Backups")
    }

    /// A name for one folder level: no slashes, nothing reserved on Windows, not empty.
    static func validName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              !name.unicodeScalars.contains(where: { $0.value < 0x20 || "/\\:*?\"<>|".unicodeScalars.contains($0) }) else { return nil }
        return name
    }

    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

// MARK: Text files

/// A text file's text with what saving needs to write it back the same way.
struct GameTextFile: Equatable {
    enum Encoding: Equatable { case utf8, utf8BOM, utf16LE, utf16BE, latin1 }
    var text: String
    let encoding: Encoding
    let crlf: Bool

    /// Decodes `data`; the text uses "\n" whatever the file had.
    init(data: Data) {
        let bytes = [UInt8](data.prefix(3))
        var decoded: String
        var found: Encoding
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF,
           let s = String(data: data.dropFirst(3), encoding: .utf8) {
            decoded = s; found = .utf8BOM
        } else if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE,
                  let s = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
            decoded = s; found = .utf16LE
        } else if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF,
                  let s = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
            decoded = s; found = .utf16BE
        } else if let s = String(data: data, encoding: .utf8) {
            decoded = s; found = .utf8
        } else {
            decoded = String(data: data, encoding: .isoLatin1) ?? ""; found = .latin1
        }
        let hasCRLF = decoded.contains("\r\n")
        if hasCRLF { decoded = decoded.replacingOccurrences(of: "\r\n", with: "\n") }
        text = decoded
        encoding = found
        crlf = hasCRLF
    }

    /// The bytes for `text` in the file's own encoding and line endings; nil if a
    /// character cannot be written in it (Latin-1).
    func data(_ text: String) -> Data? {
        let body = crlf ? text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n") : text
        switch encoding {
        case .utf8: return body.data(using: .utf8)
        case .utf8BOM: return body.data(using: .utf8).map { Data([0xEF, 0xBB, 0xBF]) + $0 }
        case .utf16LE: return body.data(using: .utf16LittleEndian).map { Data([0xFF, 0xFE]) + $0 }
        case .utf16BE: return body.data(using: .utf16BigEndian).map { Data([0xFE, 0xFF]) + $0 }
        case .latin1: return body.data(using: .isoLatin1)
        }
    }

    var encodingName: String {
        switch encoding {
        case .utf8: return "UTF-8"
        case .utf8BOM: return "UTF-8 (BOM)"
        case .utf16LE: return "UTF-16 LE"
        case .utf16BE: return "UTF-16 BE"
        case .latin1: return "Latin-1"
        }
    }
}

// MARK: Mods

struct ModRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var installed: Date
    /// Paths relative to the game's folder, in the order they were written.
    var added: [String]
    var replaced: [String]
    var folders: [String]
}

enum ModInstaller {
    enum Failure: LocalizedError {
        case inTheWay(String)
        var errorDescription: String? {
            switch self {
            case .inTheWay(let path): return "\"\(path)\" is a file in the game but a folder in the mod (or the other way round)."
            }
        }
    }

    static func store(_ place: GameFilesPlace) -> URL { GameFiles.modsRoot.appendingPathComponent(place.key, isDirectory: true) }
    private static func index(_ place: GameFilesPlace) -> URL { store(place).appendingPathComponent("mods.json") }

    static func records(_ place: GameFilesPlace) -> [ModRecord] {
        guard let data = try? Data(contentsOf: index(place)) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ModRecord].self, from: data)) ?? []
    }

    private static func write(_ records: [ModRecord], _ place: GameFilesPlace) throws {
        try FileManager.default.createDirectory(at: store(place), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: index(place), options: .atomic)
    }

    /// Merges `items` (files or folders, each under its own name) into `targetRelative`
    /// under the place's root. Undone in full if any copy fails.
    static func install(_ items: [URL], into targetRelative: String, place: GameFilesPlace, name: String) throws -> ModRecord {
        let fm = FileManager.default
        var record = ModRecord(id: UUID(), name: name, installed: Date(), added: [], replaced: [], folders: [])
        let replacedRoot = store(place).appendingPathComponent(record.id.uuidString, isDirectory: true)
            .appendingPathComponent("replaced", isDirectory: true)
        try fm.createDirectory(at: replacedRoot, withIntermediateDirectories: true)
        let target = targetRelative.isEmpty ? place.root : place.root.appendingPathComponent(targetRelative, isDirectory: true)
        do {
            for item in items {
                let scoped = item.startAccessingSecurityScopedResource()
                defer { if scoped { item.stopAccessingSecurityScopedResource() } }
                try merge(item, into: target, relativeFolder: targetRelative, replacedRoot: replacedRoot, record: &record)
            }
        } catch {
            undo(record, place: place)
            throw error
        }
        var all = records(place)
        all.append(record)
        try write(all, place)
        LogStore.shared.log("[mods] \(place.title): installed \(name) added=\(record.added.count) replaced=\(record.replaced.count)")
        return record
    }

    /// The existing child of `folder` named `name` in any case, else `name`.
    private static func existingName(_ name: String, in folder: URL) -> String {
        let children = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return children.first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name
    }

    private static func merge(_ source: URL, into folder: URL, relativeFolder: String, replacedRoot: URL, record: inout ModRecord) throws {
        let fm = FileManager.default
        let sourceName = source.lastPathComponent
        if sourceName == ".DS_Store" || sourceName == "__MACOSX" { return }
        var sourceIsDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &sourceIsDirectory) else { return }
        let name = existingName(sourceName, in: folder)
        let dest = folder.appendingPathComponent(name, isDirectory: sourceIsDirectory.boolValue)
        let relative = relativeFolder.isEmpty ? name : relativeFolder + "/" + name
        var destIsDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: dest.path, isDirectory: &destIsDirectory)
        if exists, destIsDirectory.boolValue != sourceIsDirectory.boolValue { throw Failure.inTheWay(relative) }
        if sourceIsDirectory.boolValue {
            if !exists {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                record.folders.append(relative)
            }
            for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: []) {
                try merge(child, into: dest, relativeFolder: relative, replacedRoot: replacedRoot, record: &record)
            }
        } else {
            if exists {
                // Replaced twice by this mod (two items with one name): the first original stays.
                if !record.replaced.contains(relative) {
                    let saved = replacedRoot.appendingPathComponent(relative)
                    try fm.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: dest, to: saved)
                    record.replaced.append(relative)
                } else {
                    try fm.removeItem(at: dest)
                }
            } else {
                record.added.append(relative)
            }
            try fm.copyItem(at: source, to: dest)
        }
    }

    /// Takes the mod's files out and puts back what it replaced.
    static func uninstall(_ record: ModRecord, place: GameFilesPlace) throws {
        undo(record, place: place)
        try write(records(place).filter { $0.id != record.id }, place)
        LogStore.shared.log("[mods] \(place.title): removed \(record.name)")
    }

    private static func undo(_ record: ModRecord, place: GameFilesPlace) {
        let fm = FileManager.default
        let modStore = store(place).appendingPathComponent(record.id.uuidString, isDirectory: true)
        let replacedRoot = modStore.appendingPathComponent("replaced", isDirectory: true)
        for relative in record.added.reversed() { try? fm.removeItem(at: place.root.appendingPathComponent(relative)) }
        for relative in record.replaced.reversed() {
            let saved = replacedRoot.appendingPathComponent(relative)
            guard fm.fileExists(atPath: saved.path) else { continue }
            let dest = place.root.appendingPathComponent(relative)
            try? fm.removeItem(at: dest)
            try? fm.moveItem(at: saved, to: dest)
        }
        // Deepest first; a folder something else wrote into stays.
        for relative in record.folders.sorted(by: { $0.count > $1.count }) {
            let folder = place.root.appendingPathComponent(relative, isDirectory: true)
            if let left = try? fm.contentsOfDirectory(atPath: folder.path), left.isEmpty { try? fm.removeItem(at: folder) }
        }
        try? fm.removeItem(at: modStore)
    }
}

// MARK: Views

/// Game details › Game files.
struct GameFilesSection: View {
    let place: GameFilesPlace
    @State private var userPlaces: [GameFilesPlace] = []
    @State private var modCount = 0

    var body: some View {
        Group {
            Section {
                NavigationLink { GameFolderBrowser(place: place) } label: {
                    Label("Game folder", systemImage: "folder")
                }
                NavigationLink { GameModsPage(place: place) } label: {
                    LabeledContent {
                        if modCount > 0 { Text("\(modCount)") }
                    } label: { Label("Mods", systemImage: "puzzlepiece.extension") }
                }
                Button { GameFiles.openInFiles(place.root) } label: {
                    Label("Show in Files", systemImage: "arrow.up.forward.app")
                }
            } footer: {
                Text("Edit configs and scripts right here. The first time you save a file, Atmos keeps its original in Atmos Backups.")
            }
            if !userPlaces.isEmpty {
                Section {
                    ForEach(userPlaces, id: \.self) { place in
                        NavigationLink { GameFolderBrowser(place: place) } label: {
                            Label(place.title, systemImage: "person.crop.square")
                        }
                    }
                } header: { Text("Saves and settings") }
            }
        }
        .onAppear {
            userPlaces = GameFiles.userPlaces()
            modCount = ModInstaller.records(place).count
        }
    }
}

/// One folder of a place, with its files.
struct GameFolderBrowser: View {
    let place: GameFilesPlace
    /// The folder, relative to the place's root ("" for the root).
    var relative: String = ""

    @State private var items: [GameFileItem] = []
    @State private var loaded = false
    @State private var search = ""
    @State private var importing = false
    @State private var busy = false
    @State private var error: String?
    @State private var renaming: GameFileItem?
    @State private var deleting: GameFileItem?
    @State private var naming = false
    @State private var newName = ""

    private var folder: URL { relative.isEmpty ? place.root : place.root.appendingPathComponent(relative, isDirectory: true) }
    private var title: String { relative.isEmpty ? place.title : (relative as NSString).lastPathComponent }
    private var shown: [GameFileItem] { search.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(search) } }
    private func path(_ item: GameFileItem) -> String { relative.isEmpty ? item.name : relative + "/" + item.name }

    var body: some View {
        List {
            if loaded && items.isEmpty {
                Text("This folder is empty.").foregroundStyle(.secondary)
            }
            ForEach(shown) { item in
                link(item)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { deleting = item } label: { Label("Delete", systemImage: "trash") }
                        Button { newName = item.name; renaming = item } label: { Label("Rename", systemImage: "pencil") }
                    }
                    .contextMenu {
                        Button { newName = item.name; renaming = item } label: { Label("Rename", systemImage: "pencil") }
                        if !item.isDirectory { ShareLink(item: item.url) { Label("Share", systemImage: "square.and.arrow.up") } }
                        Button(role: .destructive) { deleting = item } label: { Label("Delete", systemImage: "trash") }
                    }
            }
        }
        .overlay { if !loaded { ProgressView() } }
        .searchable(text: $search, prompt: "Search this folder")
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { importing = true } label: { Label("Add files from Files…", systemImage: "square.and.arrow.down") }
                    Button { newName = ""; naming = true } label: { Label("New folder", systemImage: "folder.badge.plus") }
                    Button { GameFiles.openInFiles(folder) } label: { Label("Show in Files", systemImage: "arrow.up.forward.app") }
                } label: {
                    if busy { ProgressView() } else { Image(systemName: "ellipsis") }
                }
                .disabled(busy)
                .accessibilityLabel("More")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls) where !urls.isEmpty: add(urls)
            case .failure(let failure): error = failure.localizedDescription
            default: break
            }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName).autocorrectionDisabled().textInputAutocapitalization(.never)
            Button("Rename") { if let item = renaming { rename(item) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New Folder", isPresented: $naming) {
            TextField("Name", text: $newName).autocorrectionDisabled().textInputAutocapitalization(.never)
            Button("Create") { createFolder() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(deleting.map { "Delete \"\($0.name)\"?" } ?? "", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let item = deleting { delete(item) } }
        } message: {
            Text("It moves to Atmos Backups in Files, so you can put it back.")
        }
        .alert("Game Files", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
        .task { await reload() }
        .refreshable { await reload() }
    }

    @ViewBuilder private func link(_ item: GameFileItem) -> some View {
        if item.isDirectory {
            NavigationLink { GameFolderBrowser(place: place, relative: path(item)) } label: { row(item) }
        } else if GameFiles.isText(item.url) {
            NavigationLink { GameTextFileEditor(place: place, relative: path(item)) } label: { row(item) }
        } else {
            row(item)
        }
    }

    private func row(_ item: GameFileItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.isDirectory ? "folder.fill" : GameFiles.isText(item.url) ? "doc.text" : "doc")
                .font(.body).foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                if !item.isDirectory {
                    Text(GameFiles.size(item.size)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func reload() async {
        let folder = self.folder
        let result = await Task.detached(priority: .userInitiated) { () -> Result<[GameFileItem], Error> in
            Result { try GameFiles.list(folder) }
        }.value
        switch result {
        case .success(let list): items = list
        case .failure(let failure): items = []; error = failure.localizedDescription
        }
        loaded = true
    }

    private func add(_ urls: [URL]) {
        busy = true
        let place = self.place, relative = self.relative
        let name = urls.count == 1 ? urls[0].lastPathComponent : "\(urls[0].lastPathComponent) and \(urls.count - 1) more"
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<ModRecord, Error> in
                Result { try ModInstaller.install(urls, into: relative, place: place, name: name) }
            }.value
            busy = false
            if case .failure(let failure) = result { error = failure.localizedDescription }
            await reload()
        }
    }

    private func rename(_ item: GameFileItem) {
        defer { renaming = nil }
        guard let name = GameFiles.validName(newName) else { error = "That name can't be used."; return }
        guard name != item.name else { return }
        do {
            try FileManager.default.moveItem(at: item.url, to: folder.appendingPathComponent(name))
            Task { await reload() }
        } catch { self.error = error.localizedDescription }
    }

    private func createFolder() {
        guard let name = GameFiles.validName(newName) else { error = "That name can't be used."; return }
        do {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: false)
            Task { await reload() }
        } catch { self.error = error.localizedDescription }
    }

    private func delete(_ item: GameFileItem) {
        defer { deleting = nil }
        do {
            try GameFiles.moveToBackups(item.url, place: place, relative: path(item))
            items.removeAll { $0.id == item.id }
        } catch { self.error = error.localizedDescription }
    }
}

/// A text file, edited in place.
struct GameTextFileEditor: View {
    let place: GameFilesPlace
    let relative: String

    @State private var file: GameTextFile?
    @State private var text = ""
    @State private var saved = ""
    @State private var tooLarge = false
    @State private var error: String?
    @State private var hasOriginal = false
    @State private var confirmRestore = false
    @State private var savedFlash = false
    @Environment(\.dismiss) private var dismiss

    private var url: URL { place.root.appendingPathComponent(relative) }
    private var changed: Bool { text != saved }

    var body: some View {
        Group {
            if tooLarge {
                ContentUnavailableView("Too Large to Edit", systemImage: "doc.text",
                                       description: Text("Files over \(GameFiles.size(Int64(GameFiles.editLimit))) open in Files instead."))
            } else if file == nil {
                ProgressView()
            } else {
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .scrollDismissesKeyboard(.interactively)
                    .padding(.horizontal, 8)
            }
        }
        .navigationTitle(url.lastPathComponent).navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(changed)
        .toolbar {
            if changed {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Revert") { text = saved }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(savedFlash ? "Saved" : "Save") { save() }.disabled(!changed || file == nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                    if hasOriginal {
                        Button(role: .destructive) { confirmRestore = true } label: {
                            Label("Restore Original", systemImage: "arrow.uturn.backward")
                        }
                    }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("More")
            }
            if let file {
                ToolbarItem(placement: .status) {
                    Text("\(file.encodingName) · \(file.crlf ? "CRLF" : "LF")").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .confirmationDialog("Restore the original file?", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Restore Original", role: .destructive) { restore() }
        } message: { Text("Your changes to this file are replaced by the copy kept on the first save.") }
        .alert("Couldn't Save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
        .task { load() }
    }

    private func load() {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= GameFiles.editLimit else { tooLarge = true; return }
        do {
            let loaded = GameTextFile(data: try Data(contentsOf: url))
            file = loaded; text = loaded.text; saved = loaded.text
            hasOriginal = FileManager.default.fileExists(atPath: GameFiles.originalCopy(place, relative).path)
        } catch { self.error = error.localizedDescription }
    }

    private func save() {
        guard let file else { return }
        guard let data = file.data(text) else {
            error = "This file is \(file.encodingName), which can't hold some of the characters you typed."; return
        }
        let fm = FileManager.default
        do {
            let original = GameFiles.originalCopy(place, relative)
            if !fm.fileExists(atPath: original.path) {
                try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: url, to: original)
                hasOriginal = true
            }
            try data.write(to: url, options: .atomic)
            saved = text
            LogStore.shared.log("[game-files] saved \(relative) (\(data.count) bytes)")
            withAnimation { savedFlash = true }
            Task { try? await Task.sleep(nanoseconds: 1_200_000_000); withAnimation { savedFlash = false } }
        } catch { self.error = error.localizedDescription }
    }

    private func restore() {
        let fm = FileManager.default
        let original = GameFiles.originalCopy(place, relative)
        do {
            let data = try Data(contentsOf: original)
            try data.write(to: url, options: .atomic)
            try? fm.removeItem(at: original)
            hasOriginal = false
            let loaded = GameTextFile(data: data)
            file = loaded; text = loaded.text; saved = loaded.text
        } catch { self.error = error.localizedDescription }
    }
}

/// Game files › Mods.
struct GameModsPage: View {
    let place: GameFilesPlace
    @State private var records: [ModRecord] = []
    @State private var importing = false
    @State private var busy = false
    @State private var error: String?
    @State private var removing: ModRecord?

    var body: some View {
        List {
            Section {
                ForEach(Array(records.reversed())) { record in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.name).lineLimit(2)
                        Text(summary(record)).font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions { Button("Remove", role: .destructive) { removing = record } }
                    .contextMenu { Button(role: .destructive) { removing = record } label: { Label("Remove", systemImage: "trash") } }
                }
                Button { importing = true } label: {
                    HStack {
                        Label("Install Mod…", systemImage: "plus")
                        if busy { Spacer(); ProgressView() }
                    }
                }
                .disabled(busy)
            } footer: {
                Text("Choose a mod's files or folders in Files. They're merged into the game's folder, matching names regardless of case. Files a mod replaces are kept, and removing the mod puts them back. Remove mods newest first if they touch the same files. Unzip archives in Files first.")
            }
        }
        .navigationTitle("Mods").navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls) where !urls.isEmpty: install(urls)
            case .failure(let failure): error = failure.localizedDescription
            default: break
            }
        }
        .confirmationDialog(removing.map { "Remove \"\($0.name)\"?" } ?? "", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove Mod", role: .destructive) { if let record = removing { remove(record) } }
        } message: { Text("Its files are taken out of the game's folder and the files it replaced are put back.") }
        .alert("Mods", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
        .onAppear { records = ModInstaller.records(place) }
    }

    private func summary(_ record: ModRecord) -> String {
        var parts = ["\(record.added.count) added"]
        if !record.replaced.isEmpty { parts.append("\(record.replaced.count) replaced") }
        parts.append(record.installed.formatted(date: .abbreviated, time: .omitted))
        return parts.joined(separator: " · ")
    }

    private func install(_ urls: [URL]) {
        busy = true
        let place = self.place
        let name = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "\(urls[0].lastPathComponent) and \(urls.count - 1) more"
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<ModRecord, Error> in
                Result { try ModInstaller.install(urls, into: "", place: place, name: name) }
            }.value
            busy = false
            if case .failure(let failure) = result { error = failure.localizedDescription }
            records = ModInstaller.records(place)
        }
    }

    private func remove(_ record: ModRecord) {
        defer { removing = nil }
        do {
            try ModInstaller.uninstall(record, place: place)
            records = ModInstaller.records(place)
        } catch { self.error = error.localizedDescription }
    }
}
