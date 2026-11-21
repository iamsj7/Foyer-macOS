import Foundation
import AddonKit
import Libmpv

// End-to-end checks: each one exercises a user-facing feature against live add-ons.
// Usage:  swift run checks "<your stream add-on manifest URL>"
//    or:  STREAM_ADDON_URL="…" swift run checks
// Prints hosts only, never full URLs, because add-on URLs often carry private tokens.

// --only catalog,streams,quality,playback,mpv,subtitles,persistence  → run just those groups
// (add-on install always runs; everything else depends on it). Default: all groups.
let args = Array(CommandLine.arguments.dropFirst())
let only: Set<String>? = args.firstIndex(of: "--only").flatMap { i in
    i + 1 < args.count ? Set(args[i + 1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }) : nil
}
func want(_ group: String) -> Bool { group == "setup" || only == nil || only!.contains(group) }
nonisolated(unsafe) var currentGroup = "setup"   // set between sections on the main task only
func group(_ g: String) { currentGroup = g }

let streamAddonURL = args.enumerated().first { i, a in !a.hasPrefix("--") && (i == 0 || args[i - 1] != "--only") }?.element
    ?? ProcessInfo.processInfo.environment["STREAM_ADDON_URL"]
guard let streamAddonURL else {
    print("Usage: swift run checks \"<stream add-on manifest URL>\" [--only group,group]")
    exit(1)
}

let movieId = "tt1375666"          // Inception
let seriesId = "tt0903747"         // Breaking Bad
let episodeId = "tt0903747:1:1"    // S1E1

let client = AddonClient()
var failures = 0

enum Mark { case pass, warn, fail }
func report(_ mark: Mark, _ name: String, _ detail: String) {
    guard want(currentGroup) else { return }
    let icon: String
    switch mark {
    case .pass: icon = "🟢 PASS"
    case .warn: icon = "🟡 INFO"
    case .fail: icon = "🔴 FAIL"; failures += 1
    }
    print("\(icon)  \(name.padding(toLength: 34, withPad: " ", startingAt: 0)) \(detail)")
}

func check<T>(_ name: String, _ body: () async throws -> (T, String, Bool)) async -> T? {
    guard want(currentGroup) else { return nil }
    do {
        let (value, detail, ok) = try await body()
        report(ok ? .pass : .fail, name, detail)
        return ok ? value : nil
    } catch {
        report(.fail, name, error.localizedDescription)
        return nil
    }
}

print("Foyer checks\n")

// 1–2. Add-on install (Settings ▸ Add-ons: paste a manifest URL)
let cinemeta = await check("Install Cinemeta (catalogs)") {
    let a = try await client.install(AddonClient.cinemeta)
    return (a, "\(a.manifest.name) \(a.manifest.version ?? "")", true)
}
let streamAddon = await check("Install your stream add-on") {
    let a = try await client.install(streamAddonURL)
    let hasStreams = (a.manifest.resources ?? []).contains { $0.name == "stream" }
    return (a, "\(a.manifest.name) \(a.manifest.version ?? "") · resources: \((a.manifest.resources ?? []).map(\.name).joined(separator: ","))", hasStreams)
}

// 3. Home rows (catalog shelves)
group("catalog")
if let cinemeta, want("catalog") {
    for type in ["movie", "series"] {
        _ = await check("Home row: popular \(type == "movie" ? "movies" : "series")") {
            guard let cat = (cinemeta.manifest.catalogs ?? []).first(where: { $0.type == type && $0.isBrowsable }) else {
                return ((), "no browsable catalog", false)
            }
            let items = try await client.catalog(cinemeta, type: type, id: cat.id)
            let withPosters = items.filter { $0.poster != nil }.count
            return ((), "\(items.count) titles, \(withPosters) with posters", items.count > 0)
        }
    }

    // 4–5. Title pages (details, seasons and episodes)
    _ = await check("Movie details") {
        let m = try await client.meta(cinemeta, type: "movie", id: movieId)
        return ((), m.map { "\($0.name) (\($0.releaseInfo ?? "?"))" } ?? "missing", m != nil)
    }
    _ = await check("Series details + episodes") {
        let m = try await client.meta(cinemeta, type: "series", id: seriesId)
        let eps = (m?.videos ?? []).filter { ($0.season ?? 0) > 0 }
        let seasons = Set(eps.compactMap(\.season)).count
        return ((), "\(m?.name ?? "?") · \(seasons) seasons · \(eps.count) episodes", !eps.isEmpty)
    }
}

