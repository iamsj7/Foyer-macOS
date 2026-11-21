import SwiftUI
import AppKit
import QuartzCore
import MediaPlayer
import Libmpv
import AddonKit

// MARK: - Routing

/// Opens an mpv player window for a stream: "Play with mpv" on AVPlayer's failure screen, or the
/// automatic hand-off when AVPlayer can't decode the video.
struct MPVRequest: Codable, Hashable {
    let request: PlayRequest
}

enum PlayerEngine {
    /// Containers Apple's AVPlayer can't open; mpv plays these.
    static func prefersMPV(_ url: String) -> Bool {
        let path = (URL(string: url)?.path ?? url).lowercased()
        return ["mkv", "avi", "webm", "flv", "wmv", "ogm", "mk3d"].contains { path.hasSuffix("." + $0) }
    }
}

/// The player window's root: AVPlayer for native streams (HDR/DV, Spatial Audio, PiP, AirPlay),
/// mpv for everything else.
struct PlayerRouter: View {
    let request: PlayRequest
    var body: some View {
        if PlayerEngine.prefersMPV(request.url) {
            MPVPlayerScreen(request: request)
        } else {
            PlayerScreen(request: request)
        }
    }
}

// MARK: - libmpv wrapper

/// Owns the mpv handle. libmpv is thread-safe; events are drained on a private serial queue
/// and delivered to the main actor through `onEvent`.
final class MPVCore: @unchecked Sendable {
    enum Event: Sendable {
        case double(String, Double)
        case flag(String, Bool)
        case int(String, Int64)
        case changed(String)          // property changed; read it yourself (e.g. track-list)
        case fileLoaded
        case endFile(error: String?)
    }

