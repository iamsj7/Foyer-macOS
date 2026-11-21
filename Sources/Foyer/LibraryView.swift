import SwiftUI
import AddonKit

enum LibraryScope {
    case recent, movies, shows
    var title: String {
        switch self {
        case .recent: "Recently Added"
        case .movies: "Movies"
        case .shows: "TV Shows"
        }
    }
}

/// The sidebar's "Library" pages: saved titles, newest first, optionally one type.
struct LibraryView: View {
    let scope: LibraryScope
    @Environment(LibraryStore.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 180), spacing: 20)]

    private var items: [LibraryItem] {
        switch scope {
        case .recent: library.saved
        case .movies: library.saved.filter { $0.type == "movie" }
        case .shows: library.saved.filter { $0.type == "series" }
        }
    }

    var body: some View {
        let continueWatching = library.continueWatching
        return ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                if scope == .recent && !continueWatching.isEmpty {
                    PosterRow(title: "Continue Watching", items: continueWatching.map(\.preview),
                              progress: Dictionary(uniqueKeysWithValues: continueWatching.map { ($0.id, $0.progress) }))
                }
                if !items.isEmpty {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                        ForEach(items) { item in
                            NavigationLink(value: item.preview) {
                                PosterCard(item: item.preview, progress: item.isInProgress ? item.progress : nil)
                            }
                            .buttonStyle(.card)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92)))
                        }
                    }
                    .padding(.horizontal, 32)
                    // Keyed on membership only, so saving or removing a title animates the grid while
                    // progress updates and hover don't. Under Reduce Motion the grid reflows without sliding.
                    .animation(reduceMotion ? nil : Motion.content(false), value: items.map(\.id))
                }
            }
            .padding(.vertical, 24)
        }
        .overlay {
            if items.isEmpty && (scope != .recent || continueWatching.isEmpty) {
                ContentUnavailableView("No \(scope == .recent ? "Titles" : scope.title) Yet",
                                       systemImage: "rectangle.stack.badge.plus",
                                       description: Text("Titles you add with + show up here."))
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: items.isEmpty)
        .staysClearOfSidebar()
        .navigationTitle(scope.title)
    }
}
