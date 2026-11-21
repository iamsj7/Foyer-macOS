import SwiftUI
import AVKit
import AppKit
import MediaPlayer
import AddonKit

/// What LoadingOverlay shows until the first frame plays.
enum LoadPhase: Equatable {
    case connecting      // opening the stream, reading its tracks: no measurable progress yet
    case buffering       // downloading ahead of the playhead: progress is measurable
    case playing         // video is on screen; overlay hidden
}

/// The AVPlayer window's model. Video is drawn by an AVPlayerLayer with our own control bar
/// (AVControls.swift); PiP, AirPlay, HDR/Dolby Vision on EDR displays and Spatial Audio come from AVFoundation.
/// Defaults left on purpose (per AVFoundation headers): appliesMediaSelectionCriteriaAutomatically,
/// appliesPerFrameHDRDisplayMetadata, allowedAudioSpatializationFormats (mono/stereo/multichannel for video).
@MainActor @Observable
final class PlayerModel: PlaybackControls {
    let player = AVPlayer()
    let request: PlayRequest
    var failure: String?
    private(set) var phase: LoadPhase = .connecting
    /// 0…1: seconds buffered ahead of the playhead, against `bufferTarget`.
    private(set) var bufferProgress: Double = 0
    /// Seconds buffered ahead that count as 100%: two to three HLS segments.
    private let bufferTarget: Double = 10
    /// External subtitles from add-ons (drawn by SubtitleOverlay).
    let subtitles = SubtitleController()
    private(set) var isPaused = false

    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var bufferObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    @ObservationIgnored private var fastTimeObserver: Any?

    // MARK: State for our control bar
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var volume: Double = 1
    private(set) var isMuted = false
    private(set) var audioOptions: [AVMediaSelectionOption] = []
    private(set) var legibleOptions: [AVMediaSelectionOption] = []
    private(set) var selectedAudio: AVMediaSelectionOption?
    private(set) var selectedLegible: AVMediaSelectionOption?
    private(set) var canPictureInPicture = false
    @ObservationIgnored private var audioGroup: AVMediaSelectionGroup?
    @ObservationIgnored private var legibleGroup: AVMediaSelectionGroup?
    @ObservationIgnored private var pip: AVPictureInPictureController?
    @ObservationIgnored private var pipObservation: NSKeyValueObservation?
    @ObservationIgnored private var pipDelegate: PiPDelegate?
    private var notificationTokens: [NSObjectProtocol] = []
    private var commandTokens: [(MPRemoteCommand, Any)] = []
    private var artwork: MPMediaItemArtwork?
    private var didStart = false

    init(request: PlayRequest) { self.request = request }

    func start(library: LibraryStore) {
        guard let url = URL(string: request.url) else { failure = "This stream has an invalid URL."; return }
        // AVPlayer drops custom headers on segment requests; HLS that needs them goes through the
        // loopback proxy, which adds them to every request.
        guard HLSHeaderProxy.isNeeded(url: url, headers: request.headers) else {
            begin(url: url, headers: request.headers, library: library)
            return
        }
        startTask = Task {
            let local = await HLSHeaderProxy.shared.localURL(for: url, headers: request.headers)
            proxied = local
            // The window may have closed while the proxy was starting.
            guard !stopped, !Task.isCancelled else { return }
            begin(url: local ?? url, headers: local == nil ? request.headers : [:], library: library)
        }
    }

    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var proxied: URL?
    @ObservationIgnored private var stopped = false