    private(set) var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "mpv.events", qos: .userInitiated)
    /// Set once in init, before mpv can deliver anything, and read only on `queue`.
    private let onEvent: (@Sendable (Event) -> Void)?
    /// mpv keeps the layer's address as "wid" without retaining it; hold it until mpv is destroyed.
    private let layer: CAMetalLayer

    init?(layer: CAMetalLayer, hdr: Bool, onEvent: @escaping @Sendable (Event) -> Void) {
        self.layer = layer
        self.onEvent = onEvent
        guard let h = mpv_create() else { return nil }
        handle = h
        // mpv's "wid" is the CAMetalLayer's address as an int64 (what MPVKit's demo passes implicitly).
        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        mpv_set_option(h, "wid", MPV_FORMAT_INT64, &wid)
        option("vo", "gpu-next")
        option("gpu-api", "vulkan")
        option("gpu-context", "moltenvk")
        option("hwdec", "videotoolbox")
        option("ytdl", "no")
        option("keep-open", "yes")            // stay on the last frame at the end instead of closing
        option("cache", "yes")
        option("demuxer-max-bytes", "400MiB")
        option("demuxer-readahead-secs", "30")
        option("subs-match-os-language", "yes")
        option("subs-fallback", "yes")
        option("audio-channels", "auto-safe")   // pass surround to capable outputs, downmix otherwise
        option("input-default-bindings", "no")
        option("input-vo-keyboard", "no")      // keys go through SwiftUI, not mpv
        if hdr { option("target-colorspace-hint", "yes") }   // must be set before init (MPVKit note)
        option("terminal", "no")
        mpv_request_log_messages(h, "no")
        guard mpv_initialize(h) >= 0 else { mpv_terminate_destroy(h); handle = nil; return nil }

        observe("time-pos", MPV_FORMAT_DOUBLE)
        observe("duration", MPV_FORMAT_DOUBLE)
        observe("pause", MPV_FORMAT_FLAG)
        observe("paused-for-cache", MPV_FORMAT_FLAG)
        observe("cache-buffering-state", MPV_FORMAT_INT64)
        observe("eof-reached", MPV_FORMAT_FLAG)
        observe("volume", MPV_FORMAT_DOUBLE)
        observe("mute", MPV_FORMAT_FLAG)
        observe("track-list", MPV_FORMAT_NONE)
        observe("video-params/sig-peak", MPV_FORMAT_DOUBLE)
        observe("video-params/aspect", MPV_FORMAT_DOUBLE)
        observe("video-params/dw", MPV_FORMAT_INT64)
        observe("video-params/dh", MPV_FORMAT_INT64)

        mpv_set_wakeup_callback(h, { ctx in
            guard let ctx else { return }
            Unmanaged<MPVCore>.fromOpaque(ctx).takeUnretainedValue().drain()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private func option(_ name: String, _ value: String) { mpv_set_option_string(handle, name, value) }
    private func observe(_ name: String, _ format: mpv_format) { mpv_observe_property(handle, 0, name, format) }

    func load(_ url: String, start: Double, headers: [String: String]) {
        var opts: [String] = []
        if start > 5 { opts.append("start=\(Int(start))") }
        var rest = headers
        if let uaKey = rest.keys.first(where: { $0.caseInsensitiveCompare("User-Agent") == .orderedSame }) {
            setString("user-agent", rest.removeValue(forKey: uaKey) ?? "")
        }
        if !rest.isEmpty {
            // mpv takes a comma-separated list; commas inside values must be escaped per mpv's list syntax.
            setString("http-header-fields", rest.map { "\($0): \($1)".replacingOccurrences(of: ",", with: "\\,") }
                .joined(separator: ","))
        }
        command(["loadfile", url, "replace", "-1", opts.joined(separator: ",")].filter { !$0.isEmpty })
    }

    /// Every libmpv call runs on `queue`, never on the main thread. mpv's render thread
    /// sometimes needs the main thread (layer updates), so a main-thread call that waits for
    /// mpv's core lock can deadlock the whole app.
    private func onQueue(_ body: @escaping @Sendable (OpaquePointer) -> Void) {
        queue.async { [weak self] in
            guard let h = self?.handle else { return }
            body(h)
        }
    }

    func command(_ args: [String]) {
        onQueue { h in
            var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) } + [nil]
            defer { cargs.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
            mpv_command(h, &cargs)
        }
    }

    func setFlag(_ name: String, _ on: Bool) {
        onQueue { h in
            var v: Int32 = on ? 1 : 0
            mpv_set_property(h, name, MPV_FORMAT_FLAG, &v)
        }
    }
    func setDouble(_ name: String, _ value: Double) {
        onQueue { h in
            var v = value
            mpv_set_property(h, name, MPV_FORMAT_DOUBLE, &v)
        }
    }
    func setString(_ name: String, _ value: String) {
        onQueue { h in _ = mpv_set_property_string(h, name, value) }
    }

    /// Reads the track list on mpv's queue and hands it back on the main actor.
    func readTracks(_ done: @escaping @MainActor @Sendable ([MPVTrack]) -> Void) {
        onQueue { h in
            func str(_ n: String) -> String? {
                guard let c = mpv_get_property_string(h, n) else { return nil }
                defer { mpv_free(c) }
                return String(cString: c)
            }
            func int(_ n: String) -> Int64? {
                var v: Int64 = 0
                return mpv_get_property(h, n, MPV_FORMAT_INT64, &v) >= 0 ? v : nil
            }
            guard let count = int("track-list/count") else { return }
            let tracks: [MPVTrack] = (0..<Int(count)).compactMap { i in
                let p = "track-list/\(i)/"
                guard let type = str(p + "type"), let id = int(p + "id") else { return nil }
                return MPVTrack(id: Int(id), type: type, title: str(p + "title"),
                                lang: str(p + "lang"), codec: str(p + "codec"),
                                channels: int(p + "demux-channel-count").map(Int.init),
                                selected: str(p + "selected") == "yes",
                                external: str(p + "external") == "yes")
            }
            DispatchQueue.main.async { done(tracks) }
        }
    }

    private func drain() {
        queue.async { [weak self] in
            guard let self, let h = self.handle else { return }
            while let ev = mpv_wait_event(h, 0)?.pointee, ev.event_id != MPV_EVENT_NONE {
                switch ev.event_id {
                case MPV_EVENT_PROPERTY_CHANGE:
                    guard let p = ev.data?.assumingMemoryBound(to: mpv_event_property.self).pointee else { continue }
                    let name = String(cString: p.name)
                    switch p.format {
                    case MPV_FORMAT_DOUBLE:
                        if let d = p.data { self.onEvent?(.double(name, d.assumingMemoryBound(to: Double.self).pointee)) }
                    case MPV_FORMAT_FLAG:
                        if let d = p.data { self.onEvent?(.flag(name, d.assumingMemoryBound(to: Int32.self).pointee != 0)) }
                    case MPV_FORMAT_INT64:
                        if let d = p.data { self.onEvent?(.int(name, d.assumingMemoryBound(to: Int64.self).pointee)) }
                    default:
                        self.onEvent?(.changed(name))
                    }
                case MPV_EVENT_FILE_LOADED:
                    self.onEvent?(.fileLoaded)
                case MPV_EVENT_END_FILE:
                    let end = ev.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                    let msg = end.flatMap { $0.reason == MPV_END_FILE_REASON_ERROR ? String(cString: mpv_error_string($0.error)) : nil }
                    self.onEvent?(.endFile(error: msg))
                default:
                    break
                }
            }
        }
    }

    /// Asynchronous on purpose: mpv_terminate_destroy joins mpv's render thread, which may need the
    /// main thread (layer teardown), and tearing down a big cache would freeze the UI anyway.
    /// The block keeps `self` (and so the layer) alive until mpv is gone.
    func shutdown() {
        queue.async { [self] in
            guard let h = handle else { return }
            mpv_set_wakeup_callback(h, nil, nil)
            mpv_terminate_destroy(h)
            handle = nil
        }
    }

    deinit {
        // Safety net if shutdown() was never called; normally `handle` is already nil here.
        if let h = handle {
            mpv_set_wakeup_callback(h, nil, nil)
            mpv_terminate_destroy(h)
        }
    }
}

/// MoltenVK workarounds from MPVKit's macOS demo: ignore 1×1 drawable resets (flicker), and
/// toggle EDR on the main thread so HDR output actually engages.
final class MPVMetalLayer: CAMetalLayer {
    private func setEDR(_ on: Bool) { super.wantsExtendedDynamicRangeContent = on }
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set { if Int(newValue.width) > 1 && Int(newValue.height) > 1 { super.drawableSize = newValue } }
    }
    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            // Async, never sync: mpv's render thread calls this while its core waits on it,
            // and the main thread may be waiting on that core, so a sync hop deadlocks.
            if Thread.isMainThread { super.wantsExtendedDynamicRangeContent = newValue }
            else { DispatchQueue.main.async { [weak self] in self?.setEDR(newValue) } }
        }
    }
}

