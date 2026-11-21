import SwiftUI
import AddonKit

struct CatalogRowModel: Identifiable {
    let id: String
    let title: String
    var items: [MetaPreview]
}

struct HomeView: View {
    /// nil = everything (Home); "movie" / "series" = the Movies / TV Shows pages.
    var type: String? = nil
    var title: String = "Home"
    @Environment(AddonStore.self) private var store
    @Environment(LibraryStore.self) private var library
    @State private var rows: [CatalogRowModel] = []
    @State private var loading = false
    @State private var reloadToken = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The first shelf's top titles fill the hero, like a TV app's featured shelf. Trending Now is the
    /// first shelf whenever an add-on offers it, so the hero prefers trending titles; while it loads the
    /// hero holds its placeholder rather than showing another catalog and then swapping.
    private var featured: [MetaPreview] { Array((rows.first?.items ?? []).prefix(6)) }

    private var showsHero: Bool { !featured.isEmpty || (loading && !rows.isEmpty) }

    private var genres: [String] { type.map { GenreCatalogs.genres(in: store.addons, type: $0) } ?? [] }

    /// No add-on offers a trending catalog for this page, so it can suggest one.
    private var lacksTrending: Bool { Trending.catalogs(in: store.addons, type: type).isEmpty }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 36) {
                if showsHero {
                    // One slot, so the placeholder and the hero crossfade in place without a layout jump.
                    ZStack {
                        if featured.isEmpty {
                            HeroPlaceholder().transition(.opacity)
                        } else {
                            FeaturedHero(items: featured).transition(.opacity)
                        }
                    }
                }
                if let type, !genres.isEmpty {
                    GenreChips(type: type, genres: genres)
                        .padding(.top, showsHero ? -12 : 64)   // without a hero, clear of the toolbar
                }
                if !loading && !rows.isEmpty && lacksTrending {
                    TrendingHint().transition(.opacity)
                }
                let continueWatching = library.continueWatching
                if type == nil && !continueWatching.isEmpty {
                    ShelfHeader(title: "Continue Watching")
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 18) {
                            ForEach(continueWatching) { item in
                                NavigationLink(value: item.preview) {
                                    LandscapeCard(item: item.preview, progress: item.progress)
                                }
                                .buttonStyle(.card)
                            }
                        }
                        .scrollTargetLayout()
                        .padding(.horizontal, 32)
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .shelfPaging(ids: continueWatching.map(\.id), step: 300 + 18)
                    .padding(.top, -24)
                }
                ForEach(rows) { row in
                    PosterRow(title: row.title, items: row.items, showsPlaceholder: loading)
                        .transition(.opacity)
                }
                if rows.isEmpty && !loading {
                    ContentUnavailableView("No catalogs yet", systemImage: "puzzlepiece.extension",
                                           description: Text("Add an add-on with catalogs in Settings (⌘,). Cinemeta, TMDB and OpenSubtitles install on first launch."))
                        .padding(.top, 120)
                        .transition(.opacity)
                }
            }
            .padding(.bottom, 36)
        }
        .ignoresSafeArea(edges: .top)
        .staysClearOfSidebar()
        .fullBleedChrome()
        .overlay { if loading && rows.isEmpty { ProgressView() } }
        .navigationTitle(title)
        .navigationDestination(for: GenreRoute.self) { GenreView(route: $0) }
        // No toolbar items: like the TV app, the art runs to the top edge. Reload is View ▸ Reload (⌘R).
        .focusedSceneValue(\.reload, ReloadAction { reloadToken += 1 })
        .task(id: HomeLoadKey(catalogs: CatalogKey.lineup(store.addons), token: reloadToken)) { await load() }
    }

    @MainActor private func load() async {
        loading = true
        defer { loading = false }
        let trending = Trending.catalogs(in: store.addons, type: type)
        let trendingKeys = Set(trending.map { CatalogKey($0.0, $0.1).id })
        // Build the row order first, then fill rows in parallel as each catalog answers.
        var order: [(InstalledAddon, CatalogDef)] = []
        for a in store.addons {
            for c in a.manifest.catalogs ?? [] where c.isBrowsable && (type == nil || c.type == type)
                && !trendingKeys.contains(CatalogKey(a, c).id) {
                order.append((a, c))
            }
        }
        var model = trending.isEmpty ? [] : [CatalogRowModel(id: Trending.rowId, title: "Trending Now", items: [])]
        model += order.map { a, c in
            CatalogRowModel(id: CatalogKey(a, c).id,
                            title: "\(c.name ?? c.id) \(c.type == "series" ? "Series" : c.type == "movie" ? "Movies" : c.type.capitalized)",
                            items: [])
        }
        rows = model
        let client = store.client
        var trendingParts: [String: [MetaPreview]] = [:]
        await withTaskGroup(of: (String, [MetaPreview]).self) { group in
            for (a, c) in trending + order {
                group.addTask {
                    let items = (try? await client.catalog(a, type: c.type, id: c.id)) ?? []
                    // Catalogs occasionally repeat a title; ForEach identity must be unique.
                    var seen = Set<String>()
                    return (CatalogKey(a, c).id, items.filter { seen.insert($0.id).inserted })
                }
            }
            for await (id, items) in group {
                if trendingKeys.contains(id) {
                    // Trending Now fills once, when every trending catalog has answered.
                    trendingParts[id] = items
                    guard trendingParts.count == trending.count else { continue }
                    let merged = Trending.merge(trending.map { trendingParts[CatalogKey($0.0, $0.1).id] ?? [] })
                    if let i = rows.firstIndex(where: { $0.id == Trending.rowId }) {
                        withAnimation(Motion.content(reduceMotion)) { rows[i].items = merged }
                    }
                    continue
                }
                // Each catalog fades in over its placeholder as it answers; a handful of updates, not a stream.
                if let i = rows.firstIndex(where: { $0.id == id }) {
                    withAnimation(Motion.content(reduceMotion)) { rows[i].items = items }
                }
            }
        }
        // Empty rows collapse; under Reduce Motion they go without the rows below sliding up.
        withAnimation(reduceMotion ? nil : Motion.content(false)) { rows.removeAll { $0.items.isEmpty } }
    }
}