    private func begin(url: URL, headers: [String: String], library: LibraryStore) {
        let item = AVPlayerItem(asset: PlaybackProbe.makeAsset(url: url, headers: headers))
        player.replaceCurrentItem(with: item)
        player.preventsDisplaySleepDuringVideoPlayback = true
        player.allowsExternalPlayback = true          // AirPlay to Apple TV / AirPlay speakers

        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error.map(Self.describe)
            Task { @MainActor in self?.handle(status, message) }
        }
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.updatePhase()
                self?.publishNowPlaying()
                if let self { let p = self.player.timeControlStatus == .paused; if p != self.isPaused { self.isPaused = p } }
            }
        }
        bufferObservation = item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.updateBuffer() }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1),
                                                      queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveProgress(library)
                self?.publishNowPlaying()
            }
        }
        // Twice a second for the control bar's clock and scrubber.
        fastTimeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                          queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, let item = self.player.currentItem else { return }
                if t.seconds.isFinite { self.position = t.seconds }
                let d = item.duration.seconds
                if d.isFinite, d > 0, d != self.duration { self.duration = d }
            }
        }
        // Errors after playback began (network drop, bad segment) arrive here, not via status.
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] note in
            let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            let message = err.map(Self.describe) ?? "Playback stopped unexpectedly."
            MainActor.assumeIsolated { self?.failure = message }
        })
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveProgress(library) }
        })
        setUpRemoteCommands()
        loadArtwork()
        subtitles.attach(player: player, request: request)
    }

    // MARK: Loading progress

    private func updateBuffer() {
        guard let item = player.currentItem else { return }
        let now = player.currentTime().seconds
        // The loaded range that contains the playhead; its end minus "now" is what's buffered ahead.
        let ahead = item.loadedTimeRanges.map(\.timeRangeValue).compactMap { r -> Double? in
            let start = r.start.seconds, end = (r.start + r.duration).seconds
            guard start.isFinite, end.isFinite, now >= start - 0.5, now <= end else { return nil }
            return end - now
        }.max() ?? 0
        var target = bufferTarget
        if item.duration.isNumeric { target = min(target, max(1, item.duration.seconds - now)) }
        bufferProgress = min(1, max(bufferProgress * (phase == .buffering ? 1 : 0), ahead / target))
        updatePhase()
    }

    private func updatePhase() {
        guard failure == nil else { return }
        switch player.timeControlStatus {
        case .playing:
            phase = .playing
        case .waitingToPlayAtSpecifiedRate:
            // Before the item is ready we can't measure anything; afterwards it's buffering.
            if player.currentItem?.status == .readyToPlay {
                if phase == .playing { bufferProgress = 0 }   // a mid-playback stall starts again from 0
                phase = .buffering
            } else {
                phase = .connecting
            }
        case .paused:
            if phase != .playing && player.currentItem?.status == .readyToPlay { phase = .buffering }
        @unknown default:
            break
        }
    }

    nonisolated private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return ns.localizedFailureReason ?? ns.localizedDescription
    }

    private func handle(_ status: AVPlayerItem.Status, _ message: String?) {
        switch status {
        case .readyToPlay where !didStart:
            didStart = true
            if request.startAt > 5 {
                player.seek(to: CMTime(seconds: request.startAt, preferredTimescale: 600))
            }
            player.play()
            updateBuffer()
            publishNowPlaying()
            checkForVideo()
            loadMediaOptions()
        case .failed:
            let isMKV = request.url.lowercased().contains(".mkv")
            failure = isMKV
                ? "This is an MKV file, which Apple's native player can't open. Play it with mpv instead, or pick a stream marked NATIVE."
                : (message ?? "The native player couldn't open this stream.")
        default:
            break
        }
    }

    // MARK: Now Playing + media keys

    private func publishNowPlaying() {
        guard let item = player.currentItem else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: request.titleName,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime().seconds,
            MPNowPlayingInfoPropertyPlaybackRate: player.rate,
        ]
        if !request.subtitle.isEmpty { info[MPMediaItemPropertyArtist] = request.subtitle }
        if item.duration.isNumeric { info[MPMediaItemPropertyPlaybackDuration] = item.duration.seconds }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = player.timeControlStatus == .paused ? .paused : .playing
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
        on(c.playCommand) { [weak self] _ in self?.player.play() }
        on(c.pauseCommand) { [weak self] _ in self?.player.pause() }
        on(c.togglePlayPauseCommand) { [weak self] _ in
            guard let p = self?.player else { return }
            p.timeControlStatus == .paused ? p.play() : p.pause()
        }
        c.skipForwardCommand.preferredIntervals = [10]
        c.skipBackwardCommand.preferredIntervals = [10]
        on(c.skipForwardCommand) { [weak self] _ in self?.skip(10) }
        on(c.skipBackwardCommand) { [weak self] _ in self?.skip(-10) }
        on(c.changePlaybackPositionCommand) { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return }
            self?.player.seek(to: CMTime(seconds: e.positionTime, preferredTimescale: 600))
        }
    }

    /// Set when Apple's player can decode the audio but not the video (e.g. HEVC tagged "hev1"
    /// in MP4, common for Dolby Vision streams): the screen hands the stream to mpv.
    var needsMPV = false
    /// Fit / Fill / Stretch (Apple's player can't reshape or show actual size).
    /// Opens at the original aspect (Fit) every time; a change applies to this window only.
    var scaling: VideoScaling = .fit

    var currentSeconds: Double { player.currentTime().seconds.isFinite ? player.currentTime().seconds : request.startAt }

    private func checkForVideo() {
        guard !request.url.lowercased().contains(".m3u8"), let asset = player.currentItem?.asset else { return }
        Task { [weak self] in
            let video = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            guard let self, !self.stopped else { return }
            let decodable = video.isEmpty ? false : ((try? await video[0].load(.isPlayable)) ?? true)
            if !audio.isEmpty && !decodable { self.player.pause(); self.needsMPV = true }
        }
    }

    func togglePause() { player.timeControlStatus == .paused ? player.play() : player.pause() }
    func nudgeVolume(_ delta: Double) { setVolume(volume + delta) }
    func toggleMute() { player.isMuted.toggle(); isMuted = player.isMuted }
    func setVolume(_ v: Double) {
        volume = min(1, max(0, v))
        player.volume = Float(volume)
        if player.isMuted && volume > 0 { player.isMuted = false; isMuted = false }
    }
    func seek(to t: Double) {
        position = max(0, t)
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func selectAudio(_ o: AVMediaSelectionOption?) {
        guard let g = audioGroup, let o else { return }
        player.currentItem?.select(o, in: g); selectedAudio = o
    }
    func selectLegible(_ o: AVMediaSelectionOption?) {
        guard let g = legibleGroup else { return }
        player.currentItem?.select(o, in: g); selectedLegible = o
    }

    /// Reads the stream's own audio and subtitle tracks once it's ready.
    private func loadMediaOptions() {
        guard let item = player.currentItem else { return }
        let asset = item.asset
        Task { [weak self] in
            let audible = try? await asset.loadMediaSelectionGroup(for: .audible)
            let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard let self, !self.stopped else { return }
            self.audioGroup = audible
            self.legibleGroup = legible
            self.audioOptions = audible?.options ?? []
            // Forced-only subtitle tracks play automatically; don't list them.
            self.legibleOptions = (legible?.options ?? []).filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }
            if let a = audible { self.selectedAudio = item.currentMediaSelection.selectedMediaOption(in: a) }
            if let l = legible { self.selectedLegible = item.currentMediaSelection.selectedMediaOption(in: l) }
        }
    }

    // MARK: Picture in Picture (from our AVPlayerLayer)

    func attach(layer: AVPlayerLayer) {
        guard pip == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let controller = AVPictureInPictureController(playerLayer: layer)
        let delegate = PiPDelegate()
        controller?.delegate = delegate
        pipDelegate = delegate
        pip = controller
        pipObservation = controller?.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] c, _ in
            let possible = c.isPictureInPicturePossible
            Task { @MainActor in self?.canPictureInPicture = possible }
        }
    }

    func togglePictureInPicture() {
        guard let pip else { return }
        pip.isPictureInPictureActive ? pip.stopPictureInPicture() : pip.startPictureInPicture()
    }

    func skip(_ seconds: Double) {
        let t = player.currentTime().seconds + seconds
        player.seek(to: CMTime(seconds: max(0, t), preferredTimescale: 600))
    }

    private func loadArtwork() {
        guard let s = request.poster, let url = URL(string: s) else { return }
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data) else { return }
            let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self?.artwork = art
            self?.publishNowPlaying()
        }
    }

    // MARK: Progress + teardown

    func saveProgress(_ library: LibraryStore) {
        guard let item = player.currentItem else { return }
        let pos = player.currentTime().seconds
        let dur = item.duration.seconds
        guard pos.isFinite, dur.isFinite, dur > 0 else { return }
        library.updateProgress(request, position: pos, duration: dur)
    }

    func stop(library: LibraryStore) {
        stopped = true
        startTask?.cancel(); startTask = nil
        if let proxied { HLSHeaderProxy.shared.endSession(for: proxied) }
        saveProgress(library)
        player.pause()
        subtitles.detach()
        if let t = timeObserver { player.removeTimeObserver(t); timeObserver = nil }
        if let t = fastTimeObserver { player.removeTimeObserver(t); fastTimeObserver = nil }
        pip?.stopPictureInPicture()
        pipObservation?.invalidate()
        statusObservation?.invalidate()
        rateObservation?.invalidate()
        bufferObservation?.invalidate()
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens = []
        commandTokens.forEach { $0.0.removeTarget($0.1) }
        commandTokens = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        player.replaceCurrentItem(with: nil)
    }
}

