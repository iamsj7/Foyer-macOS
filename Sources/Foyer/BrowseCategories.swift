import SwiftUI
import AddonKit

/// What Search covers, like Apple Music's scope switch in the toolbar.
enum SearchScope: String, CaseIterable, Identifiable {
    case all, movies, shows
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .all: "All"
        case .movies: "Movies"
        case .shows: "TV Shows"
        }
    }
    func includes(_ type: String) -> Bool {
        switch self {
        case .all: true
        case .movies: type == "movie"
        case .shows: type == "series"
        }
    }
}

// MARK: - Browse Categories

/// Search before typing, like Apple Music / the TV app: vivid category cards for every genre your
/// add-ons offer. A card opens the same genre page as the chips on Movies and TV Shows.
struct BrowseCategories: View {
    var scope: SearchScope = .all
    @Environment(AddonStore.self) private var store

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 230), spacing: 20)]

    var body: some View {
        let sections = [("movie", "Movies"), ("series", "TV Shows")].compactMap { type, title -> (String, String, [String])? in
            guard scope.includes(type) else { return nil }
            let g = GenreCatalogs.genres(in: store.addons, type: type)
            return g.isEmpty ? nil : (type, title, g)
        }
        VStack(alignment: .leading, spacing: 28) {
            ForEach(sections, id: \.0) { type, title, genres in
                VStack(alignment: .leading, spacing: 14) {
                    Text(sections.count > 1 ? "Browse \(title)" : "Browse Categories")
                        .font(.title2.bold())
                        .padding(.horizontal, 32)
                        .accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                        ForEach(genres, id: \.self) { genre in
                            NavigationLink(value: GenreRoute(type: type, genre: genre)) {
                                GenreCard(route: GenreRoute(type: type, genre: genre))
                            }
                            .buttonStyle(.card)
                        }
                    }
                    .padding(.horizontal, 32)
                }
            }
        }
    }
}

/// Apple Music's category card: one vivid colour per genre with a photo from that genre blended
/// into it (duotone), title bottom-left in bold white.
struct GenreCard: View {
    let route: GenreRoute
    @Environment(AddonStore.self) private var store
    @State private var art: URL?

    /// Apple Music-like palette; a genre always gets the same colour.
    private static let palette: [Color] = [
        Color(red: 0.62, green: 0.35, blue: 0.90),  // purple
        Color(red: 0.15, green: 0.68, blue: 0.42),  // green
        Color(red: 0.90, green: 0.40, blue: 0.25),  // orange
        Color(red: 0.88, green: 0.20, blue: 0.27),  // red
        Color(red: 0.88, green: 0.30, blue: 0.55),  // pink
        Color(red: 0.16, green: 0.55, blue: 0.86),  // blue
        Color(red: 0.86, green: 0.65, blue: 0.13),  // gold
        Color(red: 0.10, green: 0.62, blue: 0.62),  // teal
        Color(red: 0.55, green: 0.12, blue: 0.30),  // wine
        Color(red: 0.40, green: 0.45, blue: 0.95),  // indigo
    ]
    private var color: Color {
        let h = route.genre.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Self.palette[h % Self.palette.count]
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            color
            if let art {
                AsyncImage(url: art, transaction: .init(animation: .easeOut(duration: 0.3))) { phase in
                    if let image = phase.image {
                        // Duotone: the photo's light and shade in the card's colour.
                        image.resizable().scaledToFill()
                            .saturation(0)
                            .blendMode(.luminosity)
                            .opacity(0.85)
                            .transition(.opacity)
                    }
                }
                color.opacity(0.35).blendMode(.color)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .center, endPoint: .bottom)
            Text(route.genre)
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(12)
        }
        .compositingGroup()
        .aspectRatio(1.8, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(route.title))
        .task(id: route) { art = await GenreArt.shared.art(for: route, addons: store.addons, client: store.client) }
    }
}

/// One background per genre, fetched once per launch.
actor GenreArt {
    static let shared = GenreArt()
    private var cache: [GenreRoute: URL?] = [:]

    func art(for route: GenreRoute, addons: [InstalledAddon], client: AddonClient) async -> URL? {
        if let hit = cache[route] { return hit }
        var url: URL?
        if let shelf = GenreCatalogs.shelves(in: addons, route: route).first,
           let items = try? await client.catalog(shelf.addon, type: route.type, id: shelf.catalog.id, genre: shelf.genre) {
            // Wide backdrops crop well into the card; skip titles without one.
            url = items.lazy.compactMap { $0.background.flatMap(URL.init(string:)) }.first
        }
        cache[route] = url
        return url
    }
}

// MARK: - Recently Searched

/// Titles opened from Search, newest first (kept on this Mac only).
@MainActor @Observable
final class RecentSearches {
    static let shared = RecentSearches()
    private static let key = "search.recent"
    private(set) var items: [MetaPreview] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([MetaPreview].self, from: data) { items = saved }
    }
    func add(_ item: MetaPreview) {
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        if items.count > 15 { items.removeLast(items.count - 15) }
        save()
    }
    func clear() { items = []; save() }
    private func save() { UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: Self.key) }
}

/// Apple Music's "Recently Searched" row: compact cards with art, title, kind and a chevron.
struct RecentlySearchedRow: View {
    let items: [MetaPreview]
    let clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recently Searched").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Clear", action: clear)
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 32)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(items) { item in
                        NavigationLink(value: item) { RecentCard(item: item) }
                            .buttonStyle(.card)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 32)
                .padding(.vertical, 4)
            }
            .shelfPaging(ids: items.map(\.id), step: 250 + 14)
        }
    }
}

private struct RecentCard: View {
    let item: MetaPreview
    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: item.poster.flatMap(URL.init(string:)))
                .frame(width: 40, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.callout.weight(.semibold)).lineLimit(1)
                Text([item.type == "series" ? "TV Show" : "Movie", item.releaseInfo].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(width: 250, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
