import Foundation

/// What a stream claims to be, read from the text add-ons put in name/title/description/filename
/// (e.g. "4K DV HDR10 | REMUX | TrueHD Atmos 7.1 | 💾 58.2 GB"). Parsed once, when the stream is decoded.
public struct StreamQuality: Hashable, Sendable, Comparable {
    public enum Resolution: Int, Sendable, Comparable {
        case unknown = 0, sd = 480, hd = 720, fullHD = 1080, qhd = 1440, uhd = 2160
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
        public var label: String? {
            switch self {
            case .uhd: "4K"
            case .qhd: "1440p"
            case .fullHD: "1080p"
            case .hd: "720p"
            case .sd: "SD"
            case .unknown: nil
            }
        }
    }

    public enum HDR: String, Sendable, CaseIterable {
        case dolbyVision = "Dolby Vision", hdr10Plus = "HDR10+", hdr10 = "HDR10", hdr = "HDR", hlg = "HLG"
    }

    public enum Source: String, Sendable {
        case remux = "REMUX", bluray = "BluRay", webDL = "WEB-DL", webRip = "WEBRip", hdtv = "HDTV", cam = "CAM"
    }

    public var resolution: Resolution = .unknown
    public var hdr: [HDR] = []               // can be several, e.g. DV with HDR10 fallback
    public var videoCodec: String?           // HEVC, AV1, H.264, VP9
    public var tenBit = false
    public var audio: [String] = []          // best first: Atmos, TrueHD, DTS:X, DTS-HD MA, DTS, DD+, DD, AAC…
    public var channels: String?             // 7.1, 5.1, 2.0
    public var source: Source?
    public var sizeGB: Double?
    public var videoMbps: Double?            // as labelled ("24.5 Mbps"); see estimatedMbps for size-based
    public var audioKbps: Int?               // as labelled ("640 kbps")
    public var fps: Int?                     // as labelled ("60fps")

    public init() {}