// 6–7. Streams (the stream table on a title page)
group("streams")
var movieStreams: [AddonStream] = []
if let streamAddon, want("streams") || want("quality") || want("playback") {
    movieStreams = await check("Streams for a movie") {
        let s = try await client.streams(streamAddon, type: "movie", id: movieId).filter { $0.url != nil }
        let native = s.filter { $0.likelyNative == true }.count
        let mkv = s.filter { $0.likelyNative == false }.count
        return (s, "\(s.count) http streams · \(native) native-format · \(mkv) MKV/other", !s.isEmpty)
    } ?? []
    _ = await check("Streams for a series episode") {
        let s = try await client.streams(streamAddon, type: "series", id: episodeId).filter { $0.url != nil }
        return ((), "\(s.count) http streams for S1E1", !s.isEmpty)
    }
}

group("quality")
// 7b. Quality tags (4K / HDR / Atmos badges in the stream table)
_ = await check("Quality tags parse correctly") {
    let samples: [(String, [String])] = [
        ("Example Add-on\n4k DV | HDR10 Inception.2010.2160p.UHD.BluRay.REMUX.HEVC.TrueHD.Atmos.7.1 💾 58.2 GB",
         ["4K", "Dolby Vision", "HDR10", "REMUX", "HEVC", "Atmos", "TrueHD", "7.1"]),
        ("Inception 2010 1080p WEB-DL DDP5.1 H.264", ["1080p", "WEB-DL", "H.264", "DD+", "5.1"]),
        ("Inception.2010.720p.BRRip.x264.AAC.2.0", ["720p", "BluRay", "H.264", "AAC", "2.0"]),
        ("Movie HDCAM 1.4GB advanced dvd", ["CAM"]),
    ]
    var bad: [String] = []
    for (text, want) in samples where StreamQuality(parsing: text).tags != want {
        bad.append("got \(StreamQuality(parsing: text).tags) want \(want)")
    }
    let order = samples.map { StreamQuality(parsing: $0.0).score }
    if order != order.sorted(by: >) { bad.append("ranking out of order: \(order)") }
    return ((), bad.isEmpty ? "\(samples.count) sample labels tagged and ranked" : bad.joined(separator: "; "), bad.isEmpty)
}
_ = await check("HLS playlist specs parse") {
    let sample = """
    #EXTM3U
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="ENGLISH 5.1",LANGUAGE="en",DEFAULT=YES,CHANNELS="2",URI="a.m3u8"
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Atmos",LANGUAGE="en",CHANNELS="16/JOC",URI="b.m3u8"
    #EXT-X-STREAM-INF:BANDWIDTH=8128000,AVERAGE-BANDWIDTH=6628000,RESOLUTION=1920x1080,FRAME-RATE=23.976,VIDEO-RANGE=SDR,CODECS="avc1.640028,mp4a.40.2",AUDIO="audio"
    v1.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=23328000,AVERAGE-BANDWIDTH=16128000,RESOLUTION=3840x2160,FRAME-RATE=23.976,VIDEO-RANGE=PQ,CODECS="hvc1.2.4.L153.B0,ec-3",AUDIO="audio"
    v2.m3u8
    """
    guard let r = HLSInspector.result(fromMaster: sample) else { return ((), "no variants parsed", false) }
    let q = StreamQuality(parsing: "1080p WEB-DL AAC 5.1").merged(with: r)
    let ok = r.width == 3840 && r.videoKbps == 16128 && r.hdr && r.tenBit && r.videoCodec == "HEVC"
        && r.atmos && r.channels == 16 && q.resolution == .uhd && q.hdr == [.hdr10] && q.audio.first == "Atmos"
    return ((), ok ? "4K HDR10 HEVC 10-bit · 16.1 Mbps · Atmos picked from playlist, label corrected" : "got \(q.tags) \(r)", ok)
}
if !movieStreams.isEmpty {
    let best = movieStreams.max { $0.quality < $1.quality }!
    let bestNative = movieStreams.filter { $0.likelyNative != false }.max { $0.quality < $1.quality }
    let tagged = movieStreams.filter { $0.quality.isKnown }.count
    report(.warn, "Best quality offered", "\(best.quality.tags.joined(separator: " · ")) · .\(best.container) · \(tagged)/\(movieStreams.count) streams tagged")
    report(.warn, "Best native-format quality", bestNative.map { "\($0.quality.tags.joined(separator: " · ")) · .\($0.container)" } ?? "none")
}