private struct HomeLoadKey: Hashable {
    /// Add-on ids and their catalogs, so a manifest refresh that changes the lineup reloads the page,
    /// and one that only changes genre lists doesn't.
    let catalogs: [String]
    let token: Int
}

/// Stable identity for one add-on catalog ("addonId/type/catalogId").
struct CatalogKey {
    let id: String
    init(_ a: InstalledAddon, _ c: CatalogDef) { id = "\(a.id)/\(c.type)/\(c.id)" }

    static func lineup(_ addons: [InstalledAddon]) -> [String] {
        addons.flatMap { a in [a.id] + (a.manifest.catalogs ?? []).map { CatalogKey(a, $0).id } }
    }
}

// MARK: - Trending Now

/// Trending catalogs (TMDB "Trending", Kitsu "Kitsu Trending", …), found by id or name.
enum Trending {
    static let rowId = "trending-now"
    static let limit = 30

    /// Home (type nil) merges movies and series; Movies / TV Shows take their own type only.
    static func catalogs(in addons: [InstalledAddon], type: String?) -> [(InstalledAddon, CatalogDef)] {
        let types = type.map { [$0] } ?? ["movie", "series"]
        var out: [(InstalledAddon, CatalogDef)] = []
        for a in addons {
            for c in a.manifest.catalogs ?? [] where c.isBrowsable && types.contains(c.type) && isTrending(c) {
                out.append((a, c))
            }
        }
        // Movies first, so the merge starts with a movie and alternates from there.
        return out.enumerated().sorted { l, r in
            let li = types.firstIndex(of: l.element.1.type) ?? 0, ri = types.firstIndex(of: r.element.1.type) ?? 0
            return li != ri ? li < ri : l.offset < r.offset
        }.map(\.element)
    }

    static func isTrending(_ c: CatalogDef) -> Bool {
        c.id.localizedCaseInsensitiveContains("trending") || (c.name ?? "").localizedCaseInsensitiveContains("trending")
    }

    /// Round-robin across the lists (movie, series, movie…), first occurrence of each id wins.
    static func merge(_ lists: [[MetaPreview]]) -> [MetaPreview] {
        var out: [MetaPreview] = []
        var seen = Set<String>()
        let longest = lists.map(\.count).max() ?? 0
        for i in 0..<longest {
            for list in lists where i < list.count && seen.insert(list[i].id).inserted {
                out.append(list[i])
                if out.count == limit { return out }
            }
        }
        return out
    }
}