    public init(parsing raw: String) {
        let s = raw.lowercased()
        func has(_ pattern: String) -> Bool {
            // Tokens must stand alone: "dv" must not match inside "dvd" or "advanced".
            s.range(of: "(?<![a-z0-9])(?:\(pattern))(?![a-z0-9])", options: .regularExpression) != nil
        }
        /// Audio codecs are often glued to their channel count: "DDP5.1", "AAC2.0", "TrueHD7.1".
        func hasAudio(_ pattern: String) -> Bool {
            s.range(of: "(?<![a-z0-9])(?:\(pattern))(?![a-z])", options: .regularExpression) != nil
        }
        /// Channel layouts may follow a codec directly ("DDP5.1"), but not another number ("15.1").
        func hasChannels(_ pattern: String) -> Bool {
            s.range(of: "(?<![0-9])(?:\(pattern))(?![0-9])", options: .regularExpression) != nil
        }

        if has("2160p|4k|uhd") { resolution = .uhd }
        else if has("1440p|2k") { resolution = .qhd }
        else if has("1080p|1080i|fhd") { resolution = .fullHD }
        else if has("720p") { resolution = .hd }
        else if has("576p|480p|360p|sd") { resolution = .sd }

        if has("dolby ?vision|dv|dovi") { hdr.append(.dolbyVision) }
        if has("hdr10\\+|hdr10plus|hdr10p") { hdr.append(.hdr10Plus) }
        else if has("hdr10") { hdr.append(.hdr10) }
        else if has("hdr") { hdr.append(.hdr) }
        if has("hlg") { hdr.append(.hlg) }

        if has("hevc|x265|h\\.?265") { videoCodec = "HEVC" }
        else if has("av1") { videoCodec = "AV1" }
        else if has("avc|x264|h\\.?264") { videoCodec = "H.264" }
        else if has("vp9") { videoCodec = "VP9" }
        tenBit = has("10 ?bit|hi10p?")

        if hasAudio("atmos") { audio.append("Atmos") }
        if hasAudio("true ?hd") { audio.append("TrueHD") }
        if hasAudio("dts[ :-]?x") { audio.append("DTS:X") }
        else if hasAudio("dts[ -]?hd[ -]?ma|dts[ -]?hd") { audio.append("DTS-HD MA") }
        else if hasAudio("dts") { audio.append("DTS") }
        if hasAudio("ddp|dd\\+|e-?ac-?3|dolby digital plus") { audio.append("DD+") }
        else if hasAudio("dd|ac-?3|dolby digital") { audio.append("DD") }
        if hasAudio("flac") { audio.append("FLAC") }
        if hasAudio("aac") { audio.append("AAC") }
        if hasAudio("opus") { audio.append("Opus") }

        if hasChannels("7\\.1|7 1ch") { channels = "7.1" }
        else if hasChannels("5\\.1|6ch") { channels = "5.1" }
        else if hasChannels("2\\.0") || has("stereo") { channels = "2.0" }

        if has("remux") { source = .remux }
        else if has("blu-?ray|bdrip|brrip|bdremux") { source = .bluray }
        else if has("web-?dl|web") { source = .webDL }
        else if has("webrip|web-?rip") { source = .webRip }
        else if has("hdtv") { source = .hdtv }
        else if has("cam|hdcam|camrip|telesync|hdts|hd-?ts|telecine") { source = .cam }

        func number(_ pattern: String) -> Double? {
            guard let r = s.range(of: pattern, options: .regularExpression) else { return nil }
            return Double(s[r].prefix { "0123456789.,".contains($0) }.replacingOccurrences(of: ",", with: "."))
        }
        videoMbps = number("[0-9]+(?:[.,][0-9]+)? ?(?:mbps|mb/s|mbit/s|mbit)(?![a-z])")
        audioKbps = number("[0-9]{2,4} ?(?:kbps|kb/s|kbit/s)(?![a-z])").map { Int($0) }
        fps = number("[0-9]{2,3}(?:\\.[0-9]+)? ?fps(?![a-z])").map { Int($0.rounded()) }

        if let r = s.range(of: "([0-9]+(?:[.,][0-9]+)?) ?(gb|gib|mb|mib)(?![a-z/])", options: .regularExpression) {
            let m = s[r]
            let num = Double(m.prefix { "0123456789.,".contains($0) }.replacingOccurrences(of: ",", with: ".")) ?? 0
            sizeGB = m.contains("m") ? num / 1024 : num
        }
    }

    /// Picture: resolution dominates, then source, HDR, codec, bit depth, frame rate, bitrate. CAM sinks.
    public var videoScore: Int {
        var p = [Resolution.uhd: 400, .qhd: 300, .fullHD: 200, .hd: 100, .sd: 30, .unknown: 0][resolution] ?? 0
        switch source {
        case .remux: p += 60
        case .bluray: p += 40
        case .webDL: p += 30
        case .webRip: p += 20
        case .hdtv: p += 5
        case .cam: p -= 500
        case nil: break
        }
        if hdr.contains(.dolbyVision) { p += 50 }
        else if hdr.contains(.hdr10Plus) { p += 40 }
        else if !hdr.isEmpty { p += 30 }
        if videoCodec == "HEVC" || videoCodec == "AV1" { p += 5 }
        if tenBit { p += 3 }
        if let f = fps, f >= 50 { p += 4 }
        if let m = videoMbps { p += min(20, Int(m / 3)) }
        return p
    }

    /// Sound: lossless/object formats first, then channel count, then audio bitrate.
    public var audioScore: Int {
        let points = ["Atmos": 30, "TrueHD": 25, "DTS:X": 25, "DTS-HD MA": 22, "FLAC": 15,
                      "DTS": 12, "DD+": 12, "DD": 8, "AAC": 3, "Opus": 3]
        var p = audio.compactMap { points[$0] }.max() ?? 0
        if audio.contains("Atmos") && audio.count > 1 { p += 5 }   // Atmos carried in TrueHD/DD+
        switch channels {
        case "7.1": p += 10
        case "5.1": p += 6
        default: break
        }
        if let k = audioKbps { p += min(10, k / 150) }
        return p
    }