/// Hosts the Metal layer mpv renders into, and places it for the picture mode.
///
/// MPVKit's MoltenVK context ignores resizes (its control hook is VO_NOTIMPL), so mpv keeps the
/// swapchain size it started with. The drawable is therefore fixed at the largest screen's pixel
/// size (pixel-exact in full screen; MPVKit's demo does the same), mpv letterboxes the video
/// inside it, and this view moves and scales that layer so the video's own rectangle lands where
/// the mode wants it: fit, fill, stretch, actual size or a forced aspect. The view clips.
final class MPVHostView: NSView {
    let metalLayer = MPVMetalLayer()

    /// Video display aspect and size in pixels, from mpv's video-params (nil until known).
    var videoAspect: Double? { didSet { if videoAspect != oldValue { relayout(animated: false) } } }
    var videoPixels: CGSize? { didSet { if videoPixels != oldValue { relayout(animated: false) } } }
    var scaling: VideoScaling = .fit { didSet { if scaling != oldValue { relayout(animated: true) } } }
    var aspectOverride: Double? { didSet { if aspectOverride != oldValue { relayout(animated: true) } } }

    /// Our own backing layer, so mpv's layer is attached from the start (AppKit may otherwise
    /// create the backing layer later and the sublayer would be lost).
    private let container = CALayer()
    private let fixedDrawable = MPVHostView.largestScreenPixels