/// A quiet one-line suggestion when no installed add-on has a trending catalog.
private struct TrendingHint: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.line.uptrend.xyaxis").accessibilityHidden(true)
            Text("To see what's trending, add The Movie Database add-on.")
            SettingsLink { Text("Open Settings") }
                .buttonStyle(.link)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 32)
        .padding(.top, -12)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Featured hero

/// Full-bleed artwork that runs under the toolbar and sidebar, with floating glass controls.
struct FeaturedHero: View {
    let items: [MetaPreview]
    @Environment(LibraryStore.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var index = 0
    @State private var hovering = false
    @Namespace private var glass

    private var item: MetaPreview { items[min(index, items.count - 1)] }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ZStack {
                Rectangle().fill(.quaternary)
                // Each slide is its own view, so the outgoing art fades over the incoming art.
                HeroBackdrop(url: item.backdropURL, drifts: !reduceMotion,
                             anchor: index.isMultiple(of: 2) ? .topLeading : .bottomTrailing)
                    .id(item.id)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 560)
            .clipped()
            .overlay(ArtworkScrim())

            VStack(alignment: .leading, spacing: 18) {
                // Old and new info overlap here, so the swap never pushes the buttons around.
                ZStack(alignment: .bottomLeading) {
                    HeroInfo(item: item)
                        .id(item.id)
                        .transition(infoTransition)
                }
                buttons
            }
            .padding(.horizontal, 48)
            .padding(.bottom, 44)
            .environment(\.colorScheme, .dark)

            pageDots
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 48)
                .padding(.bottom, 52)
        }
        // Previous / next arrows on the edges while the pointer is over the banner, like the TV app.
        // They wrap around, so the banner reads as a loop.
        .overlay(alignment: .leading) { heroArrow(-1) }
        .overlay(alignment: .trailing) { heroArrow(1) }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
        .task(id: hovering || voiceOver || reduceMotion) {
            // Auto-advance like a featured shelf. It pauses while the pointer is over the hero, and it
            // warms the next slide's art first so the crossfade never fades into an empty frame.
            // Never moves on its own under VoiceOver or Reduce Motion (content would change under focus);
            // the page dots still switch slides.
            guard !hovering, !voiceOver, !reduceMotion, items.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(7))
                if Task.isCancelled { break }
                let next = (index + 1) % items.count
                async let warm: Void = Self.prefetch(items[next])
                try? await Task.sleep(for: .seconds(1))
                await warm
                if Task.isCancelled { break }
                show(next)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            NavigationLink(value: item) {
                Label("Watch Now", systemImage: "play.fill").padding(.horizontal, 8)
            }
            .nativeButtonStyle(prominent: true)
            .controlSize(.extraLarge)
            .glassID("watch", in: glass)

            let saved = library.isSaved(item.id)
            Button(saved ? "In Library" : "Add to Library", systemImage: saved ? "checkmark" : "plus") {
                withAnimation(.snappy) { library.toggleSaved(item) }
            }
            .labelStyle(.iconOnly)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, value: saved)   // completion feedback when it lands
            .circleGlassButton()
            .controlSize(.extraLarge)
            .glassID("library", in: glass)
            .help(saved ? "Remove from Library" : "Add to Library")
        }
        .glassGroup()
    }

    /// The new title fades in and rises once the old one has mostly faded, so the two never read on
    /// top of each other. Under Reduce Motion it only fades.
    private var infoTransition: AnyTransition {
        .asymmetric(insertion: Motion.rise(reduceMotion, by: 12).animation(.smooth(duration: 0.5).delay(0.2)),
                    removal: .opacity.animation(.easeOut(duration: 0.2)))
    }

    private func show(_ i: Int) {
        guard i != index, items.indices.contains(i) else { return }
        withAnimation(Motion.slide(reduceMotion)) { index = i }
    }

    private static func prefetch(_ item: MetaPreview) async {
        await withTaskGroup(of: Void.self) { group in
            for url in [item.backdropURL, item.logoURL].compactMap({ $0 }) {
                group.addTask { _ = try? await URLSession.shared.data(from: url) }
            }
        }
    }

    @ViewBuilder private func heroArrow(_ dir: Int) -> some View {
        if hovering && items.count > 1 {
            Button(dir < 0 ? "Previous" : "Next", systemImage: dir < 0 ? "chevron.left" : "chevron.right") {
                show((index + dir + items.count) % items.count)
            }
            .labelStyle(.iconOnly)
            .circleGlassButton()
            .controlSize(.extraLarge)
            .environment(\.colorScheme, .dark)
            .padding(.horizontal, 16)
            .help(dir < 0 ? "Previous title" : "Next title")
            .transition(.opacity)
        }
    }

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(items.indices, id: \.self) { i in
                Button { show(i) } label: {
                    Capsule().fill(.white.opacity(i == index ? 0.95 : 0.4))
                        .frame(width: i == index ? 18 : 7, height: 7)
                        .frame(minWidth: 20, minHeight: 20)   // comfortable click target around the dot
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show \(items[i].name)")
                .accessibilityAddTraits(i == index ? .isSelected : [])
            }
        }
        // Scoped to the dots: the active capsule stretches on its own spring, apart from the slow crossfade.
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0), value: index)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .glassSurface(Capsule())
        .opacity(items.count > 1 ? 1 : 0)
    }
}