// 8. Native playback (AVPlayer opens a stream)
group("playback")
if !movieStreams.isEmpty, want("playback") {
    // Try likely-native streams first, then unknowns, then the rest. Up to 8 probes.
    let ordered = movieStreams.sorted {
        let rank: (AddonStream) -> Int = { $0.likelyNative == true ? 0 : ($0.likelyNative == nil ? 1 : 2) }
        return rank($0) < rank($1)
    }.prefix(8)

    // All candidates at once (probe + spec measure per stream), 10 s timeout each: the slowest
    // server sets the wait, not the sum of all of them. Results keep the ranked order.
    let probed: [(Int, AddonStream, ProbeResult)] = await withTaskGroup(of: (Int, AddonStream, ProbeResult)?.self) { group in
        for (i, s) in ordered.enumerated() {
            guard let u = URL(string: s.url!) else { continue }
            let headers = s.requestHeaders
            group.addTask {
                async let probe = PlaybackProbe.probe(url: u, headers: headers, timeout: 10)
                async let spec = PlaybackProbe.measure(url: u, headers: headers)
                var r = await probe
                let m = await spec
                if r.playable, m.measuredFrom != nil { let p = r.playable; r = m; r.playable = p }
                return (i, s, r)
            }
        }
        var out: [(Int, AddonStream, ProbeResult)] = []
        for await x in group { if let x { out.append(x) } }
        return out.sorted { $0.0 < $1.0 }
    }
    let playable = Array(probed.filter { $0.2.playable }.prefix(3).map { ($0.1, $0.2) })
    let lastError = probed.last { !$0.2.playable }.map { $0.2.error ?? "not playable (.\($0.1.container))" } ?? "none tried"

    if let first = playable.first {
        let (s, r) = first
        var d = "\(playable.count) of \(ordered.count) tried · @\(URL(string: s.url!)?.host ?? "?") · .\(s.container)"
        if !r.video.isEmpty { d += " · \(r.video.joined(separator: ","))" }
        report(.pass, "Native AVPlayer can play a stream", d)
        for (ps, pr) in playable {
            var m: [String] = []
            if let c = pr.videoCodec { m.append(c) }
            if let w = pr.width, let h = pr.height { m.append("\(w)x\(h)") }
            if let f = pr.fps { m.append(String(format: "%.3g fps", f)) }
            if let k = pr.videoKbps { m.append(String(format: "%.1f Mbps", Double(k) / 1000)) }
            if let range = pr.videoRange { m.append(range) }
            if let a = pr.audioCodec { m.append("\(pr.atmos ? "Atmos " : "")\(a) \(pr.channels ?? 0)ch") }
            if let label = pr.audioLabel { m.append("audio named “\(label)”") }
            if let k = pr.audioKbps { m.append("\(k) kbps") }
            report(.warn, "Measured specs (.\(ps.container))", m.isEmpty ? "tracks not exposed before playback" : m.joined(separator: " · "))
        }
    } else {
        report(.fail, "Native AVPlayer can play a stream", "0 of \(ordered.count) playable · last: \(lastError)")
    }

    // Quality info: not required, but tells you what "native features" you're getting.
    let hdr = playable.contains { $0.1.hdr }
    report(hdr ? .pass : .warn, "HDR stream available (native)",
           hdr ? "HDR/Dolby Vision track found" : "none of the playable ones are HDR (normal for 1080p; try a 4K title)")
    let surround = playable.flatMap { $0.1.audio }.first { a in
        (Int(a.split(separator: " ").last?.dropLast(2) ?? "") ?? 0) > 2
    }
    report(surround != nil ? .pass : .warn, "Surround audio (Spatial Audio)",
           surround.map { "multichannel track: \($0)" } ?? "only stereo found in playable streams (HLS may report tracks only during playback)")
    let mkvOnly = movieStreams.filter { $0.likelyNative == false }.count
    if mkvOnly > 0 {
        report(.warn, "Streams that play in mpv", "\(mkvOnly) MKV/other streams; these open in the mpv player")
    }
} else if want("playback") {
    report(.fail, "Native AVPlayer can play a stream", "skipped: no streams to try")
}

