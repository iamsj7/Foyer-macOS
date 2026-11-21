import Foundation

// MARK: - Lenient decoding helper
// Add-ons are written by many people; one odd field must never break a whole response.
extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
    func lenientInt(_ key: Key) -> Int? {
        if let i = lenient(Int.self, key) { return i }
        if let s = lenient(String.self, key) { return Int(s) }
        if let d = lenient(Double.self, key) { return Int(d) }
        return nil
    }
    /// A string that some add-ons send as a number (ratings, years).
    func lenientString(_ key: Key) -> String? {
        if let s = lenient(String.self, key) { return s.isEmpty ? nil : s }
        if let i = lenient(Int.self, key) { return String(i) }
        if let d = lenient(Double.self, key) { return String(d) }
        return nil
    }
    func lenientDouble(_ key: Key) -> Double? {
        if let d = lenient(Double.self, key) { return d }
        if let s = lenient(String.self, key) { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
    /// A list that may arrive as an array or as one comma-separated string ("A, B, C").
    func lenientStrings(_ key: Key) -> [String]? {
        let raw: [String]
        if let a = lenient([LenientString].self, key) { raw = a.compactMap(\.value) }
        else if let s = lenient(String.self, key) { raw = s.split(separator: ",").map(String.init) }
        else { return nil }
        let cleaned = raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return cleaned.isEmpty ? nil : cleaned
    }
}

/// One array element that may be a string, a number, or junk (junk becomes nil, not an error).
struct LenientString: Decodable {
    let value: String?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let i = try? c.decode(Int.self) { value = String(i) }
        else { value = nil }
    }
}

/// Decodes each element on its own so one malformed entry drops out instead of failing the array.
struct LenientArray<T: Decodable>: Decodable {
    let items: [T]
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var out: [T] = []
        while !c.isAtEnd {
            if let v = try? c.decode(T.self) { out.append(v) }
            else { _ = try? c.decode(Skip.self) }
        }
        items = out
    }
    private struct Skip: Decodable {}
}

/// ISO 8601 dates as add-ons send them, with or without fractional seconds, or a bare "2010-07-16".
public enum AddonDate {
    public static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        if let d = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s) { return d }
        if let d = try? Date.ISO8601FormatStyle().parse(s) { return d }
        if let d = try? Date.ISO8601FormatStyle().year().month().day().parse(s) { return d }
        return nil
    }
}

// MARK: - Manifest

public struct Manifest: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let version: String?
    public let description: String?
    public let logo: String?
    public let types: [String]?
    public let catalogs: [CatalogDef]?
    public let resources: [Resource]?
    public let idPrefixes: [String]?

    enum CodingKeys: String, CodingKey {
        case id, name, version, description, logo, types, catalogs, resources, idPrefixes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.lenient(String.self, .name) ?? id
        version = c.lenient(String.self, .version)
        description = c.lenient(String.self, .description)
        logo = c.lenient(String.self, .logo)
        types = c.lenient([String].self, .types)
        catalogs = c.lenient([CatalogDef].self, .catalogs)
        resources = c.lenient([Resource].self, .resources)
        idPrefixes = c.lenient([String].self, .idPrefixes)
    }
}

public struct CatalogDef: Codable, Hashable, Sendable {
    public let type: String
    public let id: String
    public let name: String?
    public let extra: [CatalogExtra]?
    public let extraRequired: [String]?

    public var supportsSearch: Bool { (extra ?? []).contains { $0.name == "search" } || (extraRequired ?? []).contains("search") }

    /// Catalogs that require an extra (e.g. "search") can't be shown as a plain Home row.
    public var isBrowsable: Bool { requiredExtras.isEmpty }

    /// Names of the extras this catalog can't answer without (both manifest spellings).
    public var requiredExtras: Set<String> {
        Set((extraRequired ?? []) + (extra ?? []).filter { $0.isRequired == true }.map(\.name))
    }

    /// The catalog accepts a `genre=` extra.
    public var supportsGenre: Bool {
        (extra ?? []).contains { $0.name == "genre" } || (extraRequired ?? []).contains("genre")
    }

