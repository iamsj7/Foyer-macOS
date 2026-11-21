import SwiftUI
import AppKit
import AddonKit

struct DetailView: View {
    let preview: MetaPreview
    @Environment(AddonStore.self) private var store
    @Environment(LibraryStore.self) private var library
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var meta: Meta?
    /// Everything derived from `meta` for display, computed once when it arrives.
    @State private var info: TitleInfo?
    @State private var season: Int = 1
    @State private var selectedVideo: Video?
    @State private var groups: [StreamGroup] = []
    @State private var watchLinks: [WatchLink] = []
    @State private var heroWidth: CGFloat = 0
    @State private var checkingSources: (done: Int, total: Int)?
    @State private var autoPlayTask: Task<Void, Never>?
    @State private var noSourceResponded = false
    @State private var addonTrailer: URL?
    /// Starts true so the streams area shows "loading", not "none found", before the first fetch begins.
    @State private var loadingStreams = true
    /// Specs read from the streams themselves (HLS playlist / media tracks), keyed by stream id.
    @State private var probeToken: UUID?
    @State private var measured: [String: ProbeResult] = [:]
    /// Hero text fades and rises in once, when the page first appears.
    @State private var heroShown = false
    @Namespace private var glass

    private var isSeries: Bool { preview.type == "series" }
    private var episodes: [Video] { (meta?.videos ?? []).filter { ($0.season ?? 0) > 0 } }
    private var seasons: [Int] { Array(Set(episodes.compactMap(\.season))).sorted() }
    /// The id sent to stream add-ons: the title for movies, "tt…:season:episode" for series.
    /// Add-ons key on IMDb ids, so titles from add-ons with their own ids (TMDB's "tmdb:…") wait
    /// for the meta and use its IMDb id.
    private var streamId: String? {
        guard let raw = isSeries ? selectedVideo?.id : preview.id else { return nil }
        if raw.hasPrefix("tt") { return raw }
        guard let meta else { return nil }
        return meta.streamID(for: raw)
    }
    /// Streams are being fetched for something (not just "nothing picked yet").
    private var findingStreams: Bool { loadingStreams && streamId != nil }

    /// A stream's label quality, corrected by measured specs when available.
    private func effective(_ s: AddonStream) -> StreamQuality {
        measured[s.id].map { s.quality.merged(with: $0) } ?? s.quality
    }
    /// Best-quality stream Apple's player is expected to open directly.
    private var bestPlayable: AddonStream? {
        groups.flatMap(\.streams)
            .filter { $0.url != nil && $0.likelyNative != false }
            .max { a, b in
                let na = a.likelyNative == true, nb = b.likelyNative == true
                return na != nb ? !na : effective(a) < effective(b)
            }
    }
    /// Auto-play order: streams Apple's player opens first (best quality first), then the ones mpv
    /// plays, best first. Play checks them in this order and starts the first that responds.
    private var playCandidates: [AddonStream] {
        let all = groups.flatMap(\.streams).filter { $0.url != nil }
        let native = all.filter { $0.likelyNative != false }
            .sorted { a, b in
                let na = a.likelyNative == true, nb = b.likelyNative == true
                return na != nb ? na : effective(b) < effective(a)
            }
        let mpv = all.filter { $0.likelyNative == false }.sorted { a, b in effective(b) < effective(a) }
        return native + mpv
    }

    @MainActor private func autoPlay() {
        let ordered = Array(playCandidates.prefix(24))
        let candidates = ordered.compactMap { s in
            s.url.flatMap(URL.init(string:)).map { SourceCheck.Candidate(id: s.id, url: $0, headers: s.requestHeaders) }
        }
        guard !candidates.isEmpty else { return }
        probeToken = nil   // stop background measuring; it competes with the check
        checkingSources = (0, candidates.count)
        autoPlayTask = Task { @MainActor in
            let found = await SourceCheck.firstAvailable(candidates) { done in
                await MainActor.run { if checkingSources != nil { checkingSources = (done, candidates.count) } }
            }
            guard !Task.isCancelled else { return }
            checkingSources = nil
            if let id = found, let s = ordered.first(where: { $0.id == id }) { play(s) }
            else { noSourceResponded = true }
        }
    }