struct PlayerScreen: View {
    let request: PlayRequest
    @Environment(LibraryStore.self) private var library
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: PlayerModel?
    @State private var controlsVisible = true
    @State private var lastActivity = Date()
    @State private var lastPointer: CGPoint?
    @State private var scrubbing: Double?
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let model {
                PlayerLayerRepresentable(model: model)
                    .ignoresSafeArea()
                    // On the video only (never the control bar), like the TV app: click shows or hides
                    // the controls, double-click toggles full screen. Space and ⌘↩ play and pause.
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { NSApp.keyWindow?.toggleFullScreen(nil) }
                    .onTapGesture { toggleControls() }
                if model.failure == nil {
                    SubtitleOverlay(controller: model.subtitles, controlsVisible: controlsVisible)
                        .allowsHitTesting(false)
                    SubtitleNotice(message: model.subtitles.notice)
                        .allowsHitTesting(false)
                }
                if controlsVisible && model.failure == nil && model.phase == .playing {
                    AVControlsBar(model: model, scrubbing: $scrubbing)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                }
                if model.failure == nil && model.phase != .playing {
                    LoadingOverlay(request: request, phase: model.phase, progress: model.bufferProgress)
                        .transition(.opacity)
                }
                if let f = model.failure {
                    ContentUnavailableView {
                        Label("Can't Play This Stream", systemImage: "exclamationmark.triangle")
                    } description: { Text(f) } actions: {
                        Button("Play with mpv", systemImage: "play.fill") {
                            openWindow(value: MPVRequest(request: request))
                            dismissWindow()
                        }
                        .nativeButtonStyle(prominent: true)
                        .controlSize(.large)
                        Button("Close") { dismissWindow() }
                            .keyboardShortcut(.cancelAction)
                            .controlSize(.large)
                    }
                    .foregroundStyle(.white)
                    .background(.black.opacity(0.75))
                }
            }
        }
        .animation(.easeOut(duration: 0.35), value: model?.phase)
        .animation(.easeOut(duration: 0.25), value: controlsVisible)
        // Same behaviour as the mpv window: real pointer movement shows the controls, 3 s of
        // stillness while playing hides them and the cursor. Works whether or not this window is
        // key (watching on one display while working on another).
        .onContinuousHover { phase in
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
        .onKeyPress(.upArrow) { model?.nudgeVolume(0.05); poke(); return .handled }
        .onKeyPress(.downArrow) { model?.nudgeVolume(-0.05); poke(); return .handled }
        .onKeyPress(characters: .init(charactersIn: "fF")) { _ in NSApp.keyWindow?.toggleFullScreen(nil); return .handled }
        .onKeyPress(characters: .init(charactersIn: "mM")) { _ in model?.toggleMute(); poke(); return .handled }
        .onExitCommand { if NSApp.keyWindow?.styleMask.contains(.fullScreen) == true { NSApp.keyWindow?.toggleFullScreen(nil) } }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let idle = Date().timeIntervalSince(lastActivity) > 3
                if idle, controlsVisible, model?.isPaused == false, model?.phase == .playing, scrubbing == nil {
                    controlsVisible = false
                    if NSApp.isActive { NSCursor.setHiddenUntilMouseMoves(true) }
                }
            }
        }
        .navigationTitle(request.subtitle.isEmpty ? request.titleName : "\(request.titleName) · \(request.subtitle)")
        .onChange(of: model?.needsMPV == true) { _, needs in
            guard needs, let model else { return }
            let r = request
            openWindow(value: MPVRequest(request: PlayRequest(
                url: r.url, headers: r.headers, titleId: r.titleId, videoId: r.videoId, type: r.type,
                titleName: r.titleName, subtitle: r.subtitle, poster: r.poster, startAt: model.currentSeconds)))
            dismissWindow()
        }
        .focusedSceneValue(\.playback, model)
        .playerWindow()
        .onAppear {
            focused = true
            guard model == nil else { return }
            let m = PlayerModel(request: request)
            m.start(library: library)
            model = m
        }
        .onDisappear { model?.stop(library: library) }
    }

    private func poke() {
        lastActivity = Date()
        if !controlsVisible { controlsVisible = true }
    }

    private func toggleControls() {
        if controlsVisible { controlsVisible = false } else { poke() }
    }
}