    /// Overall: picture and sound together. Higher is better.
    public var score: Int { videoScore + audioScore }

    /// Average bitrate in Mbps: as labelled, else file size over runtime.
    public func estimatedMbps(runtimeMinutes: Double?) -> (mbps: Double, estimated: Bool)? {
        if let m = videoMbps { return (m, false) }
        guard let gb = sizeGB, let min = runtimeMinutes, min > 0 else { return nil }
        return (gb * 8 * 1024 / (min * 60), true)   // GB → megabits, over seconds
    }

    /// Video part of the tags: "4K · Dolby Vision · REMUX · HEVC 10-bit".
    public var videoTags: [String] {
        var t: [String] = []
        if let r = resolution.label { t.append(r) }
        t += hdr.map(\.rawValue)
        if let s = source { t.append(s.rawValue) }
        if let c = videoCodec { t.append(tenBit ? "\(c) 10-bit" : c) }
        if let f = fps { t.append("\(f) fps") }
        return t
    }

    /// Audio part of the tags: "TrueHD · Atmos · 7.1 · 640 kbps".
    public var audioTags: [String] {
        var t = audio
        if let ch = channels { t.append(ch) }
        if let k = audioKbps { t.append("\(k) kbps") }
        return t
    }

    /// The label's claims corrected by what the stream itself declares (HLS playlist or media tracks).
    /// Measured values win; label-only facts (source, Atmos in a name, size) are kept.
    public func merged(with m: ProbeResult) -> StreamQuality {
        var q = self
        if let h = m.height, let w = m.width {
            q.resolution = w >= 3200 || h >= 2000 ? .uhd : h >= 1400 ? .qhd : h >= 1000 ? .fullHD : h >= 700 ? .hd : .sd
        }
        if let c = m.videoCodec { q.videoCodec = c }
        if m.tenBit { q.tenBit = true }
        if let f = m.fps { q.fps = Int(f.rounded()) }
        if let k = m.videoKbps { q.videoMbps = Double(k) / 1000 }
        if m.dolbyVision, !q.hdr.contains(.dolbyVision) { q.hdr.insert(.dolbyVision, at: 0) }
        if m.videoRange == "SDR" { q.hdr.removeAll() }
        else if m.videoRange == "PQ", q.hdr.isEmpty { q.hdr = [.hdr10] }
        else if m.videoRange == "HLG", q.hdr.isEmpty { q.hdr = [.hlg] }
        if m.atmos {
            q.channels = "5.1"   // HLS "16/JOC" = Atmos objects over a DD+ 5.1 bed
        } else if let ch = m.channels {
            q.channels = ch >= 8 ? "7.1" : ch >= 6 ? "5.1" : ch == 1 ? "1.0" : "2.0"
        }
        if let a = m.audioCodec {
            var list = q.audio.filter { $0 == "Atmos" && m.atmos }
            list.append(a)
            if m.atmos, !list.contains("Atmos") { list.insert("Atmos", at: 0) }
            q.audio = list
        }
        if let k = m.audioKbps { q.audioKbps = k }
        return q
    }

    public var isKnown: Bool { score != 0 || sizeGB != nil }

    /// Short tags, most important first, for list badges and logs.
    public var tags: [String] {
        var t: [String] = []
        if let r = resolution.label { t.append(r) }
        t += hdr.map(\.rawValue)
        if let s = source { t.append(s.rawValue) }
        if let c = videoCodec { t.append(tenBit ? "\(c) 10-bit" : c) }
        t += audio
        if let ch = channels { t.append(ch) }
        return t
    }

    public static func < (a: Self, b: Self) -> Bool {
        a.score != b.score ? a.score < b.score : (a.sizeGB ?? 0) < (b.sizeGB ?? 0)
    }
}