    private var bestOverall: AddonStream? { groups.flatMap(\.streams).max { effective($0) < effective($1) } }
    private var runtimeMinutes: Double? {
        (meta?.runtime).flatMap { r in Double(r.prefix { $0.isNumber }) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero(proxy)
                    VStack(alignment: .leading, spacing: 40) {
                        if isSeries {
                            let last = library.items[preview.id]
                            EpisodesSection(episodesBySeason: info?.episodesBySeason ?? [:],
                                            seasons: info?.seasons ?? [],
                                            season: $season,
                                            selectedId: selectedVideo?.id,
                                            lastVideoId: last?.lastVideoId,
                                            lastProgress: last?.progress ?? 0,
                                            isLoading: meta == nil,
                                            select: { ep in
                                                withAnimation(DetailMotion.select(reduceMotion)) { selectedVideo = ep }
                                            })
                        }
                        streamList.id("streams")
                        // Info sits below the streams and animates in on its own, so the
                        // streams table above never moves or animates when the meta arrives.
                        VStack(alignment: .leading, spacing: 40) {
                            if let info {
                                if !info.people.isEmpty {
                                    CastCrewSection(people: info.people)
                                        .transition(DetailMotion.rise(reduceMotion))
                                }
                                if !info.facts.isEmpty || info.imdb != nil {
                                    InformationSection(facts: info.facts, imdb: info.imdb)
                                        .transition(DetailMotion.rise(reduceMotion))
                                }
                            }
                        }
                        .animation(DetailMotion.reveal(reduceMotion), value: info != nil)
                    }
                    .padding(.horizontal, 48)
                    .padding(.vertical, 32)
                }
            }
            // On the scroll view itself (as on Home): otherwise it insets its content by the toolbar
            // height and the window background shows as a band above the art, under the back button.
            .ignoresSafeArea(edges: .top)
        }
        .ignoresSafeArea(edges: .top)
        .staysClearOfSidebar()
        .fullBleedChrome()
        .navigationTitle(meta?.name ?? preview.name)
        .navigationSubtitle(meta?.releaseInfo ?? preview.releaseInfo ?? "")
        .toolbar {
            if let link = info?.imdb {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: link, subject: Text(meta?.name ?? preview.name)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .help("Share \(meta?.name ?? preview.name)")
                }
            }
        }
        .task { await loadMeta() }
        .task(id: streamId) { await loadStreams() }
        // Separate task so opening the player cancels the probes (they'd compete with playback).
        .task(id: probeToken) { if probeToken != nil { await measureTopStreams() } }
    }

    // MARK: Hero

    private var backdrop: URL? {
        meta?.background.flatMap(URL.init(string:)) ?? preview.backdropURL
    }
    private var logo: URL? { meta?.logo.flatMap(URL.init(string:)) ?? preview.logoURL }

    private func hero(_ proxy: ScrollViewProxy) -> some View {
        ZStack(alignment: .bottomLeading) {
            Artwork(url: backdrop)
                .frame(maxWidth: .infinity)
                .frame(height: 620)
                .clipped()
                .overlay(ArtworkScrim())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 14) {
                TitleLogo(url: logo, name: meta?.name ?? preview.name, maxHeight: 130)
                    .accessibilityAddTraits(.isHeader)
                if let info {
                    HeroFacts(score: info.score, certification: info.certification, year: info.year,
                              runtime: info.runtime, genres: info.genres)
                        .transition(DetailMotion.rise(reduceMotion))
                } else {
                    HeroFacts(score: nil, certification: nil, year: preview.releaseInfo, runtime: nil, genres: [])
                }
                if let best = bestOverall, best.quality.isKnown {
                    HeroQualityLine(quality: effective(best))
                        .transition(.opacity)
                }
                if let d = meta?.description ?? preview.description {
                    ExpandableText(text: d, lineLimit: 2)
                        .font(.body).foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: 600, alignment: .leading)
                }
                if let awards = info?.awards {
                    AwardsLine(text: awards)
                        .transition(DetailMotion.rise(reduceMotion))
                }
                HStack(spacing: 12) {
                    if let r = resume {
                        resumeButtons(r)
                    } else {
                        playButton(proxy)
                    }
                    if let trailer = info?.trailer ?? addonTrailer {
                        Button("Trailer", systemImage: "play.rectangle") { openURL(trailer) }
                            .nativeButtonStyle()
                            .controlSize(.extraLarge)
                            .detailGlassID("trailer", in: glass)
                            .help("Watch the trailer on YouTube")
                            .accessibilityHint("Opens YouTube in your browser")
                            .transition(.opacity)
                    }
                    let saved = library.isSaved(preview.id)
                    Button(saved ? "In Library" : "Add to Library", systemImage: saved ? "checkmark" : "plus") {
                        withAnimation(DetailMotion.select(reduceMotion)) { library.toggleSaved(meta?.preview ?? preview) }
                    }
                    .labelStyle(.iconOnly)
                    .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                    .circleGlassButton()
                    .controlSize(.extraLarge)
                    .detailGlassID("library", in: glass)
                    .help(saved ? "Remove from Library" : "Add to Library")
                }
                .glassGroup()
                .padding(.top, 6)
                if let r = resume {
                    ResumeProgress(item: r.item, episode: r.episodeLabel)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 48)
            .padding(.bottom, 44)
            .environment(\.colorScheme, .dark)
            // Meta-only rows (rating, awards, trailer) fade and rise in as the meta arrives.
            .animation(DetailMotion.reveal(reduceMotion), value: info != nil)
            .animation(DetailMotion.reveal(reduceMotion), value: bestPlayable?.id)
            .opacity(heroShown ? 1 : 0)
            .offset(y: heroShown || reduceMotion ? 0 : 18)
            .onAppear {
                withAnimation(reduceMotion ? .easeOut(duration: 0.25) : .smooth(duration: 0.7)) { heroShown = true }
            }

            // "Starring … / Director …" at the bottom right, like the TV app; only when it won't
            // crowd the left column.
            if heroWidth > 1050, let info, let credits = HeroCredits(people: info.people) {
                credits
                    .frame(maxWidth: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 48)
                    .padding(.bottom, 52)
                    .environment(\.colorScheme, .dark)
                    .transition(.opacity)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { heroWidth = $0 }
        .animation(DetailMotion.reveal(reduceMotion), value: info != nil)
    }

    @ViewBuilder private func playButton(_ proxy: ScrollViewProxy) -> some View {
        let episodeLabel = isSeries ? selectedVideo.map { " S\($0.season ?? 0), E\($0.episode ?? 0)" } ?? "" : ""
        if let checking = checkingSources {
            Button { autoPlayTask?.cancel(); autoPlayTask = nil; checkingSources = nil } label: {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking Sources… \(checking.done)/\(checking.total)").monospacedDigit()
                }
                .padding(.horizontal, 10)
            }
            .nativeButtonStyle(prominent: true)
            .controlSize(.extraLarge)
            .detailGlassID("play", in: glass)
            .help("Click to stop checking")
        } else if let s = playCandidates.first {
            Button { autoPlay() } label: {
                Label("Play\(episodeLabel)", systemImage: "play.fill").padding(.horizontal, 10)
            }
            .nativeButtonStyle(prominent: true)
            .controlSize(.extraLarge)
            .detailGlassID("play", in: glass)
            .keyboardShortcut(.space, modifiers: [])
            .help("Plays the best source that responds" + (s.quality.tags.isEmpty ? "" : ", starting with " + s.quality.tags.joined(separator: " · ")))
            .alert("No Source Responded", isPresented: $noSourceResponded) {
                Button("Show Streams") { withAnimation(reduceMotion ? nil : .smooth) { proxy.scrollTo("streams", anchor: .top) } }
                Button("OK", role: .cancel) {}
            } message: {
                Text("None of the \(playCandidates.count) sources answered. They may have expired; try again later or pick one from the list.")
            }
        } else {
            Button {
                withAnimation(reduceMotion ? nil : .smooth) { proxy.scrollTo("streams", anchor: .top) }
            } label: {
                if findingStreams {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Finding Streams…") }
                        .padding(.horizontal, 10)
                } else {
                    Label("Choose a Stream", systemImage: "list.bullet").padding(.horizontal, 10)
                }
            }
            .nativeButtonStyle(prominent: true)
            .controlSize(.extraLarge)
            .detailGlassID("play", in: glass)
            .disabled(findingStreams || (isSeries && selectedVideo == nil))
        }
    }

    // MARK: Streams

    @ViewBuilder private var streamList: some View {
        if isSeries && selectedVideo == nil && meta != nil {
            ContentUnavailableView("Pick an Episode", systemImage: "list.bullet.rectangle",
                                   description: Text("Choose an episode above to see its streams."))
        } else {
            if !watchLinks.isEmpty { WatchLinksRow(links: watchLinks) }
            StreamsSection(groups: groups, loading: loadingStreams || (isSeries && meta == nil), measured: measured,
                           runtimeMinutes: runtimeMinutes,
                           bestNativeId: bestPlayable?.id,
                           play: play)
        }
    }

    @MainActor private func play(_ s: AddonStream) {
        // A playable stream always plays; a link-out opens in the browser (http(s) only, see WebURL).
        if s.url == nil, let ext = s.externalUrl, let u = URL(string: ext), WebURL.isAllowed(u) {
            NSWorkspace.shared.open(u); return
        }
        guard let url = s.url, let videoId = streamId else { return }
        let resumeOn = UserDefaults.standard.object(forKey: Prefs.resume) as? Bool ?? true
        let addon = groups.first { $0.streams.contains { $0.id == s.id } }?.addon
        openPlayer(SavedSource(url: url, headers: s.requestHeaders, addonId: addon?.id ?? "",
                               addonName: addon?.manifest.name ?? "", name: s.name, label: s.label, videoId: videoId),
                   episode: selectedVideo,
                   startAt: resumeOn ? library.resumePosition(titleId: preview.id, videoId: videoId) : 0)
    }

    /// Opens the player and remembers the source, so Resume can continue on it later.
    @MainActor private func openPlayer(_ source: SavedSource, episode: Video?, startAt: Double) {
        let sub = isSeries ? "S\(episode?.season ?? 0)E\(episode?.episode ?? 0) · \(episode?.title ?? "")" : ""
        probeToken = nil
        library.rememberSource(source, for: meta?.preview ?? preview)
        openWindow(value: PlayRequest(
            url: source.url, headers: source.headers, titleId: preview.id, videoId: source.videoId, type: preview.type,
            titleName: meta?.name ?? preview.name, subtitle: sub, poster: meta?.poster ?? preview.poster,
            startAt: startAt))
    }

    // MARK: Resume

    struct ResumeState {
        let item: LibraryItem
        let source: SavedSource
        let episode: Video?
        var episodeLabel: String? { episode.map { "S\($0.season ?? 0), E\($0.episode ?? 0)" } }
    }

    /// In progress with a remembered source: the hero offers Resume instead of Play.
    private var resume: ResumeState? {
        guard let item = library.items[preview.id], item.isInProgress, let src = item.lastSource,
              src.videoId == item.lastVideoId else { return nil }
        return ResumeState(item: item, source: src, episode: isSeries ? episodes.first { $0.id == src.videoId } : nil)
    }

    /// Same stream as last time. Prefer the add-on's fresh copy (links with expiring tokens get
    /// re-issued): same URL, else same add-on + name + label. Otherwise the saved link itself.
    private func freshSource(for saved: SavedSource) -> SavedSource {
        guard saved.videoId == streamId else { return saved }   // list on screen is for another episode
        for g in groups where g.addon.id == saved.addonId || saved.addonId.isEmpty {
            if let s = g.streams.first(where: { $0.url == saved.url })
                ?? g.streams.first(where: { $0.name == saved.name && $0.label == saved.label }),
               let url = s.url {
                return SavedSource(url: url, headers: s.requestHeaders, addonId: g.addon.id, addonName: g.addon.manifest.name,
                                   name: s.name, label: s.label, videoId: saved.videoId)
            }
        }
        return saved
    }

    @ViewBuilder private func resumeButtons(_ r: ResumeState) -> some View {
        Button {
            openPlayer(freshSource(for: r.source), episode: r.episode, startAt: r.item.position)
        } label: {
            Label("Resume" + (r.episodeLabel.map { " \($0)" } ?? ""), systemImage: "play.fill").padding(.horizontal, 10)
        }
        .nativeButtonStyle(prominent: true)
        .controlSize(.extraLarge)
        .detailGlassID("play", in: glass)
        .keyboardShortcut(.space, modifiers: [])
        .help("Continue on \((r.source.name ?? r.source.addonName).withoutEmoji)" + (r.source.label.isEmpty ? "" : " · " + r.source.label.withoutEmoji.prefix(80)))

        Button("Start Over", systemImage: "arrow.counterclockwise") {
            openPlayer(freshSource(for: r.source), episode: r.episode, startAt: 0)
        }
        .labelStyle(.iconOnly)
        .circleGlassButton()
        .controlSize(.extraLarge)
        .detailGlassID("startOver", in: glass)
        .help("Start over on the same source")
    }

    @MainActor private func loadMeta() async {
        let m = await store.client.meta(from: store.addons, type: preview.type, id: preview.id)
        meta = m
        info = m.map(TitleInfo.init)
        if isSeries {
            season = seasons.first ?? 1
            // Resume where you left off, else first episode.
            let last = library.items[preview.id]?.lastVideoId
            selectedVideo = episodes.first { $0.id == last } ?? episodes.first { $0.season == season }
            if let s = selectedVideo?.season { season = s }
        }
    }

    /// Reads real specs for the strongest native candidates: one small playlist GET each for HLS,
    /// AVFoundation track data for MP4. Capped so opening a title stays light on the network.
    @MainActor private func measureTopStreams() async {
        let ranked = groups.flatMap(\.streams)
            .filter { $0.url != nil && $0.likelyNative != false && measured[$0.id] == nil }
            .sorted { $0.quality > $1.quality }
        // HLS is one small playlist GET; progressive files need AVFoundation reads, so only a few.
        let isHLS = { (s: AddonStream) in s.url?.lowercased().contains(".m3u8") == true }
        let candidates = Array(ranked.filter(isHLS).prefix(12)) + Array(ranked.filter { !isHLS($0) }.prefix(3))
        await withTaskGroup(of: (String, ProbeResult).self) { group in
            var pending = Array(candidates)
            func next() {
                guard !pending.isEmpty else { return }
                let s = pending.removeFirst()
                guard let raw = s.url, let u = URL(string: raw) else { return next() }
                let headers = s.requestHeaders
                group.addTask { (s.id, await PlaybackProbe.measure(url: u, headers: headers)) }
            }
            for _ in 0..<4 { next() }   // four at a time
            for await (id, r) in group {
                if Task.isCancelled { group.cancelAll(); break }
                if r.measuredFrom != nil { measured[id] = r }
                next()
            }
        }
    }

    @MainActor private func loadStreams() async {
        guard let id = streamId else { return }
        autoPlayTask?.cancel(); autoPlayTask = nil; checkingSources = nil
        groups = []
        watchLinks = []
        addonTrailer = nil
        loadingStreams = true
        let client = store.client
        let addons = store.addons
        let type = preview.type
        let stream = AsyncStream<StreamGroup> { cont in
            let task = Task {
                await client.streams(from: addons, type: type, id: id) { cont.yield($0) }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }   // leaving the page stops the add-on requests
        }
        for await g in stream {
            // Links out (externalUrl, e.g. "Open in Netflix") and YouTube trailers (ytId) aren't
            // playable streams: they get their own buttons instead of table rows. Add-ons that also
            // return playable streams use link-outs for promos, so only link-only add-ons get
            // "Open In" buttons. Duplicate links are dropped (ForEach identity must be unique).
            let linkOnly = !g.streams.contains { $0.url != nil }
            for s in g.streams where s.url == nil {
                if linkOnly, let ext = s.externalUrl, let u = URL(string: ext), WebURL.isAllowed(u), watchLinks.count < 8 {
                    watchLinks.append(WatchLink(title: (s.name ?? s.title ?? g.addon.manifest.name).withoutEmoji, url: u))
                } else if addonTrailer == nil, let yt = s.ytId {
                    addonTrailer = Trailer(title: s.title, ytId: yt).youTubeURL
                }
            }
            var seen = Set<String>()
            let playable = g.streams.filter { $0.url != nil && seen.insert($0.id).inserted }
            groups.append(StreamGroup(addon: g.addon, streams: playable, error: g.error))
        }
        loadingStreams = false
        if !Task.isCancelled { probeToken = UUID() }
    }
}