    /// Genre values the add-on lists for this catalog, in its own order (empty when it lists none).
    public var genreOptions: [String] { (extra ?? []).first { $0.name == "genre" }?.options ?? [] }

    /// Can be shown as a shelf on a genre page: takes a genre and needs nothing else (e.g. Cinemeta's "New").
    public var isBrowsableByGenre: Bool { supportsGenre && requiredExtras.subtracting(["genre"]).isEmpty }
}

public struct CatalogExtra: Codable, Hashable, Sendable {
    public let name: String
    public let isRequired: Bool?
    /// Allowed values (genre names, years…). Some add-ons send numbers; those are kept as strings.
    public let options: [String]?

    enum CodingKeys: String, CodingKey { case name, isRequired, options }

    public init(name: String, isRequired: Bool? = nil, options: [String]? = nil) {
        self.name = name; self.isRequired = isRequired; self.options = options
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        isRequired = c.lenient(Bool.self, .isRequired)
        options = Self.decodeOptions(c)
    }

    private static func decodeOptions(_ c: KeyedDecodingContainer<CodingKeys>) -> [String]? {
        if let s = c.lenient([String].self, .options) { return s.filter { !$0.isEmpty } }
        // Mixed arrays (e.g. years as numbers): keep whatever reads as a string or number.
        guard var arr = try? c.nestedUnkeyedContainer(forKey: .options) else { return nil }
        var out: [String] = []
        while !arr.isAtEnd {
            if let s = try? arr.decode(String.self) { if !s.isEmpty { out.append(s) } }
            else if let i = try? arr.decode(Int.self) { out.append(String(i)) }
            else if let d = try? arr.decode(Double.self) { out.append(String(d)) }
            else { _ = try? arr.decode(Skip.self) }
        }
        return out
    }

    /// Consumes one array element of any shape.
    private struct Skip: Decodable { init(from decoder: Decoder) throws {} }
}

/// A resource is either "stream" or {"name":"stream","types":[...],"idPrefixes":[...]}.
public struct Resource: Codable, Hashable, Sendable {
    public let name: String
    public let types: [String]?
    public let idPrefixes: [String]?

    enum CodingKeys: String, CodingKey { case name, types, idPrefixes }

    public init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            name = s; types = nil; idPrefixes = nil; return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        types = c.lenient([String].self, .types)
        idPrefixes = c.lenient([String].self, .idPrefixes)
    }
}

// MARK: - Installed add-on

public struct InstalledAddon: Codable, Hashable, Identifiable, Sendable {
    public let manifestURL: String
    public let manifest: Manifest
    public var id: String { manifest.id }

    /// Base URL = manifest URL without "/manifest.json". Kept as a raw string so
    /// encoded config segments like %7B...%7D are preserved exactly.
    public var base: String {
        var s = manifestURL
        if s.hasSuffix("/manifest.json") { s.removeLast("/manifest.json".count) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    public func supports(_ resource: String, type: String, id: String) -> Bool {
        guard let r = (manifest.resources ?? []).first(where: { $0.name == resource }) else { return false }
        let types = r.types ?? manifest.types ?? []
        guard types.isEmpty || types.contains(type) else { return false }
        guard let prefixes = r.idPrefixes ?? manifest.idPrefixes, !prefixes.isEmpty else { return true }
        return prefixes.contains { id.hasPrefix($0) }
    }
}

// MARK: - Meta

public struct MetaPreview: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let type: String
    public let name: String
    public let poster: String?
    public let background: String?
    public let description: String?
    public let releaseInfo: String?

    enum CodingKeys: String, CodingKey { case id, type, name, poster, background, description, releaseInfo }

    public init(id: String, type: String, name: String, poster: String?, background: String? = nil,
                description: String? = nil, releaseInfo: String? = nil) {
        self.id = id; self.type = type; self.name = name; self.poster = poster
        self.background = background; self.description = description; self.releaseInfo = releaseInfo
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = c.lenient(String.self, .type) ?? "movie"
        name = c.lenient(String.self, .name) ?? id
        poster = c.lenient(String.self, .poster)
        background = c.lenient(String.self, .background)
        description = c.lenient(String.self, .description)
        releaseInfo = c.lenient(String.self, .releaseInfo) ?? c.lenientInt(.releaseInfo).map(String.init)
    }
}

public struct Meta: Codable, Hashable, Sendable {
    public let id: String
    public let type: String
    public let name: String
    public let poster: String?
    public let background: String?
    public let logo: String?
    public let description: String?
    public let releaseInfo: String?
    public let runtime: String?
    public let genres: [String]?
    public let videos: [Video]?
    /// IMDb score as sent ("8.8"); see `imdbScore` for the number.
    public let imdbRating: String?
    public let year: String?
    /// ISO 8601 first release date; see `releaseDate`.
    public let released: String?
    public let cast: [String]?
    public let director: [String]?
    public let writer: [String]?
    public let country: String?
    public let awards: String?
    /// Age rating ("PG-13", "TV-MA") when an add-on provides one. Cinemeta doesn't.
    public let certification: String?
    /// "Ended", "Continuing" for series.
    public let status: String?
    public let popularity: Double?
    public let trailerStreams: [Trailer]?
    public let links: [MetaLink]?
    /// IMDb id when the add-on uses its own ids (TMDB's "tmdb:…" metas carry "imdb_id").
    public let imdbId: String?
    /// People with photos, when the add-on provides them (TMDB: app_extras.cast).
    public let castMembers: [CastMember]?

