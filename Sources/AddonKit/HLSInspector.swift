import Foundation

/// Reads an HLS master playlist: the authoritative spec sheet for .m3u8 streams.
/// AVFoundation doesn't expose HLS tracks until playback, but the playlist declares
/// bandwidth, resolution, frame rate, HDR range, codecs and audio channels up front.
public enum HLSInspector {
    /// Playlists carry signed URLs: ephemeral, so nothing lands in the disk cache.
    private static let session = URLSession(configuration: .ephemeral)

    public struct Variant: Sendable, Equatable {
        public var peakKbps: Int
        public var averageKbps: Int?
        public var width: Int?
        public var height: Int?
        public var fps: Double?
        public var videoRange: String?     // SDR, PQ (HDR10/DV), HLG
        public var codecs: [String]
        public var audioGroup: String?
    }

    public struct AudioRendition: Sendable, Equatable {
        public var name: String?
        public var language: String?
        public var channels: Int?
        public var atmos: Bool             // CHANNELS="16/JOC" = Dolby Atmos in DD+
    }

    /// Fetch and parse; nil if it isn't a master playlist (e.g. a single media playlist).
    public static func inspect(url: URL, headers: [String: String], timeout: TimeInterval = 10) async -> ProbeResult? {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        guard let (data, resp) = try? await Self.session.data(for: req),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return result(fromMaster: text)
    }

    /// Spec of the best variant AVPlayer can pick (highest bandwidth), as a ProbeResult.
    public static func result(fromMaster text: String) -> ProbeResult? {
        let (variants, audio) = parse(text)
        guard let best = variants.max(by: { $0.peakKbps < $1.peakKbps }) else { return nil }
        var r = ProbeResult()
        r.width = best.width
        r.height = best.height
        r.fps = best.fps
        r.videoKbps = best.averageKbps ?? best.peakKbps
        r.hdr = best.videoRange == "PQ" || best.videoRange == "HLG"
        r.videoRange = best.videoRange
        for c in best.codecs {
            let p = c.lowercased()
            if p.hasPrefix("dvh1") || p.hasPrefix("dvhe") { r.videoCodec = "HEVC"; r.dolbyVision = true }
            else if p.hasPrefix("hvc1") || p.hasPrefix("hev1") {
                r.videoCodec = "HEVC"
                r.tenBit = p.hasPrefix("hvc1.2") || p.hasPrefix("hev1.2")   // HEVC Main 10 profile
            }
            else if p.hasPrefix("avc1") || p.hasPrefix("avc3") { r.videoCodec = "H.264" }
            else if p.hasPrefix("av01") { r.videoCodec = "AV1" }
            else if p.hasPrefix("mp4a") { r.audioCodec = r.audioCodec ?? "AAC" }
            else if p.hasPrefix("ec-3") { r.audioCodec = "DD+" }
            else if p.hasPrefix("ac-3") { r.audioCodec = "DD" }
            else if p.hasPrefix("alac") { r.audioCodec = "ALAC" }
            else if p.hasPrefix("flac") || p.hasPrefix("fla") { r.audioCodec = "FLAC" }
        }
        let renditions = audio.filter { $0.0 == best.audioGroup || best.audioGroup == nil }.map(\.1)
        if let a = renditions.max(by: { ($0.atmos ? 100 : 0) + ($0.channels ?? 0) < ($1.atmos ? 100 : 0) + ($1.channels ?? 0) }) {
            r.channels = a.channels
            r.atmos = a.atmos
            r.audioLabel = a.name
        }
        if r.channels == nil, r.audioCodec != nil { r.channels = 2 }   // muxed audio with no declaration: stereo
        r.playable = true
        r.measuredFrom = "HLS playlist"
        return r
    }

    static func parse(_ text: String) -> ([Variant], [(String?, AudioRendition)]) {
        var variants: [Variant] = []
        var audio: [(String?, AudioRendition)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let a = attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
                guard let bw = a["BANDWIDTH"].flatMap(Int.init) else { continue }
                let res = a["RESOLUTION"]?.split(separator: "x").compactMap { Int($0) }
                variants.append(Variant(
                    peakKbps: bw / 1000,
                    averageKbps: a["AVERAGE-BANDWIDTH"].flatMap(Int.init).map { $0 / 1000 },
                    width: res?.first, height: res?.last,
                    fps: a["FRAME-RATE"].flatMap(Double.init),
                    videoRange: a["VIDEO-RANGE"],
                    codecs: (a["CODECS"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                    audioGroup: a["AUDIO"]))
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                let a = attributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
                guard a["TYPE"] == "AUDIO" else { continue }
                let ch = a["CHANNELS"] ?? ""
                audio.append((a["GROUP-ID"], AudioRendition(
                    name: a["NAME"], language: a["LANGUAGE"],
                    channels: Int(ch.split(separator: "/").first ?? ""),
                    atmos: ch.uppercased().contains("JOC"))))
            }
        }
        return (variants, audio)
    }

    /// KEY=VALUE,KEY="quoted, with commas" → dictionary.
    static func attributes(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        var key = "", value = "", inKey = true, quoted = false
        func flush() {
            if !key.isEmpty { out[key.trimmingCharacters(in: .whitespaces)] = value }
            key = ""; value = ""; inKey = true
        }
        for ch in s {
            if inKey {
                if ch == "=" { inKey = false } else if ch != "," { key.append(ch) }
            } else if ch == "\"" {
                quoted.toggle()
            } else if ch == "," && !quoted {
                flush()
            } else {
                value.append(ch)
            }
        }
        flush()
        return out
    }
}