/// One row of the streams table. Quality is the label corrected by measured specs, and every
/// sort key is precomputed so sorting never re-parses labels.
struct StreamTableRow: Identifiable {
    let stream: AddonStream
    let addon: String
    let addonId: String
    let quality: StreamQuality
    let measured: ProbeResult?
    let bitrate: (mbps: Double, estimated: Bool)?

    var id: String { stream.id }
    var name: String { (stream.name ?? addon).withoutEmoji }
    var label: String { stream.label.withoutEmoji }
    var score: Int { quality.score }
    var videoScore: Int { quality.videoScore }
    var audioScore: Int { quality.audioScore }
    var mbps: Double { bitrate?.mbps ?? 0 }
    var sizeGB: Double { quality.sizeGB ?? 0 }
    /// 0 = opens in Apple's player, 1 = unknown, 2 = needs mpv.
    var nativeRank: Int { stream.likelyNative == true ? 0 : (stream.likelyNative == nil ? 1 : 2) }
    /// The label promised more channels than the stream declares (e.g. "5.1" that is really stereo).
    var audioOverstated: String? {
        guard measured?.channels != nil, let claimed = stream.quality.channels, let real = quality.channels,
              claimed != real, (Double(claimed) ?? 0) > (Double(real) ?? 0) else { return nil }
        return "Labelled \(claimed), but the stream declares \(real)"
    }
}

