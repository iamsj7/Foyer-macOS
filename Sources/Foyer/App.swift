import SwiftUI
import AppKit
import AddonKit

@main
struct FoyerApp: App {
    @State private var addons = AddonStore()
    @State private var library = LibraryStore()

    init() {
        Disk.migrateOldPreferences()
        // Posters load through URLSession.shared; a big cache makes the second launch instant.
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
        // Running via `swift run` has no app bundle, so make it a normal foreground app.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup(AppInfo.name) {
            RootView()
                .environment(addons)
                .environment(library)
                .frame(minWidth: 960, minHeight: 600)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                    UpdateChecker.shared.checkAutomaticallyIfDue()
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()   // View ▸ Show/Hide Sidebar (⌃⌘S)
            AppCommands()       // View ▸ sections ⌘1–⌘4, Find ⌘F, Playback menu
            ToolbarCommands()   // View ▸ Customize Toolbar…
        }

        // Each stream plays in its own native window (full screen, PiP, AirPlay all work).
        WindowGroup("Player", for: PlayRequest.self) { $req in
            if let req {
                // AVPlayer for native streams, mpv for MKV/AVI/WebM.
                PlayerRouter(request: req)
                    .environment(library)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 720)

        // AVPlayer hands streams it can't play to this window ("Play with mpv", or automatically).
        WindowGroup("Player (mpv)", for: MPVRequest.self) { $req in
            if let req {
                MPVPlayerScreen(request: req.request)
                    .environment(library)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 720)

        // ⌘, opens the standard Mac settings window: one toolbar tab per category. The sidebar's
        // Settings page lists the same categories.
        Settings {
            SettingsWindow()
                .environment(addons)
                .environment(library)
        }
    }
}

/// Mirrors the TV app's sidebar: browse items on top, then a "Library" section.
enum SidebarItem: String, CaseIterable, Identifiable {
    case search, home, movies, shows
    case recentlyAdded, savedMovies, savedShows
    case settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .search: "Search"
        case .home: "Home"
        case .movies, .savedMovies: "Movies"
        case .shows, .savedShows: "TV Shows"
        case .recentlyAdded: "Recently Added"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .search: "magnifyingglass"
        case .home: "house"
        case .movies: "film"
        case .shows: "tv"
        case .recentlyAdded: "clock"
        case .savedMovies: "film.stack"
        case .savedShows: "play.rectangle.on.rectangle"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    @State private var section: SidebarItem? = .home
    @State private var path = NavigationPath()

    /// Sidebar clicks drop any pushed detail without animation. Then the new page fades in quickly
    /// in its own transaction, so pushes and pops keep the system animation.
    private var selection: Binding<SidebarItem?> {
        Binding(get: { section }, set: { new in
            guard new != section else { return }
            path = NavigationPath()
            withAnimation(Motion.page) { section = new }
        })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                row(.search)
                row(.home)
                row(.movies)
                row(.shows)
                Section("Library") {
                    row(.recentlyAdded)
                    row(.savedMovies)
                    row(.savedShows)
                }
                Section { row(.settings) }
            }
            .toolbar(removing: .sidebarToggle)   // like the TV app; View ▸ Show Sidebar (⌃⌘S) still works
            // Fixed, like the TV app: a range lets each page's ideal width resize the sidebar on switch.
            .navigationSplitViewColumnWidth(220)
        } detail: {
            NavigationStack(path: $path) {
                Group {
                    switch section ?? .home {
                    case .search: SearchView()
                    case .home: HomeView()
                    case .movies: HomeView(type: "movie", title: "Movies")
                    case .shows: HomeView(type: "series", title: "TV Shows")
                    case .recentlyAdded: LibraryView(scope: .recent)
                    case .savedMovies: LibraryView(scope: .movies)
                    case .savedShows: LibraryView(scope: .shows)
                    case .settings: SettingsView()
                    }
                }
                .id(section)   // a fresh page per sidebar switch (resets its scroll and state)
                // Fade in only, so two pages and their toolbars never overlap. Opacity alone is also
                // fine under Reduce Motion.
                .transition(.asymmetric(insertion: .opacity, removal: .identity))
                .navigationDestination(for: MetaPreview.self) { DetailView(preview: $0) }
            }
        }
        .focusedSceneValue(\.sidebarSelection, selection)
    }

    private func row(_ item: SidebarItem) -> some View {
        Label(item.title, systemImage: item.icon).tag(item)
    }
}
