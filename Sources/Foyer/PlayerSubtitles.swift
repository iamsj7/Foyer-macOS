import SwiftUI
import AVFoundation
import AddonKit

/// External subtitles (Stremio "subtitles" add-ons) for the native player.
/// AVPlayer can't attach a sidecar SRT/VTT to a remote item, so cues are downloaded, parsed and
/// drawn by `SubtitleOverlay`, kept in sync by a 0.1 s periodic time observer.
/// Picture in Picture shows only the video layer, so these cues don't appear there.
@MainActor @Observable
final class SubtitleController {
    /// Shared with `@AppStorage` in `SubtitleMenu`. Normalized language code ("en", "pt-BR"); "" = off.
    static let preferredLanguageKey = "subtitles.preferredLanguage"

    struct LanguageGroup: Identifiable {
        let code: String
        let name: String
        let tracks: [SubtitleTrack]
        var id: String { code }
    }

    private(set) var groups: [SubtitleGroup] = []
    private(set) var isSearching = false
    private(set) var hasSubtitleAddons = false
    private(set) var selected: SubtitleTrack?
    private(set) var isLoadingTrack = false
    /// Text on screen right now, or nil.
    private(set) var text: String?
    /// Seconds; positive shows subtitles later, negative earlier.
    private(set) var offset: Double = 0
    /// Short status shown briefly at the top of the player ("Subtitle delay +0.5 s").
    private(set) var notice: String?

    private weak var player: AVPlayer?
    private var request: PlayRequest?
    private var timeline: SubtitleTimeline?
    private var timeObserver: Any?
    private var searchTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var addonOrder: [String] = []
    private var userChose = false
    private var generation = 0
    private let client = AddonClient()

    var tracks: [SubtitleTrack] { groups.flatMap(\.subtitles) }
    var failedAddons: [SubtitleGroup] { groups.filter { $0.error != nil } }

