import SwiftUI
import AddonKit

/// Sidebar "Search", like the TV app: a toolbar search field and a poster grid per type.
struct SearchView: View {
    @Environment(AddonStore.self) private var store
    @State private var query = ""
    @State private var results: [SearchSection] = []
    @State private var searching = false
    /// Bumped for each new result set, so a whole set crossfades instead of cards shuffling around.
    @State private var generation = 0
    @State private var scope: SearchScope = .all
    @State private var recents = RecentSearches.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 180), spacing: 20)]

    var body: some View {
        ScrollView {
            // The outgoing and incoming result sets overlap during the crossfade.
            ZStack(alignment: .top) {
                // Before typing: category cards instead of an empty page, like the TV app.
                if overlayState == .prompt {
                    VStack(alignment: .leading, spacing: 32) {
                        if !recents.items.isEmpty {
                            RecentlySearchedRow(items: recents.items.filter { scope.includes($0.type) }) {
                                withAnimation(Motion.content(reduceMotion)) { recents.clear() }
                            }
                        }
                        BrowseCategories(scope: scope)
                    }
                    .padding(.vertical, 24)
                    .transition(.opacity)
                }
                LazyVStack(alignment: .leading, spacing: 32) {
                    ForEach(results.filter { scope.includes($0.id) }) { section in
                        VStack(alignment: .leading, spacing: 12) {
                            ShelfHeader(title: section.title)
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                                ForEach(section.items) { item in
                                    NavigationLink(value: item) { PosterCard(item: item) }
                                        .buttonStyle(.card)
                                        .simultaneousGesture(TapGesture().onEnded { recents.add(item) })
                                }
                            }
                            .padding(.horizontal, 32)
                        }
                    }
                }
                .padding(.vertical, 24)
                .id(generation)
                .transition(.asymmetric(insertion: Motion.rise(reduceMotion, by: 8),
                                        removal: .opacity.animation(.easeOut(duration: 0.15))))
            }
        }
        .overlay {
            ZStack {
                switch overlayState {
                case .prompt:
                    // Categories fill the page; this only shows when no add-on lists genres.
                    if GenreCatalogs.genres(in: store.addons, type: "movie").isEmpty
                        && GenreCatalogs.genres(in: store.addons, type: "series").isEmpty {
                        ContentUnavailableView("Search", systemImage: "magnifyingglass",
                                               description: Text("Find movies and shows across your add-ons."))
                            .transition(.opacity)
                    }
                case .loading:
                    ProgressView().transition(.opacity)
                case .noResults:
                    ContentUnavailableView.search(text: query).transition(.opacity)
                case .none:
                    EmptyView()
                }
            }
            // Keyed on the state, not the query, so typing never animates. Only switching states does.
            .animation(.easeInOut(duration: 0.2), value: overlayState)
        }
        .staysClearOfSidebar()
        .navigationTitle("Search")
        .navigationDestination(for: GenreRoute.self) { GenreView(route: $0) }
        // Centred in the toolbar with the scope switch on the right, like Apple Music.
        .searchable(text: $query, placement: .toolbarPrincipal, prompt: "Movies, Shows and More")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Search In", selection: $scope) {
                    ForEach(SearchScope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Search movies, TV shows or both")
            }
        }
        .task(id: query) { await search() }
    }

    private enum OverlayState: Equatable { case prompt, loading, noResults, none }

    private var overlayState: OverlayState {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return .prompt }
        if results.contains(where: { scope.includes($0.id) }) { return .none }
        return searching ? .loading : .noResults
    }

    @MainActor private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else {
            if !results.isEmpty { withAnimation(Motion.content(reduceMotion)) { results = []; generation += 1 } }
            return
        }
        try? await Task.sleep(for: .milliseconds(300))   // debounce typing
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }

        var targets: [(InstalledAddon, CatalogDef)] = []
        for a in store.addons {
            for c in a.manifest.catalogs ?? [] where c.supportsSearch
                && !targets.contains(where: { $0.1.type == c.type }) {   // one catalog per type is enough
                targets.append((a, c))
            }
        }
        let client = store.client
        var found: [SearchSection] = []
        await withTaskGroup(of: SearchSection?.self) { group in
            for (a, c) in targets {
                group.addTask {
                    guard let items = try? await client.search(a, type: c.type, catalogId: c.id, query: q),
                          !items.isEmpty else { return nil }
                    var seen = Set<String>()
                    return SearchSection(id: c.type, title: c.type == "series" ? "TV Shows" : c.type == "movie" ? "Movies" : c.type.capitalized,
                                         items: items.filter { seen.insert($0.id).inserted })
                }
            }
            for await s in group { if let s { found.append(s) } }
        }
        guard !Task.isCancelled else { return }
        withAnimation(Motion.content(reduceMotion)) {
            results = found.sorted { $0.id < $1.id }   // "movie" before "series"
            generation += 1
        }
    }
}

struct SearchSection: Identifiable {
    let id: String
    let title: String
    let items: [MetaPreview]
}
