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
    /// Blocks until queued writes finish; called at termination so ⌘Q doesn't drop them.
    static func flush() { writer.sync {} }
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

    var qualityText: String { [name ?? "", label].joined(separator: " ") }
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

/// One title's library record, observed on its own so a progress tick for one title doesn't
/// invalidate views showing another.
@MainActor @Observable
final class LibraryEntry {
    let id: String
    fileprivate(set) var item: LibraryItem?
    fileprivate init(id: String, item: LibraryItem?) { self.id = id; self.item = item }
}

@MainActor @Observable
final class LibraryStore {
    @ObservationIgnored private var storage: [String: LibraryItem] = [:]
    @ObservationIgnored private var entries: [String: LibraryEntry] = [:]
    private(set) var continueWatching: [LibraryItem] = []
    private(set) var saved: [LibraryItem] = []
    private(set) var hasHistory = false

    init() {
        storage = Disk.load("library", as: [String: LibraryItem].self) ?? [:]
        refreshDerived()
    }

    /// The persistent, individually observed record for a title. Creating it doesn't invalidate readers.
    func entry(for id: String) -> LibraryEntry {
        if let e = entries[id] { return e }
        let e = LibraryEntry(id: id, item: storage[id])
        entries[id] = e
        return e
    }

    func isSaved(_ id: String) -> Bool { entry(for: id).item?.saved ?? false }

    func toggleSaved(_ m: MetaPreview) {
        var item = storage[m.id] ?? LibraryItem(id: m.id, type: m.type, name: m.name, poster: m.poster, saved: false)
        item.saved.toggle()
        item.updatedAt = Date()
        set(item)
        commit()
    }

    /// Called when a stream starts, before any progress arrives. A different episode starts fresh.
    func rememberSource(_ source: SavedSource, for m: MetaPreview) {
        var item = storage[m.id] ?? LibraryItem(id: m.id, type: m.type, name: m.name, poster: m.poster, saved: false)
        if item.lastVideoId != source.videoId { item.position = 0; item.duration = 0 }
        item.lastVideoId = source.videoId
        item.lastSource = source
        item.updatedAt = Date()
        set(item)
        commit()
    }

    /// The player moved to a fallback source: Resume should use the one that actually plays.
    func rememberSource(_ source: SavedSource, for req: PlayRequest) {
        rememberSource(source, for: MetaPreview(id: req.titleId, type: req.type, name: req.titleName, poster: req.poster))
    }

    func resumePosition(titleId: String, videoId: String) -> Double {
        guard let i = storage[titleId], i.lastVideoId == videoId, i.isInProgress else { return 0 }
        return i.position
    }

    func updateProgress(_ req: PlayRequest, position: Double, duration: Double) {
        guard duration > 0, position.isFinite else { return }
        var item = storage[req.titleId] ?? LibraryItem(id: req.titleId, type: req.type, name: req.titleName,
                                                       poster: req.poster, saved: false)
        item.position = position
        item.duration = duration
        item.lastVideoId = req.videoId
        item.updatedAt = Date()
        set(item)
        commit()
    }

    /// Settings ▸ Clear Watch History: keeps saved titles, forgets positions.
    func clearHistory() {
        for (id, var item) in storage {
            item.position = 0; item.duration = 0; item.lastVideoId = nil
            if item.saved { set(item) } else { remove(id) }
        }
        commit()
    }

    /// Settings ▸ Remove All Saved Titles: keeps watch progress for unsaved titles.
    func removeAllSaved() {
        for (id, var item) in storage where item.saved {
            item.saved = false
            if item.position > 0 { set(item) } else { remove(id) }
        }
        commit()
    }

    private func set(_ item: LibraryItem) {
        storage[item.id] = item
        if let e = entries[item.id], e.item != item { e.item = item }
    }

    private func remove(_ id: String) {
        storage[id] = nil
        if let e = entries[id], e.item != nil { e.item = nil }
    }

    private func commit() {
        refreshDerived()
        Disk.saveInBackground(storage, "library")
    }

    private func refreshDerived() {
        let all = storage.values
        let cw = all.filter(\.isInProgress).sorted { $0.updatedAt > $1.updatedAt }
        let sv = all.filter(\.saved).sorted { $0.updatedAt > $1.updatedAt }
        let history = all.contains { $0.position > 0 }
        if cw != continueWatching { continueWatching = cw }
        if sv != saved { saved = sv }
        if history != hasHistory { hasHistory = history }
    }
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
    /// The source's name and label, parsed for the player's quality chips (4K, Dolby Vision, Atmos…).
    var sourceText: String = ""

    /// Checks the fallbacks in order (up to a few) and returns them without the dead ones that come
    /// before the first live one, so a switch lands on a source that answers. Run while playing.
    static func prewarm(_ alternates: [SavedSource]) async -> [SavedSource] {
        var pool = alternates
        for s in alternates.prefix(4) {
            guard !Task.isCancelled, let url = URL(string: s.url) else { break }
            if await SourceCheck.isAvailable(.init(id: s.url, url: url, headers: s.headers)) { break }
            pool.removeAll { $0.url == s.url }   // isAvailable already remembered it as dead
        }
        return pool
    }

    /// This request at another position (same source and fallbacks).
    func at(_ position: Double) -> PlayRequest {
        var r = PlayRequest(url: url, headers: headers, titleId: titleId, videoId: videoId, type: type,
                            titleName: titleName, subtitle: subtitle, poster: poster, startAt: position)
        r.alternates = alternates
        r.note = note
        r.sourceText = sourceText
        return r
    }

    /// The same title and position on another source; the rest of the list stays as fallbacks.
    func switching(to next: SavedSource, at position: Double, note: String?) -> PlayRequest {
        var r = PlayRequest(url: next.url, headers: next.headers, titleId: titleId, videoId: videoId, type: type,
                            titleName: titleName, subtitle: subtitle, poster: poster, startAt: position)
        r.alternates = alternates.filter { $0.url != next.url }
        r.sourceText = next.qualityText
        r.note = note
        return r
    }
}