    /// Languages, the preferred one first, then the system language, then alphabetical.
    var languages: [LanguageGroup] {
        let preferred = UserDefaults.standard.string(forKey: Self.preferredLanguageKey) ?? ""
        let system = Locale.current.language.languageCode?.identifier ?? "en"
        let byCode = Dictionary(grouping: tracks, by: \.languageCode)
        return byCode.map { LanguageGroup(code: $0.key, name: SubtitleLanguage.displayName($0.key), tracks: $0.value) }
            .sorted { a, b in
                func rank(_ g: LanguageGroup) -> Int {
                    if !preferred.isEmpty && g.code == preferred { return 0 }
                    if SubtitleLanguage.base(g.code) == system { return 1 }
                    return g.code == "und" ? 3 : 2
                }
                let ra = rank(a), rb = rank(b)
                return ra != rb ? ra < rb : a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    // MARK: Lifecycle

    func attach(player: AVPlayer, request: PlayRequest) {
        self.player = player
        self.request = request
        search()
    }

    func detach() {
        searchTask?.cancel(); loadTask?.cancel(); noticeTask?.cancel()
        stopObserving()
        timeline = nil; text = nil
    }

    /// Reads the installed add-ons (same file AddonStore persists) and asks the subtitle-capable ones.
    func search() {
        guard let request else { return }
        searchTask?.cancel()
        let addons = Disk.load("addons", as: [InstalledAddon].self) ?? []
        let capable = addons.filter { $0.supports("subtitles", type: request.type, id: request.videoId) }
        addonOrder = addons.map(\.id)
        hasSubtitleAddons = !capable.isEmpty
        groups = []
        generation += 1
        guard !capable.isEmpty else { isSearching = false; return }
        isSearching = true
        let client = client, gen = generation
        let onGroup: @Sendable (SubtitleGroup) async -> Void = { [weak self] group in
            await self?.receive(group, generation: gen)
        }
        searchTask = Task { [weak self] in
            await client.subtitles(from: capable, type: request.type, id: request.videoId, onGroup: onGroup)
            guard let self, self.generation == gen else { return }
            self.isSearching = false
        }
    }

    private func receive(_ group: SubtitleGroup, generation gen: Int) {
        guard gen == generation else { return }   // a newer search replaced this one
        groups.removeAll { $0.id == group.id }
        groups.append(group)
        groups.sort { (addonOrder.firstIndex(of: $0.id) ?? .max) < (addonOrder.firstIndex(of: $1.id) ?? .max) }
        autoSelect()
    }

    /// Picks the remembered language the first time a matching track shows up.
    private func autoSelect() {
        guard !userChose, selected == nil,
              let preferred = UserDefaults.standard.string(forKey: Self.preferredLanguageKey), !preferred.isEmpty
        else { return }
        let match = tracks.first { $0.languageCode == preferred }
            ?? tracks.first { SubtitleLanguage.base($0.languageCode) == SubtitleLanguage.base(preferred) }
        if let match { load(match) }
    }

    // MARK: Choosing

    func select(_ track: SubtitleTrack) {
        userChose = true
        load(track)
    }

    func turnOff() {
        userChose = true
        loadTask?.cancel()
        selected = nil; isLoadingTrack = false
        timeline = nil; text = nil
        stopObserving()
    }

    private func load(_ track: SubtitleTrack) {
        loadTask?.cancel()
        selected = track
        isLoadingTrack = true
        timeline = nil; text = nil
        let client = client
        loadTask = Task { [weak self] in
            do {
                let timeline = try await client.cues(for: track)   // download + parse off the main actor
                guard let self, !Task.isCancelled, self.selected?.id == track.id else { return }
                self.isLoadingTrack = false
                guard !timeline.cues.isEmpty else {
                    self.flash("No readable cues in that \(track.languageName) file. Try another.")
                    return
                }
                self.timeline = timeline
                self.startObserving()
                self.turnOffEmbeddedSubtitles()
            } catch {
                guard let self, !Task.isCancelled, self.selected?.id == track.id else { return }
                self.isLoadingTrack = false
                self.selected = nil
                // Host only: subtitle links can carry tokens.
                self.flash("Couldn't download subtitles from \(track.host.isEmpty ? track.addonName : track.host).")
            }
        }
    }

    // MARK: Timing

    func adjustOffset(by delta: Double) {
        offset = ((offset + delta) * 10).rounded() / 10
        refresh()
        flash(offsetDescription)
    }

    func resetOffset() {
        offset = 0
        refresh()
        flash(offsetDescription)
    }

    var offsetDescription: String {
        if offset == 0 { return "Subtitle timing: in sync" }
        return offset > 0 ? String(format: "Subtitles delayed %.1f s", offset)
                          : String(format: "Subtitles earlier by %.1f s", -offset)
    }

    private func startObserving() {
        guard timeObserver == nil, let player else { refresh(); return }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10),
                                                      queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.update(time.seconds) }
        }
        refresh()
    }

    private func stopObserving() {
        if let t = timeObserver { player?.removeTimeObserver(t) }
        timeObserver = nil
    }

    private func refresh() {
        guard let player else { return }
        update(player.currentTime().seconds)
    }

    private func update(_ seconds: Double) {
        guard seconds.isFinite else { return }
        let new = timeline?.text(at: seconds - offset)
        if new != text { text = new }
    }

    /// Avoids two sets of subtitles: when an external track is on, switch off a stream's own
    /// (non-forced) subtitle track. The player's subtitle menu can still turn it back on.
    private func turnOffEmbeddedSubtitles() {
        guard let item = player?.currentItem else { return }
        Task { [weak self] in
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                  self?.selected != nil, group.allowsEmptySelection,
                  let current = item.currentMediaSelection.selectedMediaOption(in: group),
                  !current.hasMediaCharacteristic(.containsOnlyForcedSubtitles) else { return }
            item.select(nil, in: group)
        }
    }

    private func flash(_ message: String) {
        noticeTask?.cancel()
        notice = message
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}

// MARK: - Overlay

/// Bottom-centered cues, sized to the window. Never takes mouse events.
struct SubtitleOverlay: View {
    let controller: SubtitleController
    /// True while the player's control bar shows; lifts the text above it.
    let controlsVisible: Bool