// 8b. mpv fallback: open a real MKV with libmpv, no video/audio output.
func mpvOpen(_ url: String, headers: [String: String], timeout: Double) -> (ok: Bool, detail: String) {
    guard let h = mpv_create() else { return (false, "mpv_create failed") }
    defer { mpv_terminate_destroy(h) }
    for (k, v) in [("vo", "null"), ("ao", "null"), ("ytdl", "no"), ("terminal", "no"), ("hwdec", "no")] {
        mpv_set_option_string(h, k, v)
    }
    if !headers.isEmpty {
        mpv_set_option_string(h, "http-header-fields",
                              headers.map { "\($0): \($1)".replacingOccurrences(of: ",", with: "\\,") }.joined(separator: ","))
    }
    let debug = ProcessInfo.processInfo.environment["NS_MPV_DEBUG"] != nil
    guard mpv_initialize(h) >= 0 else { return (false, "mpv_initialize failed") }
    if debug { mpv_request_log_messages(h, "v") }
    let args: [String] = ["loadfile", url]
    var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
    cargs.append(nil)
    mpv_command(h, &cargs)
    cargs.forEach { free(UnsafeMutablePointer(mutating: $0)) }
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        guard let ev = mpv_wait_event(h, 1)?.pointee else { continue }
        if debug, ev.event_id == MPV_EVENT_LOG_MESSAGE,
           let m = ev.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee {
            // URLs carry tokens: print host only.
            let text = String(cString: m.text).replacingOccurrences(
                of: "https?://([^/\\s'\"]+)[^\\s'\"]*", with: "<$1>", options: .regularExpression)
            print("  [mpv \(String(cString: m.prefix))] \(text)", terminator: "")
        }
        if ev.event_id == MPV_EVENT_FILE_LOADED {
            func str(_ n: String) -> String? {
                guard let c = mpv_get_property_string(h, n) else { return nil }
                defer { mpv_free(c) }
                return String(cString: c)
            }
            var count: Int64 = 0
            mpv_get_property(h, "track-list/count", MPV_FORMAT_INT64, &count)
            var parts: [String] = []
            var subs = 0, audios = 0
            for i in 0..<Int(count) {
                let t = str("track-list/\(i)/type") ?? ""
                if t == "video", parts.isEmpty {
                    parts.append("\(str("track-list/\(i)/codec") ?? "?") \(str("track-list/\(i)/demux-w") ?? "?")x\(str("track-list/\(i)/demux-h") ?? "?")")
                } else if t == "audio" {
                    audios += 1
                    if audios == 1 { parts.append("\(str("track-list/\(i)/codec") ?? "?") \(str("track-list/\(i)/demux-channel-count") ?? "?")ch") }
                } else if t == "sub" { subs += 1 }
            }
            parts.append("\(audios) audio · \(subs) subtitle tracks")
            return (true, parts.joined(separator: " · "))
        }
        if ev.event_id == MPV_EVENT_END_FILE {
            let e = ev.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            return (false, e.map { String(cString: mpv_error_string($0.error)) } ?? "ended")
        }
    }
    return (false, "timed out after \(Int(timeout))s")
}
// A widely available title, so most stream add-ons return MKV links for it.
let mkvMovieId = "tt0468569"   // The Dark Knight
group("mpv")
var mkvStreams: [AddonStream] = []
if let streamAddon, want("mpv") {
    mkvStreams = ((try? await client.streams(streamAddon, type: "movie", id: mkvMovieId)) ?? [])
        .filter { $0.likelyNative == false && $0.url != nil }
}
if !mkvStreams.isEmpty {
    // Top 4 MKV streams opened in parallel (15 s each); first success wins, the rest are cancelled.
    let top = Array(mkvStreams.sorted(by: { $0.quality > $1.quality }).prefix(4))
    let result: (ok: Bool, detail: String) = await withTaskGroup(of: (Bool, String).self) { group in
        for s in top {
            let url = s.url!, headers = s.requestHeaders, ext = s.container
            group.addTask {
                let r = await Task.detached { mpvOpen(url, headers: headers, timeout: 15) }.value
                return (r.ok, r.ok ? ".\(ext) · @\(URL(string: url)?.host ?? "?") · " + r.detail : r.detail)
            }
        }
        var last = (false, "none tried")
        for await r in group {
            if r.0 { group.cancelAll(); return (true, "\(top.count) tried in parallel · " + r.1) }
            last = r
        }
        return last
    }
    report(result.ok ? .pass : .fail, "mpv can open an MKV stream", result.detail)
}