    public struct CastMember: Decodable, Hashable, Sendable {
        public let name: String
        public let character: String?
        public let photo: String?
    }
    private struct AppExtras: Decodable { let cast: LenientArray<CastMember>? }

    enum CodingKeys: String, CodingKey {
        case id, type, name, poster, background, logo, description, releaseInfo, runtime, genres, videos
        case imdbRating, year, released, cast, director, writer, country, awards, certification, status
        case popularity, trailerStreams, links
    }
    /// Alternate spellings, read only when decoding.
    private enum AltKeys: String, CodingKey {
        case genre, trailers, ageRating, rated, imdb_id, app_extras
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let alt = try? decoder.container(keyedBy: AltKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = c.lenient(String.self, .type) ?? "movie"
        name = c.lenient(String.self, .name) ?? id
        poster = c.lenient(String.self, .poster)
        background = c.lenient(String.self, .background)
        logo = c.lenient(String.self, .logo)
        description = c.lenient(String.self, .description)
        releaseInfo = c.lenient(String.self, .releaseInfo) ?? c.lenientInt(.releaseInfo).map(String.init)
        runtime = c.lenientString(.runtime)
        genres = c.lenientStrings(.genres) ?? alt?.lenientStrings(.genre)
        videos = c.lenient(LenientArray<Video>.self, .videos)?.items
        imdbRating = c.lenientString(.imdbRating)
        year = c.lenientString(.year)
        released = c.lenientString(.released)
        cast = c.lenientStrings(.cast)
        director = c.lenientStrings(.director)
        writer = c.lenientStrings(.writer)
        country = c.lenientString(.country)
        awards = c.lenientString(.awards)
        certification = c.lenientString(.certification) ?? alt?.lenientString(.ageRating) ?? alt?.lenientString(.rated)
        status = c.lenientString(.status)
        popularity = c.lenientDouble(.popularity)
        let streams = c.lenient(LenientArray<Trailer>.self, .trailerStreams)?.items ?? []
        let legacy = (alt?.lenient(LenientArray<LegacyTrailer>.self, .trailers)?.items ?? [])
            .filter { $0.type == nil || $0.type == "Trailer" }
            .map { Trailer(title: nil, ytId: $0.source) }
        let trailers = streams.isEmpty ? legacy : streams
        trailerStreams = trailers.isEmpty ? nil : trailers
        links = c.lenient(LenientArray<MetaLink>.self, .links)?.items
        let imdb = alt?.lenientString(.imdb_id)
        imdbId = imdb?.hasPrefix("tt") == true ? imdb : (id.hasPrefix("tt") ? String(id.split(separator: ":")[0]) : nil)
        let members = (alt.flatMap { try? $0.decodeIfPresent(AppExtras.self, forKey: .app_extras) })?.cast?.items ?? []
        castMembers = members.isEmpty ? nil : members
    }