/// A hero slide's backdrop. While the slide shows, the art drifts and zooms slowly (Ken Burns).
/// The drift is off under Reduce Motion.
private struct HeroBackdrop: View {
    let url: URL?
    let drifts: Bool
    let anchor: UnitPoint
    @State private var drifted = false

    var body: some View {
        AsyncImage(url: url, transaction: .init(animation: .easeOut(duration: 0.4))) { phase in
            if let img = phase.image { img.resizable().aspectRatio(contentMode: .fill) }
            else { Color.clear }
        }
        .scaleEffect(drifted ? 1.05 : 1, anchor: anchor)
        .onAppear { startDrift() }
        .onChange(of: drifts) {
            if drifts { startDrift() } else {
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { drifted = false }
            }
        }
    }

    private func startDrift() {
        guard drifts, !drifted else { return }
        // A single long animation, not a per-frame update. It runs past the slide interval so it never visibly stops.
        withAnimation(.easeInOut(duration: 10)) { drifted = true }
    }
}

/// Logo, year and synopsis for the current hero slide.
private struct HeroInfo: View {
    let item: MetaPreview
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TitleLogo(url: item.logoURL, name: item.name, maxHeight: 120)
            if let info = item.releaseInfo {
                Text(info).font(.callout.weight(.medium)).foregroundStyle(.white.opacity(0.8))
            }
            if let d = item.description {
                Text(d).font(.body).foregroundStyle(.white.opacity(0.9))
                    .lineLimit(3).frame(maxWidth: 560, alignment: .leading)
            }
        }
    }
}

/// Holds the hero's space while the first catalog loads, so content below doesn't jump when it lands.
private struct HeroPlaceholder: View {
    var body: some View {
        Rectangle().fill(.quaternary)
            .frame(maxWidth: .infinity)
            .frame(height: 560)
            .overlay(ArtworkScrim().opacity(0.5))
            .accessibilityHidden(true)
    }
}

/// The title's logo artwork, or its name in large type when there is no logo.
struct TitleLogo: View {
    let url: URL?
    let name: String
    var maxHeight: CGFloat = 110

    var body: some View {
        AsyncImage(url: url, transaction: .init(animation: .easeOut(duration: 0.3))) { phase in
            if let img = phase.image {
                img.resizable().aspectRatio(contentMode: .fit)
                    .shadow(color: .black.opacity(0.4), radius: 12)
            } else {
                Text(name).font(.system(.largeTitle, weight: .heavy)).foregroundStyle(.white)
                    .lineLimit(2).shadow(color: .black.opacity(0.4), radius: 8)
            }
        }
        .frame(maxWidth: 420, maxHeight: maxHeight, alignment: .bottomLeading)
        .accessibilityLabel(name)
    }
}

// MARK: - Shelves

struct ShelfHeader: View {
    let title: String
    var body: some View {
        Text(title).font(.title2.bold())
        .padding(.horizontal, 32)
        .accessibilityAddTraits(.isHeader)
    }
}

struct PosterRow: View {
    let title: String
    let items: [MetaPreview]
    var progress: [String: Double] = [:]
    /// Show placeholder posters while `items` is still empty (the catalog hasn't answered yet).
    var showsPlaceholder = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ShelfHeader(title: title)
            // Placeholder and posters share one slot and crossfade in place.
            ZStack(alignment: .topLeading) {
                if items.isEmpty {
                    if showsPlaceholder { PosterRowPlaceholder().transition(.opacity) }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 18) {
                            ForEach(items) { item in
                                NavigationLink(value: item) {
                                    PosterCard(item: item, progress: progress[item.id])
                                }
                                .buttonStyle(.card)
                            }
                        }
                        .scrollTargetLayout()
                        .padding(.horizontal, 32)
                        .padding(.vertical, 10)   // room for the hover lift
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .shelfPaging(ids: items.map(\.id), step: 160 + 18)
                    .transition(.opacity)
                }
            }
        }
    }
}