    override init(frame: NSRect) {
        super.init(frame: frame)
        container.backgroundColor = NSColor.black.cgColor
        container.masksToBounds = true
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        metalLayer.contentsGravity = .resize
        metalLayer.needsDisplayOnBoundsChange = false
        metalLayer.drawableSize = fixedDrawable
        container.addSublayer(metalLayer)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }
    override func makeBackingLayer() -> CALayer { container }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout(animated: false)
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        relayout(animated: false)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        relayout(animated: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// NS_PICTURE_DEBUG=1 logs every placement to stderr.
    static let debug = ProcessInfo.processInfo.environment["NS_PICTURE_DEBUG"] != nil

    static var largestScreenPixels: CGSize {
        let sizes = NSScreen.screens.map { CGSize(width: $0.frame.width * $0.backingScaleFactor,
                                                  height: $0.frame.height * $0.backingScaleFactor) }
        return sizes.max { $0.width * $0.height < $1.width * $1.height } ?? CGSize(width: 3840, height: 2160)
    }

    override func layout() {
        super.layout()
        relayout(animated: false)
    }

    private func relayout(animated: Bool) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        // The drawable must stay at mpv's swapchain size; put it back if anything changed it.
        if metalLayer.drawableSize != fixedDrawable { metalLayer.drawableSize = fixedDrawable }
        let d = fixedDrawable
        CATransaction.begin()
        CATransaction.setDisableActions(!animated || inLiveResize)
        if animated { CATransaction.setAnimationDuration(0.25) }
        metalLayer.contentsScale = scale
        metalLayer.frame = PictureLayout.layerFrame(bounds: bounds, drawable: d, videoAspect: videoAspect,
                                           override: aspectOverride, scaling: scaling,
                                           pixelSize: videoPixels.map { CGSize(width: $0.width / scale, height: $0.height / scale) })
        CATransaction.commit()
        if Self.debug {
            FileHandle.standardError.write(Data(String(format: "[picture] bounds %.0fx%.0f drawable %.0fx%.0f (layer reports %.0fx%.0f) video %@ %@ override %@ mode %@ -> layer %.0f,%.0f %.0fx%.0f scale %.0f\n",
                bounds.width, bounds.height, d.width, d.height, metalLayer.drawableSize.width, metalLayer.drawableSize.height,
                videoAspect.map { String(format: "%.3f", $0) } ?? "?", videoPixels.map { "\(Int($0.width))x\(Int($0.height))" } ?? "?",
                aspectOverride.map { String(format: "%.2f", $0) } ?? "-", scaling.rawValue,
                metalLayer.frame.minX, metalLayer.frame.minY, metalLayer.frame.width, metalLayer.frame.height, scale).utf8))
        }
    }

}

struct MPVVideoView: NSViewRepresentable {
    let host: MPVHostView
    func makeNSView(context: Context) -> MPVHostView { host }
    func updateNSView(_ nsView: MPVHostView, context: Context) {}
}

// MARK: - Model

struct MPVTrack: Identifiable, Hashable {
    let id: Int
    let type: String          // video / audio / sub
    let title: String?
    let lang: String?
    let codec: String?
    let channels: Int?
    let selected: Bool
    let external: Bool

    var label: String {
        var parts: [String] = []
        if let lang, let name = Locale.current.localizedString(forLanguageCode: lang) { parts.append(name) }
        else if let lang { parts.append(lang.uppercased()) }
        if let title, !title.isEmpty, !parts.contains(title) { parts.append(title) }
        if let codec { parts.append(codec.uppercased()) }
        if let ch = channels { parts.append(ch >= 8 ? "7.1" : ch >= 6 ? "5.1" : ch == 1 ? "Mono" : "Stereo") }
        return parts.isEmpty ? "Track \(id)" : parts.joined(separator: " · ")
    }
}

@MainActor @Observable
final class MPVPlayerModel: PlaybackControls {
    let request: PlayRequest
    let host = MPVHostView(frame: .init(x: 0, y: 0, width: 1280, height: 720))
    private var core: MPVCore?

    var position: Double = 0
    var duration: Double = 0
    var paused = false
    var buffering = true
    var bufferPercent: Int = 0
    var loaded = false
    var failure: String?
    var volume: Double = 100
    var muted = false
    var tracks: [MPVTrack] = []
    var isHDR = false
    @ObservationIgnored private var videoSize = CGSize.zero
    /// Every video opens at its original aspect (Fit); a change applies to this window only.
    var scaling: VideoScaling = .fit {
        didSet { host.scaling = scaling }
    }
    /// Per window: a forced shape is usually for one film, so it isn't remembered.
    var aspect: AspectPreset = .auto { didSet { host.aspectOverride = aspect.ratio } }