group("subtitles")
// 9. Subtitles: parser + a real subtitle add-on
_ = await check("Subtitle parser (SRT/WebVTT)") {
    let srt = SubtitleParser.parse("1\n00:00:01,000 --> 00:00:02,500\n<i>Hi</i>\n")
    let vtt = SubtitleParser.parse("WEBVTT\n\n00:01.000 --> 00:02.000 align:start\nHello\nthere\n")
    let ok = srt.count == 1 && srt[0].start == 1 && srt[0].end == 2.5 && srt[0].text == "Hi"
        && vtt.count == 1 && vtt[0].text == "Hello\nthere" && SubtitleLanguage.normalize("pob") == "pt-BR"
    return ((), ok ? "SRT + WebVTT cues, tags stripped, language codes normalized" : "srt \(srt) vtt \(vtt)", ok)
}
_ = await check("Subtitles from OpenSubtitles v3") {
    let os = try await client.install("https://opensubtitles-v3.strem.io/manifest.json")
    let tracks = try await client.subtitles(os, type: "movie", id: movieId)
    let langs = Set(tracks.map(\.languageCode)).count
    guard let en = tracks.first(where: { $0.languageCode == "en" }) else { return ((), "\(tracks.count) tracks, no English", false) }
    let cues = try await client.cues(for: en).cues.count
    return ((), "\(tracks.count) tracks · \(langs) languages · English file → \(cues) cues", cues > 100)
}

// 10. Title page info (rating, cast, trailer)
group("catalog")
if let cinemeta, want("catalog") {
    _ = await check("Title info: rating, cast, trailer") {
        guard let m = try await client.meta(cinemeta, type: "movie", id: movieId) else { return ((), "missing", false) }
        let ok = m.imdbScore != nil && !(m.cast ?? []).isEmpty && m.trailerURL != nil && m.imdbURL != nil
        return ((), "IMDb \(m.imdbRating ?? "?") · \(m.cast?.count ?? 0) cast · director \(m.director?.first ?? "?") · trailer \(m.trailerURL != nil ? "yes" : "no")", ok)
    }
}

group("persistence")
// 11. Persistence (add-ons and library survive a restart)
_ = await check("Saved add-ons survive restart") {
    let list = [cinemeta, streamAddon].compactMap { $0 }
    let data = try JSONEncoder().encode(list)
    let back = try JSONDecoder().decode([InstalledAddon].self, from: data)
    return ((), "\(back.count) add-ons round-tripped", back.map(\.id) == list.map(\.id) && !list.isEmpty)
}

print("")
if failures == 0 {
    print("✅ All required checks green. Launch the app with:  swift run Foyer")
    exit(0)
} else {
    print("❌ \(failures) required check(s) failed.")
    exit(1)
}