/// Poster-shaped placeholders with the same metrics as real cards. They pulse gently while loading,
/// and stay still under Reduce Motion.
private struct PosterRowPlaceholder: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion { cards } else {
            cards.phaseAnimator([false, true]) { content, dim in
                content.opacity(dim ? 0.55 : 1)
            } animation: { _ in .easeInOut(duration: 1.1) }
        }
    }

    private var cards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(0..<10, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary)
                            .frame(width: 160, height: 240)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Placeholder title").font(.callout.weight(.medium))
                            Text("2024").font(.caption)
                        }
                        .redacted(reason: .placeholder)
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 10)
        }
        .scrollDisabled(true)
        .accessibilityHidden(true)
    }
}

/// 16:9 card with progress, for Continue Watching.
struct LandscapeCard: View {
    let item: MetaPreview
    var progress: Double
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Artwork(url: item.backdropURL)
                .frame(width: 300, height: 169)
                .overlay(ArtworkScrim())
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 6) {
                        TitleLogo(url: item.logoURL, name: item.name, maxHeight: 44)
                            .frame(maxWidth: 170, alignment: .leading)
                        ProgressView(value: progress).tint(.white)
                    }
                    .padding(12)
                    .environment(\.colorScheme, .dark)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .hoverLift(hovering, cornerRadius: 14, scale: 1.03)
            Text(item.name).font(.callout.weight(.medium)).lineLimit(1)
        }
        .frame(width: 300)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
    }
}

struct PosterCard: View {
    let item: MetaPreview
    var progress: Double?
    @Environment(LibraryStore.self) private var library
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Artwork(url: item.poster.flatMap(URL.init(string:)))
                .overlay {
                    if item.poster == nil {
                        Text(item.name).font(.caption).multilineTextAlignment(.center).padding(6)
                    }
                }
                .frame(width: 160, height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .bottom) {
                    if let p = progress { ProgressView(value: p).tint(.white).padding(10) }
                }
                .hoverLift(hovering, cornerRadius: 12)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.callout.weight(.medium)).lineLimit(1)
                if let year = item.releaseInfo {
                    Text(year).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 160, alignment: .leading)
        }
        .onHover { hovering = $0 }
        .contextMenu {
            let saved = library.isSaved(item.id)
            Button(saved ? "Remove from Library" : "Add to Library",
                   systemImage: saved ? "minus.circle" : "plus.circle") { library.toggleSaved(item) }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Shelf paging

extension View {
    /// Hover arrows that page a horizontal shelf, like the TV app. Without them a mouse wheel
    /// (vertical only) can't reach anything past the first screen.
    func shelfPaging<ID: Hashable>(ids: [ID], step: CGFloat) -> some View {
        modifier(ShelfPager(ids: ids, step: step))
    }
}

private struct ShelfPager<ID: Hashable>: ViewModifier {
    let ids: [ID]
    let step: CGFloat
    @State private var position: ID?
    @State private var hovering = false
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .scrollPosition(id: $position, anchor: .leading)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { width = g.size.width }
                    .onChange(of: g.size.width) { _, w in width = w }
            })
            .overlay(alignment: .leading) { arrow(-1) }
            .overlay(alignment: .trailing) { arrow(1) }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private var page: Int { max(1, Int((width - 64) / step)) }
    private var current: Int { position.flatMap { ids.firstIndex(of: $0) } ?? 0 }

    @ViewBuilder private func arrow(_ dir: Int) -> some View {
        let canMove = dir < 0 ? current > 0 : current + page < ids.count
        if hovering && canMove {
            Button(dir < 0 ? "Scroll Back" : "Scroll Forward",
                   systemImage: dir < 0 ? "chevron.left" : "chevron.right") {
                let target = min(max(0, current + dir * page), ids.count - 1)
                withAnimation(.smooth) { position = ids[target] }
            }
            .labelStyle(.iconOnly)
            .circleGlassButton()
            .controlSize(.large)
            .padding(.horizontal, 10)
            .transition(.opacity)
        }
    }
}