    var body: some View {
        GeometryReader { geo in
            let size = min(max(geo.size.height * 0.045, 15), 60)
            let lift = controlsVisible ? max(96, geo.size.height * 0.06) : max(24, geo.size.height * 0.06)
            VStack {
                Spacer(minLength: 0)
                if let text = controller.text {
                    Text(text)
                        .font(.system(size: size, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineSpacing(size * 0.08)
                        .shadow(color: .black.opacity(0.9), radius: 1, x: 0, y: 0)
                        .shadow(color: .black.opacity(0.8), radius: 1, x: 1, y: 1)
                        .shadow(color: .black.opacity(0.55), radius: size * 0.18, x: 0, y: 1)
                        .padding(.horizontal, size * 0.45)
                        .padding(.vertical, size * 0.12)
                        .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
                        .frame(maxWidth: geo.size.width * 0.86)
                        .id(text)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, lift)
            .animation(.easeOut(duration: 0.12), value: controller.text)
            .animation(.easeInOut(duration: 0.25), value: controlsVisible)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(controller.text == nil)
    }
}

/// Short status capsule at the top ("Subtitles delayed 0.5 s", download errors).
struct SubtitleNotice: View {
    let message: String?

    var body: some View {
        VStack {
            if let message {
                Text(message)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassSurface(Capsule())
                    .environment(\.colorScheme, .dark)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Spacer()
        }
        .padding(.top, 18)
        .animation(.easeOut(duration: 0.2), value: message)
        .allowsHitTesting(false)
    }
}

// MARK: - Menu

/// Add-on subtitle items (languages, each a submenu of files; timing; search again), embedded in
/// the player's Subtitles menu.
struct SubtitleMenu: View {
    let controller: SubtitleController
    @AppStorage(SubtitleController.preferredLanguageKey) private var preferredLanguage = ""

    /// Called after an add-on track is picked (the player turns embedded subtitles off).
    var onPick: (() -> Void)? = nil

    var body: some View {
        if !controller.hasSubtitleAddons {
            Section("No subtitle add-ons installed") {
                SettingsLink { Text("Add OpenSubtitles in Settings…") }
            }
        } else {
            Section(header) {
                ForEach(controller.languages) { language in
                    Menu {
                        ForEach(language.tracks) { track in
                            Toggle(title(track), isOn: Binding(get: { controller.selected?.id == track.id },
                                                               set: { on in
                                guard on else { return }
                                controller.select(track); onPick?()
                                preferredLanguage = track.languageCode
                            }))
                        }
                    } label: {
                        if controller.selected?.languageCode == language.code {
                            Label("\(language.name) (\(language.tracks.count))", systemImage: "checkmark")
                        } else {
                            Text("\(language.name) (\(language.tracks.count))")
                        }
                    }
                }
            }
            ForEach(controller.failedAddons) { group in
                Text("\(group.addon.manifest.name) didn't answer")
            }
        }

        Section(timingHeader) {
            Button("Delay by 0.5 s") { controller.adjustOffset(by: 0.5) }
            Button("Show 0.5 s Earlier") { controller.adjustOffset(by: -0.5) }
            Button("Reset Timing") { controller.resetOffset() }
                .disabled(controller.offset == 0)
        }
        .disabled(controller.selected == nil)

        Divider()
        Button("Search Again") { controller.search() }
            .disabled(controller.isSearching)
    }

    private var header: String {
        if controller.isSearching { return controller.tracks.isEmpty ? "Searching add-ons…" : "Languages (searching…)" }
        if controller.isLoadingTrack, let s = controller.selected { return "Loading \(s.languageName)…" }
        return controller.tracks.isEmpty ? "No subtitles found" : "Languages"
    }

    private var timingHeader: String {
        controller.offset == 0 ? "Timing" : String(format: "Timing (%+.1f s)", controller.offset)
    }

    private func title(_ t: SubtitleTrack) -> String {
        var name = t.label ?? t.languageName
        if name.count > 70 { name = String(name.prefix(67)) + "…" }
        return "\(name) — \(t.addonName)"
    }
}