/// Shown until the first frame plays: poster, title, and a real percentage once buffering is measurable.
struct LoadingOverlay: View {
    let request: PlayRequest
    let phase: LoadPhase
    let progress: Double
    @State private var slow = false

    private var host: String { URL(string: request.url)?.host ?? "server" }   // host only: URLs carry tokens

    var body: some View {
        ZStack {
            Artwork(url: request.poster.flatMap(URL.init(string:)))
                .blur(radius: 40).opacity(0.35)
                .ignoresSafeArea()
            Color.black.opacity(0.45).ignoresSafeArea()

            VStack(spacing: 18) {
                VStack(spacing: 4) {
                    Text(request.titleName).font(.title.bold())
                    if !request.subtitle.isEmpty {
                        Text(request.subtitle).font(.title3).foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.center)

                VStack(spacing: 8) {
                    switch phase {
                    case .connecting:
                        ProgressView().controlSize(.large)
                        Text("Connecting to \(host)…").font(.callout).foregroundStyle(.secondary)
                    case .buffering:
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .frame(width: 280)
                            .tint(.white)
                        Text("Buffering \(Int((progress * 100).rounded()))%")
                            .font(.callout.weight(.medium)).monospacedDigit()
                            .contentTransition(.numericText())
                            .animation(.default, value: Int(progress * 100))
                    case .playing:
                        EmptyView()
                    }
                }
                .frame(minHeight: 44)

                if slow {
                    Text("This is taking longer than usual. The server may be slow; you can close this window and try another stream.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 360)
                        .transition(.opacity)
                }
            }
            .padding(28)
            .glassSurface(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .environment(\.colorScheme, .dark)
        }
        .allowsHitTesting(false)   // the window's buttons (close, full screen) stay usable
        .accessibilityElement(children: .combine)
        .task {
            try? await Task.sleep(for: .seconds(15))
            withAnimation { slow = true }
        }
    }
}

/// Brings the player window back when Picture in Picture ends.
final class PiPDelegate: NSObject, AVPictureInPictureControllerDelegate {
    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor in
            if let window = NSApp.windows.first(where: { $0.isMiniaturized }) { window.deminiaturize(nil) }
            NSApp.activate(ignoringOtherApps: true)
            completionHandler(true)
        }
    }
}