    private var lastSaved = Date.distantPast
    private var commandTokens: [(MPRemoteCommand, Any)] = []

    init(request: PlayRequest) {
        self.request = request
        host.scaling = scaling
    }

    func start(library: LibraryStore) {
        let edr = (NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1
        let onEvent: @Sendable (MPVCore.Event) -> Void = { [weak self] event in
            DispatchQueue.main.async { self?.handle(event, library: library) }
        }
        guard let core = MPVCore(layer: host.metalLayer, hdr: edr, onEvent: onEvent) else {
            failure = "mpv couldn't start on this Mac."
            return
        }
        self.core = core
        core.load(request.url, start: request.startAt, headers: request.headers)
        setUpRemoteCommands()
    }

    private func handle(_ e: MPVCore.Event, library: LibraryStore) {
        guard core != nil else { return }   // stopped: late events from the closing core
        switch e {
        case .double("time-pos", let v):
            // mpv reports every frame; the controls only need ~4 updates a second.
            if abs(v - position) >= 0.25 || v < position { position = v }
            if Date().timeIntervalSince(lastSaved) > 10 { saveProgress(library); publishNowPlaying() }
        case .double("duration", let v): duration = v
        case .double("volume", let v): volume = v
        case .double("video-params/sig-peak", let v): isHDR = v > 1
        case .double("video-params/aspect", let v): host.videoAspect = v > 0 ? v : nil
        case .int("video-params/dw", let v): videoSize.width = CGFloat(v); host.videoPixels = videoSize.width > 0 && videoSize.height > 0 ? videoSize : nil
        case .int("video-params/dh", let v): videoSize.height = CGFloat(v); host.videoPixels = videoSize.width > 0 && videoSize.height > 0 ? videoSize : nil
        case .flag("pause", let v): paused = v; publishNowPlaying()
        case .flag("mute", let v): muted = v
        case .flag("paused-for-cache", let v): buffering = v
        case .flag("eof-reached", let v): if v { saveProgress(library) }
        case .int("cache-buffering-state", let v): bufferPercent = Int(v)
        case .changed("track-list"): readTracks()
        case .fileLoaded:
            loaded = true
            buffering = false
            readTracks()
            publishNowPlaying()
        case .endFile(let error):
            if let error, !loaded || position < 1 {
                failure = "mpv couldn't open this stream (\(error))."
            }
        default: break
        }
    }

    private func readTracks() {
        core?.readTracks { [weak self] in self?.tracks = $0 }
    }

    // Controls
    func togglePause() { core?.setFlag("pause", !paused) }
    func seek(to t: Double) { core?.command(["seek", String(max(0, t)), "absolute"]) }
    func skip(_ s: Double) { core?.command(["seek", String(s), "relative"]) }
    func setVolume(_ v: Double) {
        core?.setDouble("volume", v)
        if muted && v > 0 { core?.setFlag("mute", false) }   // dragging volume up unmutes, as in Apple's players
    }
    func nudgeVolume(_ delta: Double) { setVolume(min(100, max(0, volume + delta * 100))) }
    func toggleMute() { core?.command(["cycle", "mute"]) }
    func select(_ track: MPVTrack?, type: String) {
        let prop = type == "audio" ? "aid" : type == "sub" ? "sid" : "vid"
        core?.setString(prop, track.map { String($0.id) } ?? "no")
        readTracks()
    }
    func addExternalSubtitle(_ url: URL) { core?.command(["sub-add", url.absoluteString, "select"]) }

    func saveProgress(_ library: LibraryStore) {
        lastSaved = Date()
        guard duration > 0, position.isFinite else { return }
        library.updateProgress(request, position: position, duration: duration)
    }

    // Now Playing + media keys (same behaviour as the AVPlayer window)
    private func publishNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: request.titleName,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: paused ? 0.0 : 1.0,
        ]
        if !request.subtitle.isEmpty { info[MPMediaItemPropertyArtist] = request.subtitle }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = paused ? .paused : .playing
    }

    private func setUpRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ body: @escaping @MainActor (MPRemoteCommandEvent) -> Void) {
            command.isEnabled = true
            let token = command.addTarget { event in
                MainActor.assumeIsolated { body(event) }
                return .success
            }
            commandTokens.append((command, token))
        }
        on(c.playCommand) { [weak self] _ in self?.core?.setFlag("pause", false) }
        on(c.pauseCommand) { [weak self] _ in self?.core?.setFlag("pause", true) }
        on(c.togglePlayPauseCommand) { [weak self] _ in self?.togglePause() }
        on(c.skipForwardCommand) { [weak self] _ in self?.skip(10) }
        on(c.skipBackwardCommand) { [weak self] _ in self?.skip(-10) }
        on(c.changePlaybackPositionCommand) { [weak self] e in
            if let e = e as? MPChangePlaybackPositionCommandEvent { self?.seek(to: e.positionTime) }
        }
    }

    func stop(library: LibraryStore) {
        saveProgress(library)
        commandTokens.forEach { $0.0.removeTarget($0.1) }
        commandTokens = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        core?.shutdown()
        core = nil
    }
}