/// The detail page's streams: a native Table (sortable headers, selection,
/// double-click or Return to play, right-click menu), like Finder or Music.
struct StreamsSection: View {
    let groups: [StreamGroup]
    let loading: Bool
    let measured: [String: ProbeResult]
    let runtimeMinutes: Double?
    let bestNativeId: String?
    let play: (AddonStream) -> Void

    @State private var sortOrder = [KeyPathComparator(\StreamTableRow.score, order: .reverse)]
    @State private var selection: StreamTableRow.ID?
    @AppStorage(Prefs.nativeOnly) private var nativeOnly = false
    /// nil shows every add-on's streams.
    @State private var addonFilter: String?

    /// Add-ons that returned streams, in the user's add-on order.
    private var sources: [(id: String, name: String, count: Int)] {
        groups.filter { !$0.streams.isEmpty }.map { ($0.addon.id, $0.addon.manifest.name, $0.streams.count) }
    }

    private func makeRows() -> [StreamTableRow] {
        groups.flatMap { g in
            g.streams.map { s in
                let m = measured[s.id]
                let q = m.map { s.quality.merged(with: $0) } ?? s.quality
                return StreamTableRow(stream: s, addon: g.addon.manifest.name, addonId: g.addon.id, quality: q, measured: m,
                                      bitrate: q.estimatedMbps(runtimeMinutes: runtimeMinutes))
            }
        }
    }

