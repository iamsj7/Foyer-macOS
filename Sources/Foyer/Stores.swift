import Foundation
import Observation
import AddonKit

/// ~/Library/Application Support/Foyer/<name>.json
enum Disk {
    static let dir: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("Foyer", isDirectory: true)
        // The app was called NativeStream before: carry its data over once.
        let old = base.appendingPathComponent("NativeStream", isDirectory: true)
        if !fm.fileExists(atPath: d.path), fm.fileExists(atPath: old.path) {
            try? fm.moveItem(at: old, to: d)
        }
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// Preferences written under the old name (`swift run` uses the executable name as the domain;
    /// the old app bundle used io.github.nativestream). Copied once, keys we own only.
    static func migrateOldPreferences() {
        let defaults = UserDefaults.standard
        let flag = "migration.fromNativeStream"
        guard !defaults.bool(forKey: flag) else { return }
        let owned = ["playback.", "subtitles.", "search.", "streamsNativeOnly"]
        for domain in ["NativeStream", "io.github.nativestream"] {
            for (key, value) in defaults.persistentDomain(forName: domain) ?? [:]
            where owned.contains(where: key.hasPrefix) && defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: flag)
    }
    /// Encodes and writes off the main thread, in order; the latest snapshot wins.
    private static let writer = DispatchQueue(label: "disk.writer", qos: .utility)
    static func saveInBackground<T: Encodable & Sendable>(_ value: T, _ name: String) {
        writer.async { save(value, name) }
    }
    static func load<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name + ".json")) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    static func save<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: dir.appendingPathComponent(name + ".json"), options: .atomic)
    }
}

// MARK: - Add-ons

@MainActor @Observable
final class AddonStore {
    private(set) var addons: [InstalledAddon] = []
    var lastError: String?
    let client = AddonClient()

    init() {
        addons = Disk.load("addons", as: [InstalledAddon].self) ?? []
        if addons.isEmpty {
            // First launch: legal, no-account add-ons so Home, Search and the player work right away.
            // Cinemeta: catalogs and details. TMDB: Trending Now, genres, cast photos.
            // OpenSubtitles v3: subtitles. Installed in this order (it sets Home row order).
            Task {
                for url in Self.firstLaunchAddons { try? await install(url) }
            }
        } else {
            Task { await refreshManifests() }
        }
    }

    static let firstLaunchAddons = [
        AddonClient.cinemeta,
        "https://tmdb.elfhosted.com/manifest.json",
        "https://opensubtitles-v3.strem.io/manifest.json",
    ]

    /// Re-reads every installed manifest in the background, so new catalogs and genre lists show up
    /// without reinstalling. Order is kept; an add-on that fails to answer keeps its stored copy.
    func refreshManifests() async {
        let client = client
        let installed = addons
        var fresh: [String: InstalledAddon] = [:]
        await withTaskGroup(of: InstalledAddon?.self) { group in
            for a in installed {
                group.addTask { try? await client.refresh(a) }
            }
            for await r in group { if let r { fresh[r.manifestURL] = r } }
        }
        var changed = false
        // Match on the manifest URL (not the id) and against the current list, so an install or
        // removal made meanwhile isn't undone.
        addons = addons.map { a in
            guard let f = fresh[a.manifestURL], f.id == a.id, f != a else { return a }
            changed = true
            return f
        }
        if changed { Disk.saveInBackground(addons, "addons") }
    }

    func install(_ raw: String) async throws {
        let addon = try await client.install(raw)
        addons.removeAll { $0.id == addon.id }
        addons.append(addon)
        Disk.save(addons, "addons")
    }

    func remove(_ addon: InstalledAddon) {
        addons.removeAll { $0.id == addon.id }
        Disk.save(addons, "addons")
    }

    func move(from: IndexSet, to: Int) {
        addons.move(fromOffsets: from, toOffset: to)
        Disk.save(addons, "addons")
    }
}

// MARK: - Library + watch progress

/// The exact stream last played for a title, so Resume continues on the same source.
/// Saved locally only (the URL can carry an add-on token), never logged.
struct SavedSource: Codable, Hashable {
    let url: String
    let headers: [String: String]
    let addonId: String
    let addonName: String
    let name: String?
    let label: String
    let videoId: String       // movie: title id; episode: "tt…:season:episode"
}

struct LibraryItem: Codable, Identifiable, Hashable {
    let id: String          // title id, e.g. tt1375666
    var type: String
    var name: String
    var poster: String?
    var saved: Bool
    var position: Double = 0
    var duration: Double = 0
    var lastVideoId: String?
    var lastSource: SavedSource? = nil
    var updatedAt = Date()

