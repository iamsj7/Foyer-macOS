import AVFoundation
import CoreMedia

/// Asks AVFoundation directly whether the native player can open a stream,
/// and what's inside it (codec, HDR, audio channels). Only track metadata is loaded; nothing plays.
public struct ProbeResult: Sendable {
    public var playable = false
    public var hdr = false
    public var video: [String] = []
    public var audio: [String] = []
    public var duration: Double?
    public var error: String?
    /// Measured from the stream's tracks (AVAssetTrack.estimatedDataRate / nominalFrameRate).
    public var videoKbps: Int?
    public var audioKbps: Int?
    public var fps: Double?
    public var width: Int?
    public var height: Int?
    public var channels: Int?
    public var videoCodec: String?
    public var audioCodec: String?
    public var videoRange: String?      // SDR / PQ / HLG (HLS)
    public var dolbyVision = false
    public var tenBit = false
    public var atmos = false
    public var audioLabel: String?      // rendition name as the server declares it, e.g. "ENGLISH 5.1"
    public var measuredFrom: String?    // "HLS playlist" or "media tracks"

    public init() {}

    /// Friendly codec names for the four-char codes AVFoundation reports.
    public static func codecName(_ fourCC: String) -> String {
        switch fourCC {
        case "hvc1", "hev1": "HEVC"
        case "dvh1", "dvhe": "HEVC (Dolby Vision)"
        case "avc1", "avc3": "H.264"
        case "av01": "AV1"
        case "vp09": "VP9"
        case "aac", "mp4a": "AAC"
        case "ac-3": "DD"
        case "ec-3": "DD+"
        case "alac": "ALAC"
        case "opus": "Opus"
        case "fLaC": "FLAC"
        default: fourCC
        }
    }
}

public enum PlaybackProbe {
    /// Builds the asset with an add-on's proxy headers, using Apple's public options first:
    /// User-Agent → AVURLAssetHTTPUserAgentKey, Cookie → AVURLAssetHTTPCookiesKey.
    public static func makeAsset(url: URL, headers: [String: String]) -> AVURLAsset {
        var options: [String: Any] = [:]
        var rest = headers
        func take(_ name: String) -> String? {
            guard let key = rest.keys.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
            return rest.removeValue(forKey: key)
        }
        if let ua = take("User-Agent") { options[AVURLAssetHTTPUserAgentKey] = ua }
        if let cookie = take("Cookie"), let host = url.host {
            let cookies = cookie.split(separator: ";").compactMap { pair -> HTTPCookie? in
                let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard kv.count == 2 else { return nil }
                return HTTPCookie(properties: [.name: kv[0], .value: kv[1], .domain: host, .path: "/"])
            }
            if !cookies.isEmpty { options[AVURLAssetHTTPCookiesKey] = cookies }
        }
        // Anything else (Referer, Authorization…) has no public AVURLAsset option. This key is
        // undocumented but long-standing; it's only used when an add-on actually sends such headers.
        if !rest.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = rest }
        return AVURLAsset(url: url, options: options)
    }

    /// Specs for the stream list: HLS master playlist when it's .m3u8 (cheap, one small GET),
    /// otherwise AVFoundation's own track data.
    public static func measure(url: URL, headers: [String: String] = [:]) async -> ProbeResult {
        if url.path.lowercased().hasSuffix(".m3u8"),
           let r = await HLSInspector.inspect(url: url, headers: headers) {
            return r
        }
        var r = await probe(url: url, headers: headers, timeout: 15)
        if r.videoCodec != nil || r.audioCodec != nil { r.measuredFrom = "media tracks" }
        return r
    }

    public static func probe(url: URL, headers: [String: String] = [:], timeout: Double = 20) async -> ProbeResult {
        await withTaskGroup(of: ProbeResult?.self) { group in
            group.addTask { await run(url: url, headers: headers) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                var r = ProbeResult(); r.error = "timed out after \(Int(timeout))s"; return r
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? ProbeResult()
        }
    }

    /// Cancelling the caller stops AVFoundation's loading too (progressive files can read a lot).
    private static func run(url: URL, headers: [String: String]) async -> ProbeResult {
        let asset = makeAsset(url: url, headers: headers)
        return await withTaskCancellationHandler {
            await load(asset)
        } onCancel: {
            asset.cancelLoading()
        }
    }

    private static func load(_ asset: AVURLAsset) async -> ProbeResult {
        var r = ProbeResult()
        do {
            let (playable, duration) = try await asset.load(.isPlayable, .duration)
            r.playable = playable
            if duration.isNumeric { r.duration = duration.seconds }

            let hdrTracks = try await asset.loadTracks(withMediaCharacteristic: .containsHDRVideo)
            r.hdr = !hdrTracks.isEmpty

            for track in try await asset.loadTracks(withMediaType: .video) {
                let (descs, size, rate, frameRate) = try await track.load(.formatDescriptions, .naturalSize,
                                                                          .estimatedDataRate, .nominalFrameRate)
                for d in descs {
                    let code = fourCC(CMFormatDescriptionGetMediaSubType(d))
                    r.video.append("\(code) \(Int(size.width))x\(Int(size.height))")
                    if r.videoCodec == nil { r.videoCodec = ProbeResult.codecName(code) }
                }
                if r.width == nil, size.width > 0 { r.width = Int(size.width); r.height = Int(size.height) }
                if rate > 0 { r.videoKbps = max(r.videoKbps ?? 0, Int(rate / 1000)) }
                if frameRate > 0 { r.fps = Double(frameRate) }
            }
            try Task.checkCancellation()
            for track in try await asset.loadTracks(withMediaType: .audio) {
                let (descs, rate) = try await track.load(.formatDescriptions, .estimatedDataRate)
                for d in descs {
                    let code = fourCC(CMFormatDescriptionGetMediaSubType(d))
                    let ch = Int(CMAudioFormatDescriptionGetStreamBasicDescription(d)?.pointee.mChannelsPerFrame ?? 0)
                    r.audio.append("\(code) \(ch)ch")
                    // Keep the richest audio track: most channels, then highest bitrate.
                    if ch > (r.channels ?? 0) || (ch == r.channels && Int(rate / 1000) > (r.audioKbps ?? 0)) {
                        r.channels = ch
                        r.audioCodec = ProbeResult.codecName(code)
                        if rate > 0 { r.audioKbps = Int(rate / 1000) }
                    }
                }
            }
        } catch {
            r.error = (error as NSError).localizedFailureReason ?? error.localizedDescription
        }
        return r
    }

    public static func fourCC(_ v: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xff) }
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "\(v)"
    }
}
