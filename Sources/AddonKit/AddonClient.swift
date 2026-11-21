import Foundation

public enum AddonError: LocalizedError {
    case badURL(String)
    case http(Int, String)

    public var errorDescription: String? {
        switch self {
        case .badURL(let s): return "Not a valid add-on URL: \(s)"
        case .http(let code, let host): return "\(host) answered HTTP \(code)"
        }
    }
}

public struct StreamGroup: Identifiable, Sendable {
    public let addon: InstalledAddon
    public let streams: [AddonStream]
    public let error: String?
    public var id: String { addon.id }

    public init(addon: InstalledAddon, streams: [AddonStream], error: String?) {
        self.addon = addon; self.streams = streams; self.error = error
    }
}

/// Talks the Stremio add-on protocol. Stateless and safe to share.
public struct AddonClient: Sendable {
    public static let cinemeta = "https://v3-cinemeta.strem.io/manifest.json"

    private let session: URLSession
    private static let memoryCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 0)

    public init(timeout: TimeInterval = 15) {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = timeout
        cfg.waitsForConnectivity = false
        cfg.httpAdditionalHeaders = ["Accept": "application/json"]
        // Stream and subtitle answers carry add-on tokens: cache them in memory only, never on disk.
        cfg.urlCache = Self.memoryCache
        session = URLSession(configuration: cfg)
    }

    /// Accepts https://…/manifest.json, stremio://…/manifest.json, or a base URL without manifest.json.
    public static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("stremio://") { s = "https://" + s.dropFirst("stremio://".count) }
        guard s.hasPrefix("http://") || s.hasPrefix("https://") else { return nil }
        if !s.hasSuffix("manifest.json") {
            while s.hasSuffix("/") { s.removeLast() }
            s += "/manifest.json"
        }
        return URL(string: s) == nil ? nil : s
    }

    public func install(_ raw: String) async throws -> InstalledAddon {
        guard let s = Self.normalize(raw), let url = URL(string: s) else { throw AddonError.badURL(raw) }
        let manifest: Manifest = try await get(url)
        return InstalledAddon(manifestURL: s, manifest: manifest)
    }

    /// /catalog/{type}/{id}.json, or /catalog/{type}/{id}/genre={genre}&skip={n}.json with extras.
    public func catalog(_ addon: InstalledAddon, type: String, id: String, genre: String? = nil,
                        skip: Int = 0) async throws -> [MetaPreview] {
        struct R: Decodable { let metas: [MetaPreview]? }
        let r: R = try await get(try url(addon, "catalog", type, id, extra: Self.catalogExtra(genre: genre, skip: skip),
                                         extraEncoded: true))
        return r.metas ?? []
    }

    /// The extra path segment, already percent-encoded. Genre values can hold spaces, "&", "=" or "/"
    /// ("Sci-Fi & Fantasy", "Action/Adventure"), so each value is encoded on its own.
    static func catalogExtra(genre: String?, skip: Int) -> String {
        var parts: [String] = []
        if let genre, !genre.isEmpty {
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove(charactersIn: "&=/?#+")
            parts.append("genre=" + (genre.addingPercentEncoding(withAllowedCharacters: allowed) ?? genre))
        }
        if skip > 0 { parts.append("skip=\(skip)") }
        return parts.joined(separator: "&")
    }

    /// Re-reads an installed add-on's manifest from its own URL (catalogs, genres and resources change
    /// over time). The URL, and any token it carries, is kept exactly as installed.
    public func refresh(_ addon: InstalledAddon) async throws -> InstalledAddon {
        guard let url = URL(string: addon.manifestURL) else { throw AddonError.badURL(addon.id) }
        let manifest: Manifest = try await get(url)
        return InstalledAddon(manifestURL: addon.manifestURL, manifest: manifest)
    }

    /// Catalog search (Stremio "search" extra): /catalog/{type}/{id}/search={query}.json
    public func search(_ addon: InstalledAddon, type: String, catalogId: String, query: String) async throws -> [MetaPreview] {
        struct R: Decodable { let metas: [MetaPreview]? }
        let q = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
        let s = "\(addon.base)/catalog/\(type)/\(catalogId)/search=\(q).json"
        guard let u = URL(string: s) else { throw AddonError.badURL(s) }
        let r: R = try await get(u)
        return r.metas ?? []
    }

    public func meta(_ addon: InstalledAddon, type: String, id: String) async throws -> Meta? {
        struct R: Decodable { let meta: Meta? }
        let r: R = try await get(try url(addon, "meta", type, id))
        return r.meta
    }

    public func streams(_ addon: InstalledAddon, type: String, id: String) async throws -> [AddonStream] {
        struct R: Decodable { let streams: [AddonStream]? }
        let r: R = try await get(try url(addon, "stream", type, id))
        return r.streams ?? []
    }

    /// First installed add-on that can describe this title.
    public func meta(from addons: [InstalledAddon], type: String, id: String) async -> Meta? {
        for a in addons where a.supports("meta", type: type, id: id) {
            if let m = try? await meta(a, type: type, id: id) { return m }
        }
        return nil
    }

    /// Asks every stream-capable add-on in parallel; results arrive as each one answers.
    public func streams(from addons: [InstalledAddon], type: String, id: String,
                        onGroup: @escaping @Sendable (StreamGroup) async -> Void) async {
        await withTaskGroup(of: StreamGroup.self) { group in
            for a in addons where a.supports("stream", type: type, id: id) {
                group.addTask {
                    do {
                        let list = try await self.streams(a, type: type, id: id)
                        return StreamGroup(addon: a, streams: list, error: nil)
                    } catch {
                        return StreamGroup(addon: a, streams: [], error: error.localizedDescription)
                    }
                }
            }
            for await g in group { await onGroup(g) }
        }
    }

    // MARK: - Subtitles

    /// /subtitles/{type}/{id}.json, or /subtitles/{type}/{id}/videoHash=…&videoSize=….json when known.
    public func subtitles(_ addon: InstalledAddon, type: String, id: String,
                          videoHash: String? = nil, videoSize: Int64? = nil) async throws -> [SubtitleTrack] {
        struct R: Decodable { let subtitles: [WireSubtitle]? }
        var extras: [String] = []
        if let videoHash, !videoHash.isEmpty { extras.append("videoHash=\(videoHash)") }
        if let videoSize, videoSize > 0 { extras.append("videoSize=\(videoSize)") }
        let r: R = try await get(try url(addon, "subtitles", type, id, extra: extras.joined(separator: "&")))
        var seen = Set<String>()
        return (r.subtitles ?? []).compactMap { w -> SubtitleTrack? in
            guard let u = w.url, u.hasPrefix("http://") || u.hasPrefix("https://") else { return nil }
            let key = "\(addon.id)|\(w.id ?? u)"
            guard seen.insert(key).inserted else { return nil }
            return SubtitleTrack(id: key, url: u, rawLanguage: w.lang ?? "", label: w.label, encoding: w.encoding,
                                 addonId: addon.id, addonName: addon.manifest.name)
        }
    }

    /// Asks every subtitles-capable add-on in parallel; results arrive as each one answers.
    public func subtitles(from addons: [InstalledAddon], type: String, id: String,
                          onGroup: @escaping @Sendable (SubtitleGroup) async -> Void) async {
        await withTaskGroup(of: SubtitleGroup.self) { group in
            for a in addons where a.supports("subtitles", type: type, id: id) {
                group.addTask {
                    do {
                        return SubtitleGroup(addon: a, subtitles: try await self.subtitles(a, type: type, id: id), error: nil)
                    } catch {
                        return SubtitleGroup(addon: a, subtitles: [], error: error.localizedDescription)
                    }
                }
            }
            for await g in group { await onGroup(g) }
        }
    }

    /// Downloads, decodes and parses one subtitle file (SRT or WebVTT). Runs off the main actor.
    public func cues(for track: SubtitleTrack) async throws -> SubtitleTimeline {
        guard let u = URL(string: track.url) else { throw AddonError.badURL(track.host) }
        var req = URLRequest(url: u)
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AddonError.http(http.statusCode, u.host ?? "subtitles")
        }
        try Task.checkCancellation()
        let text = SubtitleParser.decode(data, encodingHint: track.encoding)
        return SubtitleTimeline(cues: SubtitleParser.parse(text))
    }

    // MARK: - Plumbing

    /// `extraEncoded` is a path segment the caller already percent-encoded (catalog extras).
    private func url(_ addon: InstalledAddon, _ resource: String, _ type: String, _ id: String,
                     extra: String = "", extraEncoded: Bool = false) throws -> URL {
        let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let encodedExtra = extra.isEmpty ? "" : "/" + (extraEncoded ? extra
            : (extra.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? extra))
        let s = "\(addon.base)/\(resource)/\(type)/\(encodedId)\(encodedExtra).json"
        guard let u = URL(string: s) else { throw AddonError.badURL(s) }
        return u
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AddonError.http(http.statusCode, url.host ?? "add-on")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