    var progress: Double { duration > 0 ? position / duration : 0 }
    var isInProgress: Bool { progress > 0.03 && progress < 0.92 }

    var preview: MetaPreview { MetaPreview(id: id, type: type, name: name, poster: poster) }
}

@MainActor @Observable
final class LibraryStore {
    private(set) var items: [String: LibraryItem] = [:]

    init() { items = Disk.load("library", as: [String: LibraryItem].self) ?? [:] }

    var saved: [LibraryItem] { items.values.filter(\.saved).sorted { $0.updatedAt > $1.updatedAt } }
    var continueWatching: [LibraryItem] {
        items.values.filter(\.isInProgress).sorted { $0.updatedAt > $1.updatedAt }
    }

    func isSaved(_ id: String) -> Bool { items[id]?.saved ?? false }

    func toggleSaved(_ m: MetaPreview) {
        var item = items[m.id] ?? LibraryItem(id: m.id, type: m.type, name: m.name, poster: m.poster, saved: false)
        item.saved.toggle()
        item.updatedAt = Date()
        items[m.id] = item
        persist()
    }

    /// Called when a stream starts, before any progress arrives. A different episode starts fresh.
    func rememberSource(_ source: SavedSource, for m: MetaPreview) {
        var item = items[m.id] ?? LibraryItem(id: m.id, type: m.type, name: m.name, poster: m.poster, saved: false)
        if item.lastVideoId != source.videoId { item.position = 0; item.duration = 0 }
        item.lastVideoId = source.videoId
        item.lastSource = source
        item.updatedAt = Date()
        items[m.id] = item
        persist()
    }

    /// The player moved to a fallback source: Resume should use the one that actually plays.
    func rememberSource(_ source: SavedSource, for req: PlayRequest) {
        rememberSource(source, for: MetaPreview(id: req.titleId, type: req.type, name: req.titleName, poster: req.poster))
    }

    func resumePosition(titleId: String, videoId: String) -> Double {
        guard let i = items[titleId], i.lastVideoId == videoId, i.isInProgress else { return 0 }
        return i.position
    }

    func updateProgress(_ req: PlayRequest, position: Double, duration: Double) {
        guard duration > 0, position.isFinite else { return }
        var item = items[req.titleId] ?? LibraryItem(id: req.titleId, type: req.type, name: req.titleName,
                                                     poster: req.poster, saved: false)
        item.position = position
        item.duration = duration
        item.lastVideoId = req.videoId
        item.updatedAt = Date()
        items[req.titleId] = item
        persist()
    }

    /// Settings ▸ Clear Watch History: keeps saved titles, forgets positions.
    func clearHistory() {
        for (id, var item) in items {
            item.position = 0; item.duration = 0; item.lastVideoId = nil
            if item.saved { items[id] = item } else { items[id] = nil }
        }
        persist()
    }

    /// Settings ▸ Remove All Saved Titles: keeps watch progress for unsaved titles.
    func removeAllSaved() {
        for (id, var item) in items where item.saved {
            item.saved = false
            items[id] = item.position > 0 ? item : nil
        }
        persist()
    }

    private func persist() { Disk.saveInBackground(items, "library") }
}

/// Everything a player window needs. Codable so it can open its own window.
struct PlayRequest: Codable, Hashable {
    let url: String
    let headers: [String: String]
    let titleId: String
    let videoId: String
    let type: String
    let titleName: String
    let subtitle: String
    let poster: String?
    let startAt: Double
    /// The next sources to try, best quality first, if this one fails to load.
    var alternates: [SavedSource] = []
    /// Shown while loading (e.g. "Your last source didn't respond; playing the best one that did.").
    var note: String? = nil

    /// This request at another position (same source and fallbacks).
    func at(_ position: Double) -> PlayRequest {
        var r = PlayRequest(url: url, headers: headers, titleId: titleId, videoId: videoId, type: type,
                            titleName: titleName, subtitle: subtitle, poster: poster, startAt: position)
        r.alternates = alternates
        r.note = note
        return r
    }

    /// The same title and position on another source; the rest of the list stays as fallbacks.
    func switching(to next: SavedSource, at position: Double, note: String?) -> PlayRequest {
        var r = PlayRequest(url: next.url, headers: next.headers, titleId: titleId, videoId: videoId, type: type,
                            titleName: titleName, subtitle: subtitle, poster: poster, startAt: position)
        r.alternates = alternates.filter { $0.url != next.url }
        r.note = note
        return r
    }
}
