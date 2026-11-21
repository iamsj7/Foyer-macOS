import SwiftUI
import AddonKit

/// A genre page to push: "Action" within movies, "Drama" within series, and so on.
struct GenreRoute: Hashable {
    let type: String
    let genre: String

    var title: String {
        switch type {
        case "movie": return "\(genre) Movies"
        case "series": return "\(genre) TV Shows"
        default: return "\(genre) \(type.capitalized)"
        }
    }
}

/// Genre discovery from installed manifests: each catalog lists its `genre` extra's options.
enum GenreCatalogs {
    /// Union of every add-on's genre options for one type. Cinemeta's order comes first (it is the
    /// add-on most people have), then any genre only another add-on knows, in that add-on's order.
    /// Duplicates are matched case-insensitively; the first spelling seen is kept.
    static func genres(in addons: [InstalledAddon], type: String) -> [String] {
        let ordered = addons.filter { isCinemeta($0) } + addons.filter { !isCinemeta($0) }
        var seen = Set<String>()
        var out: [String] = []
        for a in ordered {
            for c in a.manifest.catalogs ?? [] where c.type == type && isGenreCatalog(c) {
                for g in c.genreOptions {
                    let name = g.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty, seen.insert(name.lowercased()).inserted { out.append(name) }
                }
            }
        }
        return out
    }

    /// Catalogs that can show a genre, with the genre spelled the way that add-on lists it.
    static func shelves(in addons: [InstalledAddon], route: GenreRoute) -> [GenreShelf] {
        var out: [GenreShelf] = []
        for a in addons {
            for c in a.manifest.catalogs ?? [] where c.type == route.type && isGenreCatalog(c) {
                guard let value = c.genreOptions.first(where: { $0.caseInsensitiveCompare(route.genre) == .orderedSame })
                else { continue }
                out.append(GenreShelf(id: CatalogKey(a, c).id, addon: a, catalog: c, genre: value,
                                      title: c.name ?? c.id))
            }
        }
        // Two add-ons with a "Popular" catalog: name the add-on so the shelves read apart.
        let counts = Dictionary(grouping: out, by: { $0.title.lowercased() }).mapValues(\.count)
        return out.map { s in
            guard counts[s.title.lowercased(), default: 0] > 1 else { return s }
            var s = s
            s.title = "\(s.title) · \(s.addon.manifest.name)"
            return s
        }
    }

    /// Add-ons reuse the `genre` extra for other filters: years (Cinemeta "New", TMDB "Year"),
    /// languages (TMDB "Language"), or "Day"/"Week" (TMDB "Trending"). A catalog counts as a genre
    /// catalog only when its options include a few everyday genre names. Catalogs that take a genre but
    /// list no options are left out: there is nothing to offer for them.
    static func isGenreCatalog(_ c: CatalogDef) -> Bool {
        guard c.isBrowsableByGenre else { return false }
        let known = c.genreOptions.filter { commonGenres.contains($0.lowercased()) }.count
        return known >= 2
    }

    private static let commonGenres: Set<String> = [
        "action", "adventure", "animation", "comedy", "crime", "documentary", "drama", "family",
        "fantasy", "history", "horror", "mystery", "romance", "sci-fi", "science fiction", "thriller",
        "war", "western", "music", "musical", "biography", "sport", "action & adventure",
        "sci-fi & fantasy", "kids", "reality", "talk", "news", "soap",
    ]

    private static func isCinemeta(_ a: InstalledAddon) -> Bool {
        a.id.localizedCaseInsensitiveContains("cinemeta") || a.manifest.name.localizedCaseInsensitiveContains("cinemeta")
    }
}

struct GenreShelf: Identifiable {
    let id: String
    let addon: InstalledAddon
    let catalog: CatalogDef
    let genre: String
    var title: String
}

// MARK: - Genre chips

/// Horizontally scrolling category capsules, like the TV app's chips under its hero.
struct GenreChips: View {
    let type: String
    let genres: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(genres, id: \.self) { genre in
                    NavigationLink(value: GenreRoute(type: type, genre: genre)) {
                        Text(genre).padding(.horizontal, 4)
                    }
                    .nativeButtonStyle()
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .accessibilityHint("Shows \(GenreRoute(type: type, genre: genre).title)")
                }
            }
            .scrollTargetLayout()
            .glassGroup(spacing: 10)
            .padding(.horizontal, 32)
            .padding(.vertical, 6)
        }
        .scrollTargetBehavior(.viewAligned)
        // Chips vary in width; a typical one is about this wide, which is enough for paging by arrows.
        .shelfPaging(ids: genres, step: 120)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Genres")
    }
}

// MARK: - Genre page

struct GenreView: View {
    let route: GenreRoute
    @Environment(AddonStore.self) private var store
    @State private var shelves: [GenreShelf] = []
    @State private var items: [String: [MetaPreview]] = [:]
    @State private var loading = false
    @State private var reloadToken = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var visible: [GenreShelf] { loading ? shelves : shelves.filter { !(items[$0.id] ?? []).isEmpty } }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 36) {
                Text(route.title)
                    .font(.largeTitle.bold())
                    .padding(.horizontal, 32)
                    .padding(.top, 12)
                    .accessibilityAddTraits(.isHeader)
                ForEach(visible) { shelf in
                    PosterRow(title: shelf.title, items: items[shelf.id] ?? [], showsPlaceholder: loading)
                        .transition(.opacity)
                }
                if !loading && visible.isEmpty {
                    emptyState
                        .padding(.top, 80)
                        .transition(.opacity)
                }
            }
            .padding(.bottom, 36)
        }
        .staysClearOfSidebar()
        .overlay { if loading && shelves.isEmpty { ProgressView() } }
        .navigationTitle(route.title)
        .titleInContent()   // the large heading above is the visible title
        .focusedSceneValue(\.reload, ReloadAction { reloadToken += 1 })   // View ▸ Reload (⌘R)
        .task(id: GenreLoadKey(route: route, catalogs: CatalogKey.lineup(store.addons), token: reloadToken)) { await load() }
    }

    @ViewBuilder private var emptyState: some View {
        if shelves.isEmpty {
            ContentUnavailableView("No catalogs for \(route.genre)", systemImage: "square.stack.3d.up.slash",
                                   description: Text("None of your add-ons can browse this genre. Add one in Settings (⌘,)."))
        } else {
            ContentUnavailableView("Nothing in \(route.genre) right now", systemImage: "film.stack",
                                   description: Text("Your add-ons didn't return any titles. Check your connection, then reload (⌘R)."))
        }
    }

    @MainActor private func load() async {
        loading = true
        defer { loading = false }
        let list = GenreCatalogs.shelves(in: store.addons, route: route)
        shelves = list
        items = [:]
        let client = store.client
        await withTaskGroup(of: (String, [MetaPreview]).self) { group in
            for s in list {
                group.addTask {
                    let got = (try? await client.catalog(s.addon, type: s.catalog.type, id: s.catalog.id, genre: s.genre)) ?? []
                    // Catalogs occasionally repeat a title; ForEach identity must be unique.
                    var seen = Set<String>()
                    return (s.id, got.filter { seen.insert($0.id).inserted })
                }
            }
            for await (id, got) in group {
                withAnimation(Motion.content(reduceMotion)) { items[id] = got }
            }
        }
        // `loading` turning off collapses empty shelves; animate that like Home does.
        withAnimation(reduceMotion ? nil : Motion.content(false)) { loading = false }
    }
}

private struct GenreLoadKey: Hashable {
    let route: GenreRoute
    let catalogs: [String]
    let token: Int
}