// MARK: - Screen

struct MPVPlayerScreen: View {
    let request: PlayRequest
    @Environment(LibraryStore.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: MPVPlayerModel?
    @State private var controlsVisible = true
    @State private var lastActivity = Date()
    @State private var lastPointer: CGPoint?
    @State private var scrubbing: Double?
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let model {
                MPVVideoView(host: model.host).ignoresSafeArea()
                    // On the video only (never the control bar): click shows or hides the controls,
                    // double-click toggles full screen. Space and ⌘↩ play and pause.
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { toggleFullScreen() }
                    .onTapGesture { if controlsVisible { controlsVisible = false } else { poke() } }

                if let f = model.failure {
                    ContentUnavailableView {
                        Label("Can't Play This Stream", systemImage: "exclamationmark.triangle")
                    } description: { Text(f) } actions: {
                        Button("Close") { model.host.window?.performClose(nil) }
                            .keyboardShortcut(.cancelAction)
                            .controlSize(.large)
                    }
                    .foregroundStyle(.white)
                    .background(.black.opacity(0.75))
                } else if !model.loaded || model.buffering {
                    MPVLoadingBadge(request: request, loaded: model.loaded, percent: model.bufferPercent)
                        .transition(.opacity)
                }

                if controlsVisible && model.failure == nil {
                    MPVControls(model: model, scrubbing: $scrubbing)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
        .animation(.easeOut(duration: 0.25), value: controlsVisible)
        .animation(.easeOut(duration: 0.3), value: model?.loaded)
        .onContinuousHover { phase in
            // Only real pointer movement counts: SwiftUI also reports hover when the view under a
            // still pointer changes (the controls hiding), which would bring them straight back.
            guard case .active(let p) = phase else { return }
            if let last = lastPointer, hypot(p.x - last.x, p.y - last.y) < 3 { return }
            lastPointer = p
            poke()
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.space) { model?.togglePause(); poke(); return .handled }
        .onKeyPress(.leftArrow) { model?.skip(-10); poke(); return .handled }
        .onKeyPress(.rightArrow) { model?.skip(10); poke(); return .handled }
        .onKeyPress(characters: .init(charactersIn: "fF")) { _ in toggleFullScreen(); return .handled }
        .onKeyPress(.upArrow) { model?.nudgeVolume(0.05); poke(); return .handled }
        .onKeyPress(.downArrow) { model?.nudgeVolume(-0.05); poke(); return .handled }
        .onKeyPress(characters: .init(charactersIn: "mM")) { _ in model?.toggleMute(); poke(); return .handled }
        .onExitCommand { if NSApp.keyWindow?.styleMask.contains(.fullScreen) == true { toggleFullScreen() } }
        .focusedSceneValue(\.playback, model)
        .playerWindow()
        .task {
            // Auto-hide controls (and the cursor) while playing, like the system player.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let idle = Date().timeIntervalSince(lastActivity) > 3
                if idle, controlsVisible, model?.paused == false, scrubbing == nil {
                    controlsVisible = false
                    NSCursor.setHiddenUntilMouseMoves(true)
                }
            }
        }
        .navigationTitle(request.subtitle.isEmpty ? request.titleName : "\(request.titleName) · \(request.subtitle)")
        .onAppear {
            focused = true
            guard model == nil else { return }
            let m = MPVPlayerModel(request: request)
            m.start(library: library)
            model = m
        }
        .onDisappear { model?.stop(library: library) }
    }

    private func poke() {
        lastActivity = Date()
        if !controlsVisible { controlsVisible = true }
    }

    private func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }
}