    /// The id stream and subtitle add-ons expect. They key on IMDb ids, so a "tmdb:123" title
    /// (or "tmdb:123:1:2" episode) is asked for as "tt…" ("tt…:1:2") when the meta knows it.
    public func streamID(for videoId: String) -> String {
        guard let imdbId, !id.hasPrefix("tt"), videoId.hasPrefix(id) else { return videoId }
        return imdbId + videoId.dropFirst(id.count)
    }

    public var preview: MetaPreview {
        MetaPreview(id: id, type: type, name: name, poster: poster, background: background,
                    description: description, releaseInfo: releaseInfo)
    }

    /// IMDb score out of 10, when it parses.
    public var imdbScore: Double? {
        imdbRating.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 > 0 ? $0 : nil }
    }
    public var releaseDate: Date? { AddonDate.parse(released) }
    /// IMDb title page, for IMDb ids only.
    public var imdbURL: URL? {
        imdbId.flatMap { URL(string: "https://www.imdb.com/title/\($0)/") }
    }
    /// The first trailer, as a YouTube watch page (AVPlayer can't play YouTube).
    public var trailerURL: URL? { trailerStreams?.first?.youTubeURL }
    /// Runtime in minutes, from "148 min", "2h 28min" or "148".
    public var runtimeMinutes: Int? {
        guard let r = runtime?.lowercased() else { return nil }
        let nums = r.split { !$0.isNumber }.compactMap { Int($0) }
        if r.contains("h"), nums.count >= 2 { return nums[0] * 60 + nums[1] }
        if r.contains("h"), let h = nums.first { return h * 60 }
        return nums.first
    }
}

public struct Trailer: Codable, Hashable, Sendable {
    public let title: String?
    public let ytId: String

    public init(title: String?, ytId: String) { self.title = title; self.ytId = ytId }

    public var youTubeURL: URL? {
        var c = URLComponents(string: "https://www.youtube.com/watch")
        c?.queryItems = [URLQueryItem(name: "v", value: ytId)]
        return c?.url
    }
}

/// Cinemeta's older trailer shape: {"source": "<ytId>", "type": "Trailer"}.
struct LegacyTrailer: Decodable {
    let source: String
    let type: String?
}

/// A related link: {"name": "Christopher Nolan", "category": "Directors", "url": "stremio:///search?..."}.
public struct MetaLink: Codable, Hashable, Sendable {
    public let name: String
    public let category: String
    public let url: String
}

public struct Video: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String?
    public let season: Int?
    public let episode: Int?
    public let thumbnail: String?
    public let released: String?
    /// Episode synopsis (Cinemeta sends both `overview` and `description`).
    public let overview: String?

    enum CodingKeys: String, CodingKey {
        case id, title, name, season, episode, number, thumbnail, released, firstAired, overview, description
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = c.lenient(String.self, .title) ?? c.lenient(String.self, .name)
        season = c.lenientInt(.season)
        episode = c.lenientInt(.episode) ?? c.lenientInt(.number)
        thumbnail = c.lenient(String.self, .thumbnail)
        released = c.lenient(String.self, .released) ?? c.lenient(String.self, .firstAired)
        overview = c.lenientString(.overview) ?? c.lenientString(.description)
    }

    public var releaseDate: Date? { AddonDate.parse(released) }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(season, forKey: .season)
        try c.encodeIfPresent(episode, forKey: .episode)
        try c.encodeIfPresent(thumbnail, forKey: .thumbnail)
        try c.encodeIfPresent(released, forKey: .released)
        try c.encodeIfPresent(overview, forKey: .overview)
    }
}

// MARK: - Stream

public struct AddonStream: Codable, Hashable, Identifiable, Sendable {
    public let name: String?
    public let title: String?
    public let description: String?
    public let url: String?
    public let infoHash: String?
    public let ytId: String?
    public let externalUrl: String?
    public let behaviorHints: BehaviorHints?
    /// Parsed from the text fields at decode time (not part of the wire format).
    public let quality: StreamQuality