    var body: some View {
        let filter = sources.contains { $0.id == addonFilter } ? addonFilter : nil
        let all = makeRows().filter { filter == nil || $0.addonId == filter }
        let rows = all.filter { !nativeOnly || $0.nativeRank < 2 }.sorted(using: sortOrder)
        let known = all.filter { $0.quality.isKnown }
        let best = Bests(
            overall: known.max { $0.quality < $1.quality }?.id,
            video: known.max { ($0.videoScore, $0.mbps) < ($1.videoScore, $1.mbps) }?.id,
            audio: known.filter { $0.audioScore > 0 }
                .max { ($0.audioScore, $0.quality.audioKbps ?? 0) < ($1.audioScore, $1.quality.audioKbps ?? 0) }?.id,
            native: bestNativeId)

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Streams").detailSectionHeader()
                if loading { ProgressView().controlSize(.small) }
                else { Text("\(rows.count)").foregroundStyle(.secondary).monospacedDigit() }
                if !measured.isEmpty {
                    Label("\(measured.count) measured", systemImage: "checkmark.circle")
                        .font(.callout).foregroundStyle(.secondary)
                        .help("Specs read from the stream itself (HLS playlist or media tracks), not just its label")
                }
                Spacer()
                if sources.count > 1 {
                    Picker("Add-on", selection: $addonFilter) {
                        Text("All Add-ons").tag(String?.none)
                        Divider()
                        ForEach(sources, id: \.id) { src in
                            Text("\(src.name) (\(src.count))").tag(Optional(src.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .help("Show streams from one add-on")
                }
                Toggle("Native only", isOn: $nativeOnly)
                    .toggleStyle(.checkbox)
                    .help("Hide MKV and other streams Apple's player can't open yet")
            }

            if rows.isEmpty && !loading {
                ContentUnavailableView("No Streams Found", systemImage: "play.slash",
                                       description: Text(filter != nil ? "This add-on has no matching streams. Choose “All Add-ons”."
                                                          : nativeOnly ? "Turn off “Native only” to see every stream."
                                                                       : "Add a stream add-on in Settings (⌘,)."))
                    .frame(maxWidth: .infinity)
            } else {
                table(rows, best: best)
                    .frame(height: min(CGFloat(max(rows.count, 4)) * 46 + 30, 600))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
            }

            ForEach(groups.filter { $0.error != nil }) { g in
                Label("\(g.addon.manifest.name): \(g.error ?? "")", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    struct Bests { let overall, video, audio, native: String? }

    private func table(_ rows: [StreamTableRow], best: Bests) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Stream", value: \.score) { r in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        if r.id == best.overall {
                            Image(systemName: "star.fill").foregroundStyle(.yellow)
                                .help("Best quality overall").accessibilityLabel("Best quality")
                        } else if r.id == best.native {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                                .help("Best stream Apple's player can open").accessibilityLabel("Best native")
                        }
                        Text(r.name).fontWeight(.medium).lineLimit(1)
                    }
                    Text(r.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .help(r.label)
            }
            .width(min: 180, ideal: 260)

            TableColumn("Video", value: \.videoScore) { r in
                SpecCell(tags: r.quality.videoTags, isBest: r.id == best.video, bestLabel: "Best video",
                         bestColor: .purple, measured: r.measured?.videoCodec != nil ? r.measured?.measuredFrom : nil)
            }
            .width(min: 180, ideal: 260)

            TableColumn("Audio", value: \.audioScore) { r in
                SpecCell(tags: r.quality.audioTags, isBest: r.id == best.audio, bestLabel: "Best audio",
                         bestColor: .teal, measured: r.measured?.audioCodec != nil ? r.measured?.measuredFrom : nil,
                         warning: r.audioOverstated)
            }
            .width(min: 150, ideal: 210)

            TableColumn("Bitrate", value: \.mbps) { r in
                if let b = r.bitrate {
                    HStack(spacing: 3) {
                        Text((b.estimated ? "~" : "") + b.mbps.formatted(.number.precision(.fractionLength(1))) + " Mbps")
                            .monospacedDigit()
                        if r.measured?.videoKbps != nil {
                            Image(systemName: "checkmark.circle").foregroundStyle(.secondary).imageScale(.small)
                        }
                    }
                    .help(r.measured?.videoKbps != nil ? "Average bitrate measured from the stream"
                          : b.estimated ? "Estimated: file size ÷ runtime" : "As labelled by the add-on")
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .width(min: 80, ideal: 95, max: 120)

            TableColumn("Size", value: \.sizeGB) { r in
                Text(r.quality.sizeGB.map { $0.formatted(.number.precision(.fractionLength($0 < 10 ? 1 : 0))) + " GB" } ?? "—")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 55, ideal: 65, max: 85)

            TableColumn("Format", value: \.nativeRank) { r in
                FormatBadge(stream: r.stream)
            }
            .width(min: 65, ideal: 75, max: 95)

            TableColumn("Add-on", value: \.addon) { r in
                Text(r.addon).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(r.addon)
            }
            .width(min: 96, ideal: 120, max: 180)
        }
        .contextMenu(forSelectionType: StreamTableRow.ID.self) { ids in
            if let r = rows.first(where: { ids.contains($0.id) }) {
                Button(r.stream.externalUrl != nil ? "Open in Browser" : "Play", systemImage: "play.fill") { play(r.stream) }
            }
        } primaryAction: { ids in
            // Double-click or Return plays, as in any Mac list.
            if let r = rows.first(where: { ids.contains($0.id) }) { play(r.stream) }
        }
    }
}

/// One spec column: optional "Best …" badge, compact chips, a ✓ when measured, ⚠ when the label overstates.
struct SpecCell: View {
    let tags: [String]
    var isBest = false
    var bestLabel = ""
    var bestColor: Color = .accentColor
    var measured: String?
    var warning: String?

    var body: some View {
        HStack(spacing: 4) {
            if isBest {
                Label(bestLabel, systemImage: "crown.fill").tagStyle(bestColor)
            }
            if tags.isEmpty {
                Text("—").foregroundStyle(.secondary)
            } else {
                Text(tags.joined(separator: " · ")).font(.callout).lineLimit(1)
            }
            if let warning {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(warning)
                    .accessibilityLabel(warning)
            } else if let measured {
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary).imageScale(.small)
                    .help("Measured from the \(measured)").accessibilityLabel("Measured")
            }
        }
        .help(tags.joined(separator: " · "))
    }
}

/// NATIVE (Apple's player opens it) vs the container that needs mpv.
struct FormatBadge: View {
    let stream: AddonStream
    var body: some View {
        switch stream.likelyNative {
        case .some(true): Text("NATIVE").badgeStyle(.green).help("Plays in Apple's player")
        case .some(false): Text(stream.container.uppercased()).badgeStyle(.orange).help("Plays in mpv")
        case .none: Text("—").foregroundStyle(.secondary)
        }
    }
}


/// TV-style format line under the title: "4K  Dolby Vision  Dolby Atmos".
struct HeroQualityLine: View {
    let quality: StreamQuality
    var body: some View {
        let items = [quality.resolution.label, quality.hdr.first?.rawValue,
                     quality.audio.contains("Atmos") ? "Dolby Atmos" : quality.audio.first,
                     quality.channels].compactMap { $0 }
        HStack(spacing: 6) {
            ForEach(items, id: \.self) { t in
                Text(t).font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(.white.opacity(0.6), lineWidth: 1))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Available in " + items.joined(separator: ", "))
    }
}

/// Colored quality chips: resolution, HDR, source, codec, audio, channels, size.
struct QualityTags: View {
    let quality: StreamQuality
    var isBest = false
    var isBestNative = false
    var showSize = true

    var body: some View {
        FlowLayout(spacing: 4) {
            if isBest { Label("Best quality", systemImage: "star.fill").tagStyle(.yellow) }
            if isBestNative { Label("Best native", systemImage: "checkmark.seal.fill").tagStyle(.green) }
            if let r = quality.resolution.label { Text(r).tagStyle(quality.resolution >= .uhd ? .indigo : .blue) }
            ForEach(quality.hdr, id: \.self) { Text($0.rawValue).tagStyle(.purple) }
            if let s = quality.source { Text(s.rawValue).tagStyle(s == .cam ? .red : .gray) }
            if let c = quality.videoCodec { Text(quality.tenBit ? "\(c) 10-bit" : c).tagStyle(.gray) }
            ForEach(quality.audio, id: \.self) { Text($0).tagStyle(.teal) }
            if let ch = quality.channels { Text(ch).tagStyle(.teal) }
            if showSize, let gb = quality.sizeGB {
                Text(gb.formatted(.number.precision(.fractionLength(gb < 10 ? 1 : 0))) + " GB").tagStyle(.gray)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Wraps chips onto new lines instead of truncating them.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, p) in rows(bounds.width, subviews).origins.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }

    private func rows(_ maxWidth: CGFloat, _ subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, width: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth { x = 0; y += lineHeight + spacing; lineHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            width = max(width, x - spacing)
        }
        return (origins, CGSize(width: width, height: y + lineHeight))
    }
}

private extension View {
    func tagStyle(_ color: Color) -> some View {
        font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule()).foregroundStyle(color)
            .labelStyle(.titleAndIcon)
    }
}

private extension Text {
    func badgeStyle(_ color: Color) -> some View {
        font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 3)
            .background(color.opacity(0.2), in: Capsule()).foregroundStyle(color)
    }
}

/// TV-style progress under Resume: a thin bar and "42 min left".
struct ResumeProgress: View {
    let item: LibraryItem
    let episode: String?

    private var remaining: String {
        let left = max(0, item.duration - item.position)
        let f = DateComponentsFormatter()
        f.allowedUnits = left >= 3600 ? [.hour, .minute] : [.minute]
        f.unitsStyle = .short
        return (f.string(from: left) ?? "") + " left"
    }

    var body: some View {
        HStack(spacing: 10) {
            ProgressView(value: item.progress)
                .progressViewStyle(.linear)
                .tint(.white)
                .frame(width: 140)
            Text([episode, remaining, item.lastSource?.addonName].compactMap { $0 }.filter { !$0.isEmpty }
                .joined(separator: " · "))
                .font(.callout.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Int((item.progress * 100).rounded())) percent watched, \(remaining)")
    }
}

/// An add-on's link out to another app or site (externalUrl streams).
struct WatchLink: Identifiable, Hashable {
    let title: String
    let url: URL
    var id: URL { url }
}

/// "Open In" buttons for links out, shown above the stream table instead of as rows.
struct WatchLinksRow: View {
    let links: [WatchLink]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Open In").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(links) { link in
                        Link(destination: link.url) {
                            Label(link.title, systemImage: "arrow.up.forward.app").lineLimit(1)
                        }
                        .nativeButtonStyle()
                        .help("Open \(link.title)")
                    }
                }
                .scrollTargetLayout()
                .glassGroup()
            }
            .shelfPaging(ids: links.map(\.id), step: 150)
        }
        .padding(.bottom, 8)
    }
}

/// The TV app's credits block: "Starring A, B, C" and "Director D", secondary label + names.
struct HeroCredits: View {
    let starring: [String]
    let directors: [String]

    init?(people: [TitleInfo.Person]) {
        starring = Array(people.filter { $0.roles.contains(.cast) }.prefix(3).map(\.name))
        directors = Array(people.filter { $0.roles.contains(.director) }.prefix(2).map(\.name))
        if starring.isEmpty && directors.isEmpty { return nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !starring.isEmpty { line("Starring", starring) }
            if !directors.isEmpty { line(directors.count > 1 ? "Directors" : "Director", directors) }
        }
        .font(.callout)
        .frame(maxWidth: 300, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func line(_ label: LocalizedStringKey, _ names: [String]) -> some View {
        (Text(label).foregroundStyle(.white.opacity(0.6)) + Text(" ") +
         Text(names.formatted(.list(type: .and))).foregroundStyle(.white.opacity(0.92)))
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}