/// Bottom control bar in Liquid Glass (material before macOS 26).
struct MPVControls: View {
    let model: MPVPlayerModel
    @Binding var scrubbing: Double?

    private var shownTime: Double { scrubbing ?? model.position }

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Text(format(shownTime)).monospacedDigit()
                    Slider(value: Binding(get: { shownTime }, set: { scrubbing = $0 }),
                           in: 0...max(model.duration, 1)) { editing in
                        if !editing, let t = scrubbing { model.seek(to: t); scrubbing = nil }
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Playback position")
                    Text("-" + format(max(0, model.duration - shownTime))).monospacedDigit()
                }
                .font(.callout)

                HStack(spacing: 16) {
                    trackMenu(type: "audio", systemImage: "speaker.wave.2", title: "Audio")
                    trackMenu(type: "sub", systemImage: "captions.bubble", title: "Subtitles")
                    if model.isHDR {
                        Text("HDR").font(.caption.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.7)))
                            .accessibilityLabel("HDR video")
                    }
                    Spacer()
                    Button("Back 10 Seconds", systemImage: "gobackward.10") { model.skip(-10) }
                    Button(model.paused ? "Play" : "Pause", systemImage: model.paused ? "play.fill" : "pause.fill") {
                        model.togglePause()
                    }
                    .font(.title2)
                    .keyboardShortcut(.space, modifiers: [])
                    Button("Forward 10 Seconds", systemImage: "goforward.10") { model.skip(10) }
                    Spacer()
                    MuteButton(muted: model.muted, level: model.volume / 100) { model.toggleMute() }
                    Slider(value: Binding(get: { model.volume }, set: { model.setVolume($0) }), in: 0...100)
                        .frame(width: 90).controlSize(.mini)
                        .accessibilityLabel("Volume")
                    PictureMenu(scaling: Binding(get: { model.scaling }, set: { model.scaling = $0 }),
                                aspect: Binding(get: { model.aspect }, set: { model.aspect = $0 }))
                    Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") {
                        NSApp.keyWindow?.toggleFullScreen(nil)
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.title3)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20).padding(.vertical, 14)
            .glassSurface(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .environment(\.colorScheme, .dark)
            .frame(maxWidth: 820)
            .padding(.horizontal, 24).padding(.bottom, 22)
        }
    }

    private func trackMenu(type: String, systemImage: String, title: String) -> some View {
        let list = model.tracks.filter { $0.type == type }
        return Menu {
            if type == "sub" {
                Button { model.select(nil, type: type) } label: {
                    if !list.contains(where: \.selected) { Label("Off", systemImage: "checkmark") } else { Text("Off") }
                }
                if !list.isEmpty { Divider() }
            }
            ForEach(list) { t in
                Button { model.select(t, type: type) } label: {
                    if t.selected { Label(t.label, systemImage: "checkmark") } else { Text(t.label) }
                }
            }
            if list.isEmpty && type == "audio" { Text("No audio tracks") }
        } label: {
            Label(title, systemImage: systemImage)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help(title)
        .disabled(list.isEmpty && type == "audio")
    }

    private func format(_ t: Double) -> String {
        guard t.isFinite else { return "0:00" }
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Opening/buffering state for mpv: it reports cache fill as a real percentage.
struct MPVLoadingBadge: View {
    let request: PlayRequest
    let loaded: Bool
    let percent: Int
    private var host: String { URL(string: request.url)?.host ?? "server" }   // host only: URLs carry tokens

    var body: some View {
        VStack(spacing: 12) {
            if loaded {
                ProgressView(value: Double(percent), total: 100).frame(width: 240).tint(.white)
                Text("Buffering \(percent)%").font(.callout.weight(.medium)).monospacedDigit()
            } else {
                ProgressView().controlSize(.large)
                Text("Opening with mpv · \(host)…").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}