    enum CodingKeys: String, CodingKey {
        case name, title, description, url, infoHash, ytId, externalUrl, behaviorHints
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.lenient(String.self, .name)
        title = c.lenient(String.self, .title)
        description = c.lenient(String.self, .description)
        url = c.lenient(String.self, .url)
        infoHash = c.lenient(String.self, .infoHash)
        ytId = c.lenient(String.self, .ytId)
        externalUrl = c.lenient(String.self, .externalUrl)
        behaviorHints = c.lenient(BehaviorHints.self, .behaviorHints)
        quality = StreamQuality(parsing: [name, title, description, behaviorHints?.filename]
            .compactMap { $0 }.joined(separator: " "))
    }

    /// Stable identity for lists: the link itself, which is what makes two streams different.
    /// In memory only; never logged (links can carry private tokens).
    public var id: String {
        url ?? externalUrl ?? infoHash ?? ytId ?? "\(name ?? "")|\(title ?? "")|\(description ?? "")"
    }

    /// Text shown under the add-on name (Stremio uses `title`, newer add-ons use `description`).
    public var label: String { description ?? title ?? "" }

    public var requestHeaders: [String: String] { behaviorHints?.proxyHeaders?.request ?? [:] }

    /// Best guess at the container, from the filename hint or URL path.
    public var container: String {
        let candidates = [behaviorHints?.filename, url.flatMap { URL(string: $0)?.path }]
        for c in candidates.compactMap({ $0?.lowercased() }) {
            for ext in ["m3u8", "mp4", "m4v", "mov", "mkv", "avi", "webm", "ts"] where c.hasSuffix("." + ext) {
                return ext
            }
        }
        // Many add-ons hide the file behind a resolver URL but name the container in the label
        // ("4K • MKV • REMUX"). Match whole words only.
        let words = Set("\(name ?? "") \(title ?? "") \(description ?? "")".uppercased()
            .split { !$0.isLetter && !$0.isNumber })
        for (word, ext) in [("MKV", "mkv"), ("MP4", "mp4"), ("M2TS", "m2ts"), ("AVI", "avi"), ("WEBM", "webm"), ("HLS", "m3u8")]
        where words.contains(Substring(word)) {
            return ext
        }
        return "?"
    }

    /// Whether Apple's native AVPlayer is expected to open this container.
    public var likelyNative: Bool? {
        switch container {
        case "m3u8", "mp4", "m4v", "mov": return true
        case "mkv", "avi", "webm", "m2ts": return false
        default: return nil   // unknown: try it
        }
    }
}

public struct BehaviorHints: Codable, Hashable, Sendable {
    public let notWebReady: Bool?
    public let bingeGroup: String?
    public let filename: String?
    public let proxyHeaders: ProxyHeaders?

    enum CodingKeys: String, CodingKey { case notWebReady, bingeGroup, filename, proxyHeaders }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notWebReady = c.lenient(Bool.self, .notWebReady)
        bingeGroup = c.lenient(String.self, .bingeGroup)
        filename = c.lenient(String.self, .filename)
        proxyHeaders = c.lenient(ProxyHeaders.self, .proxyHeaders)
    }
}

public struct ProxyHeaders: Codable, Hashable, Sendable {
    public let request: [String: String]?
}

public extension String {
    /// Add-on labels decorate with emoji ("🍿 Title 🎞️ 4K • MP4"). For display only: drops emoji
    /// (and the joiners/variation selectors that build them), then tidies the spacing left behind.
    /// Plain digits, "#", "*" and symbols like "•" stay, since they're emoji-capable but not emoji.
    var withoutEmoji: String {
        var out = String.UnicodeScalarView()
        for s in unicodeScalars {
            let p = s.properties
            let isEmoji = p.isEmojiPresentation || (p.isEmoji && s.value > 0x2000 && s != "•")
            let isJoiner = s.value == 0x200D || (0xFE00...0xFE0F).contains(s.value) || (0x1F3FB...0x1F3FF).contains(s.value)
                || (0xE0020...0xE007F).contains(s.value)
            if !isEmoji && !isJoiner { out.append(s) }
        }
        return String(out)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: "• •", with: "•")
            .trimmingCharacters(in: CharacterSet(charactersIn: " •|-·"))
    }
}
