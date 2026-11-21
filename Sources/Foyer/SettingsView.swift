import SwiftUI
import AppKit
import AddonKit

/// Preference keys shared by Settings and the views that read them.
enum Prefs {
    static let resume = "playback.resume"                       // Bool, default true
    static let nativeOnly = "streamsNativeOnly"                 // Bool, legacy: replaced by streamPlayer
    static let streamPlayer = "streams.player"                  // StreamFilters.Player: any / native
    static let technicalDetails = "streams.technicalDetails"    // Bool, default false: format column

    /// "Show only native streams" became the Player filter; carry the old choice over once.
    static func migrateStreamFilter() {
        let d = UserDefaults.standard
        guard d.object(forKey: streamPlayer) == nil, d.bool(forKey: nativeOnly) else { return }
        d.set(StreamFilters.Player.native.rawValue, forKey: streamPlayer)
    }
    static let subtitleLanguage = "subtitles.preferredLanguage"   // "" = off; same key SubtitleController reads
    static let settingsTab = "settings.selectedPane"
}

/// Settings categories. The sidebar page lists them like System Settings; the ⌘, window shows one
/// toolbar tab per category, like Apple's apps.
enum SettingsPane: String, CaseIterable, Identifiable {
    case addons, playback, subtitles, library, storage, about
    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .addons: "Add-ons"
        case .playback: "Playback"
        case .subtitles: "Subtitles"
        case .library: "Library"
        case .storage: "Storage"
        case .about: "About"
        }
    }
    var summary: LocalizedStringKey {
        switch self {
        case .addons: "Install, reorder and remove add-ons"
        case .playback: "Resume and stream preferences"
        case .subtitles: "Preferred subtitle language"
        case .library: "Watch history and saved titles"
        case .storage: "Cache and app data"
        case .about: "Version, license, updates and acknowledgements"
        }
    }
    var systemImage: String {
        switch self {
        case .addons: "puzzlepiece.extension.fill"
        case .playback: "play.fill"
        case .subtitles: "captions.bubble.fill"
        case .library: "books.vertical.fill"
        case .storage: "internaldrive.fill"
        case .about: "info"
        }
    }
    /// The coloured tile behind the symbol, as in System Settings.
    var tint: Color {
        switch self {
        case .addons: .purple
        case .playback: .red
        case .subtitles: .blue
        case .library: .orange
        case .storage: .gray
        case .about: .secondary
        }
    }
}

/// One category's page. Add-ons has its own full page; the rest are grouped forms.
struct SettingsPaneView: View {
    let pane: SettingsPane

    var body: some View {
        Group {
            switch pane {
        case .addons: AddonsView()
        case .playback: PlaybackSettings()
        case .subtitles: SubtitleSettings()
        case .library: LibrarySettings()
        case .storage: Form { StorageSection() }.formStyle(.grouped).navigationTitle("Storage")
        case .about: Form { AboutSection() }.formStyle(.grouped).navigationTitle("About")
            }
        }
        .floatingToolbarChrome()
    }
}

// MARK: - Sidebar ▸ Settings

/// The sidebar's Settings page: categories listed like System Settings.
struct SettingsView: View {
    var body: some View {
        Form {
            Section {
                ForEach(SettingsPane.allCases) { pane in
                    NavigationLink { SettingsPaneView(pane: pane) } label: { SettingsRow(pane: pane) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}

struct SettingsRow: View {
    let pane: SettingsPane
    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(pane: pane)
            VStack(alignment: .leading, spacing: 2) {
                Text(pane.title)
                Text(pane.summary).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// System Settings–style icon: white symbol on a rounded, coloured tile.
struct SettingsIcon: View {
    let pane: SettingsPane
    var body: some View {
        Image(systemName: pane.systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(pane.tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - ⌘, window

/// The Settings window: one toolbar tab per category (the standard Mac settings layout).
struct SettingsWindow: View {
    @AppStorage(Prefs.settingsTab) private var selection: SettingsPane = .addons

    var body: some View {
        TabView(selection: $selection) {
            ForEach(SettingsPane.allCases) { pane in
                NavigationStack { SettingsPaneView(pane: pane) }
                    .tabItem { Label(pane.title, systemImage: pane.systemImage) }
                    .tag(pane)
            }
        }
        .frame(width: 660, height: 580)
    }
}

// MARK: - Panes

struct PlaybackSettings: View {
    @AppStorage(Prefs.resume) private var resume = true
    @AppStorage(Prefs.technicalDetails) private var technical = false

    var body: some View {
        Form {
            Section {
                Toggle("Resume where you left off", isOn: $resume)
            } footer: {
                Text("Resume continues on the same source at your last position.")
            }
            Section {
                Toggle("Show technical details", isOn: $technical)
            } footer: {
                Text("Adds each stream's file format to the stream list. \(AppInfo.name) always picks the right player automatically.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Playback")
    }
}

struct SubtitleSettings: View {
    @AppStorage(Prefs.subtitleLanguage) private var subtitleLanguage = ""

    /// Common languages first; the current choice is always listed even if it's not here.
    private var languages: [String] {
        let common = ["en", "es", "fr", "de", "it", "pt-BR", "pt", "nl", "sv", "pl", "tr", "ru",
                      "ar", "hi", "ta", "te", "ur", "ja", "ko", "zh-Hans", "zh-Hant"]
        return subtitleLanguage.isEmpty || common.contains(subtitleLanguage) ? common : [subtitleLanguage] + common
    }

    var body: some View {
        Form {
            Section {
                Picker("Preferred language", selection: $subtitleLanguage) {
                    Text("Off").tag("")
                    Divider()
                    ForEach(languages, id: \.self) { code in
                        Text(SubtitleLanguage.displayName(code)).tag(code)
                    }
                }
            } footer: {
                Text("Turned on automatically when a subtitle add-on has this language. Change it anytime from the player.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Subtitles")
    }
}

struct LibrarySettings: View {
    @Environment(LibraryStore.self) private var library
    @State private var confirm: ClearAction?

    enum ClearAction: Identifiable {
        case history, saved
        var id: Self { self }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Saved titles", value: "\(library.saved.count)")
                LabeledContent("In progress", value: "\(library.continueWatching.count)")
            }
            Section {
                Button("Clear Watch History…") { confirm = .history }
                    .disabled(library.items.values.allSatisfy { $0.position == 0 })
                Button("Remove All Saved Titles…", role: .destructive) { confirm = .saved }
                    .disabled(library.saved.isEmpty)
            } footer: {
                Text("Your library is stored only on this Mac.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Library")
        .confirmationDialog(confirm == .saved ? "Remove all saved titles?" : "Clear watch history?",
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            presenting: confirm) { action in
            switch action {
            case .history: Button("Clear Watch History", role: .destructive) { library.clearHistory() }
            case .saved: Button("Remove All Saved Titles", role: .destructive) { library.removeAllSaved() }
            }
        } message: { action in
            Text(action == .history ? "Continue Watching and resume positions will be reset."
                                    : "Your saved Movies and TV Shows will be removed from the Library.")
        }
    }
}
