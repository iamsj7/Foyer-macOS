import Foundation

// MARK: - Subtitle tracks (Stremio "subtitles" resource)

/// One external subtitle file offered by an add-on.
/// `url` can carry a private token for some add-ons: keep it in memory, never log it (host only).
public struct SubtitleTrack: Codable, Hashable, Identifiable, Sendable {
    /// Unique across add-ons: "<addon id>|<add-on's own subtitle id or url>".
    public let id: String
    public let url: String
    /// Language exactly as the add-on sent it ("eng", "pob", "pt-BR", …).
    public let rawLanguage: String
    /// Normalized BCP 47-ish code for grouping and preferences ("en", "pt-BR", "zh-Hant", …).
    public let languageCode: String
    /// Release / file name when the add-on gives one, for telling tracks apart.
    public let label: String?
    /// Character encoding the add-on reports (e.g. "UTF-8", "CP1250"), used as a decoding hint.
    public let encoding: String?
    public let addonId: String
    public let addonName: String

    public init(id: String, url: String, rawLanguage: String, label: String?, encoding: String?,
                addonId: String, addonName: String) {
        self.id = id; self.url = url; self.rawLanguage = rawLanguage
        self.languageCode = SubtitleLanguage.normalize(rawLanguage)
        self.label = label; self.encoding = encoding
        self.addonId = addonId; self.addonName = addonName
    }

    /// Localized language name ("English", "Portuguese (Brazil)").
    public var languageName: String { SubtitleLanguage.displayName(languageCode) }

    /// Host only, safe to show or log.
    public var host: String { URL(string: url)?.host ?? "" }
}

/// Wire format of one entry in {"subtitles":[…]}; decoded leniently.
struct WireSubtitle: Decodable {
    let id: String?
    let url: String?
    let lang: String?
    let label: String?
    let encoding: String?

    enum CodingKeys: String, CodingKey {
        case id, url, lang, title, label, name, subtitleFileName, movieReleaseName, SubEncoding, encoding
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(String.self, .id) ?? c.lenientInt(.id).map(String.init)
        url = c.lenient(String.self, .url)
        lang = c.lenient(String.self, .lang)
        let names = [c.lenient(String.self, .movieReleaseName), c.lenient(String.self, .subtitleFileName),
                     c.lenient(String.self, .label), c.lenient(String.self, .title), c.lenient(String.self, .name)]
        label = names.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        encoding = c.lenient(String.self, .SubEncoding) ?? c.lenient(String.self, .encoding)
    }
}

/// Subtitles from one add-on (or the error it gave).
public struct SubtitleGroup: Identifiable, Sendable {
    public let addon: InstalledAddon
    public let subtitles: [SubtitleTrack]
    public let error: String?
    public var id: String { addon.id }

    public init(addon: InstalledAddon, subtitles: [SubtitleTrack], error: String?) {
        self.addon = addon; self.subtitles = subtitles; self.error = error
    }
}

// MARK: - Languages

public enum SubtitleLanguage {
    /// ISO 639-2/B codes (and OpenSubtitles' own) that Foundation doesn't map to a 2-letter code.
    private static let special: [String: String] = [
        "pob": "pt-BR", "pb": "pt-BR", "ptbr": "pt-BR", "pt-br": "pt-BR",
        "spl": "es-419", "spn": "es-419", "ea": "es-419", "es-la": "es-419",
        "zht": "zh-Hant", "zh-tw": "zh-Hant", "zh-hant": "zh-Hant", "zhs": "zh-Hans", "zh-cn": "zh-Hans",
        "zh-hans": "zh-Hans", "ze": "zh", "chi": "zh",
        "cze": "cs", "per": "fa", "gre": "el", "rum": "ro", "dut": "nl", "alb": "sq", "scc": "sr",
        "fre": "fr", "ger": "de", "may": "ms", "slo": "sk", "arm": "hy", "baq": "eu", "bur": "my",
        "geo": "ka", "ice": "is", "mac": "mk", "mao": "mi", "tib": "bo", "wel": "cy",
    ]

    /// "eng" → "en", "pob" → "pt-BR", "pt-br" → "pt-BR"; unknown values come back lowercased.
    public static func normalize(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "_", with: "-")
        if s.isEmpty { return "und" }
        if let m = special[s] { return m }
        let parts = s.split(separator: "-", maxSplits: 1).map(String.init)
        let base = parts[0]
        let code = base.count == 2 ? base : (special[base] ?? Locale.LanguageCode(base).identifier(.alpha2) ?? base)
        guard parts.count == 2 else { return code }
        let region = parts[1]
        return region.count == 2 ? "\(code)-\(region.uppercased())" : "\(code)-\(region.capitalized)"
    }

    public static func displayName(_ code: String, locale: Locale = .current) -> String {
        if code == "und" { return "Unknown" }
        if let n = locale.localizedString(forIdentifier: code) { return n.prefix(1).uppercased() + n.dropFirst() }
        return code
    }

    /// The base language ("pt-BR" → "pt"), for loose preference matching.
    public static func base(_ code: String) -> String {
        String(code.split(separator: "-").first ?? Substring(code))
    }
}

// MARK: - Cues

public struct SubtitleCue: Hashable, Sendable {
    /// Seconds from the start of the video.
    public let start: Double
    public let end: Double
    /// Plain text, tags stripped; lines separated by "\n".
    public let text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start; self.end = end; self.text = text
    }
}

/// Sorted cues with fast lookup by playback time.
public struct SubtitleTimeline: Sendable {
    public let cues: [SubtitleCue]
    private let longest: Double

    public init(cues: [SubtitleCue]) {
        self.cues = cues.sorted { $0.start < $1.start }
        longest = cues.map { $0.end - $0.start }.max() ?? 0
    }

    /// Cues showing at `time` (usually one; overlapping cues all appear, oldest first).
    public func cues(at time: Double) -> [SubtitleCue] {
        // Last cue that starts at or before `time`.
        var lo = 0, hi = cues.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if cues[mid].start <= time { lo = mid + 1 } else { hi = mid }
        }
        var result: [SubtitleCue] = []
        var i = lo - 1
        while i >= 0, cues[i].start >= time - longest {
            if cues[i].end > time { result.append(cues[i]) }
            i -= 1
        }
        return result.reversed()
    }

    /// Text to show at `time`, or nil when nothing is on screen.
    public func text(at time: Double) -> String? {
        let active = cues(at: time)
        return active.isEmpty ? nil : active.map(\.text).joined(separator: "\n")
    }
}

// MARK: - SRT / WebVTT parsing

public enum SubtitleParser {
    /// Turns downloaded bytes into text: BOMs, UTF-8/UTF-16, then the add-on's hint, then Windows-1252.
    public static func decode(_ data: Data, encodingHint: String? = nil) -> String {
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: data.dropFirst(3), as: UTF8.self) }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]),
           let s = String(data: data, encoding: .utf16) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let hint = encodingHint?.trimmingCharacters(in: .whitespaces), !hint.isEmpty {
            let cf = CFStringConvertIANACharSetNameToEncoding(hint as CFString)
            if cf != kCFStringEncodingInvalidId {
                let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let s = String(data: data, encoding: enc) { return s }
            }
        }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    /// Parses SubRip (.srt) or WebVTT (.vtt). Tolerant of CRLF, BOMs, missing indexes,
    /// "," or "." millisecond separators, mm:ss.mmm VTT times, and cue settings after the end time.
    public static func parse(_ text: String) -> [SubtitleCue] {
        var s = text
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        let lines = s.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var cues: [SubtitleCue] = []
        var timing: (Double, Double)?
        var body: [String] = []
        var skippingBlock = false          // WebVTT NOTE / STYLE / REGION blocks

        func flush() {
            if let (start, end) = timing {
                let cleaned = body.map(clean).filter { !$0.isEmpty }.joined(separator: "\n")
                if !cleaned.isEmpty, end > start { cues.append(SubtitleCue(start: start, end: end, text: cleaned)) }
            }
            timing = nil; body = []
        }

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush(); skippingBlock = false
                continue
            }
            if skippingBlock { continue }
            if line.contains("-->"), let t = parseTiming(line) {
                // A cue that wasn't followed by a blank line: its trailing index number belongs to this cue.
                if timing != nil, let last = body.last, last.allSatisfy(\.isNumber) { body.removeLast() }
                flush()
                timing = t
                continue
            }
            if timing != nil {
                body.append(line)
            } else if line.hasPrefix("NOTE") || line == "STYLE" || line == "REGION" {
                skippingBlock = true
            }
            // Otherwise: "WEBVTT" header, header metadata, an SRT index or a VTT cue id. Ignored.
        }
        flush()
        return cues
    }

    /// "00:01:02,345 --> 00:01:04,000 align:start" → (62.345, 64.0)
    static func parseTiming(_ line: String) -> (Double, Double)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        let lhs = parts[0].trimmingCharacters(in: .whitespaces)
        let rhs = parts[1].trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        guard let a = parseTime(lhs), let b = parseTime(rhs) else { return nil }
        return (a, b)
    }

    /// "01:02:03,456", "01:02:03.456", "02:03.456", "1:02:03" → seconds.
    static func parseTime(_ s: String) -> Double? {
        let normalized = s.replacingOccurrences(of: ",", with: ".")
        let fields = normalized.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(fields.count) else { return nil }
        var total = 0.0
        for (i, f) in fields.enumerated() {
            let isLast = i == fields.count - 1
            if isLast {
                // seconds[.fraction]; a fraction of "5" means 500 ms, like players treat it.
                let sf = f.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
                guard let sec = Int(sf[0]) else { return nil }
                var frac = 0.0
                if sf.count == 2 {
                    let digits = sf[1].prefix(3)
                    guard !digits.isEmpty, let v = Int(digits) else { return nil }
                    frac = Double(v) / pow(10, Double(digits.count))
                }
                total = total * 60 + Double(sec) + frac
            } else {
                guard let v = Int(f.trimmingCharacters(in: .whitespaces)) else { return nil }
                total = total * 60 + Double(v)
            }
        }
        return total
    }

    private static let entities: [(String, String)] = [
        ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
        ("&lrm;", ""), ("&rlm;", ""), ("&amp;", "&"),
    ]

    /// Strips HTML-ish tags (<i>, <font …>, <c.yellow>, <v Name>, <00:00:01.000>) and ASS overrides ({\an8}).
    static func clean(_ line: String) -> String {
        let noASS = line.replacingOccurrences(of: #"\{\\[^}]*\}"#, with: "", options: .regularExpression)
        var out = ""
        var inTag = false
        for ch in noASS {
            switch ch {
            case "<": inTag = true
            case ">" where inTag: inTag = false
            default: if !inTag { out.append(ch) }
            }
        }
        out = out.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
        for (k, v) in entities { out = out.replacingOccurrences(of: k, with: v) }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
