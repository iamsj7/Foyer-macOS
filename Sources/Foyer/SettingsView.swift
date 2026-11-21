import SwiftUI
import AppKit
import AddonKit

/// Preference keys shared by Settings and the views that read them.
enum Prefs {
    static let resume = "playback.resume"                       // Bool, default true
    static let nativeOnly = "streamsNativeOnly"                 // Bool, default false (stream table)
    static let subtitleLanguage = "subtitles.preferredLanguage"   // "" = off; same key SubtitleController reads
}

/// The sidebar's Settings page (also shown for ⌘,): app preferences plus add-on management.
struct SettingsView: View {
    @Environment(AddonStore.self) private var store
    @Environment(LibraryStore.self) private var library

    @AppStorage(Prefs.resume) private var resume = true
    @AppStorage(Prefs.nativeOnly) private var nativeOnly = false
    @AppStorage(Prefs.subtitleLanguage) private var subtitleLanguage = ""
    @State private var confirmClear: ClearAction?

    enum ClearAction: Identifiable {
        case history, saved
        var id: Self { self }
    }

    /// Common subtitle languages first; the current choice is always listed even if it's not here.
    private var languages: [String] {
        let common = ["en", "es", "fr", "de", "it", "pt-BR", "pt", "nl", "sv", "pl", "tr", "ru",
                      "ar", "hi", "ta", "te", "ur", "ja", "ko", "zh-Hans", "zh-Hant"]
        return subtitleLanguage.isEmpty || common.contains(subtitleLanguage) ? common : [subtitleLanguage] + common
    }

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    AddonsView()
                } label: {
                    LabeledContent {
                        Text("\(store.addons.count) installed").foregroundStyle(.secondary)
                    } label: {
                        Label("Add-ons", systemImage: "puzzlepiece.extension")
                    }
                }
            } header: {
                Text("Add-ons")
            } footer: {
                Text("Install, reorder and remove add-ons. Order sets Home rows and stream priority.")
            }

            Section("Playback") {
                Toggle("Resume where you left off", isOn: $resume)
                Toggle("Show only streams that play natively", isOn: $nativeOnly)
                LabeledContent("Player") {
                    Text("Apple's player for MP4 and HLS · mpv for MKV and other formats")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section {
                Picker("Preferred language", selection: $subtitleLanguage) {
                    Text("Off").tag("")
                    Divider()
                    ForEach(languages, id: \.self) { code in
                        Text(SubtitleLanguage.displayName(code)).tag(code)
                    }
                }
            } header: {
                Text("Subtitles")
            } footer: {
                Text("Turned on automatically when a subtitle add-on has this language. Change it anytime from the player.")
            }

            Section("Library") {
                LabeledContent("Saved titles", value: "\(library.saved.count)")
                LabeledContent("In progress", value: "\(library.continueWatching.count)")
                HStack {
                    Button("Clear Watch History…") { confirmClear = .history }
                        .disabled(library.items.values.allSatisfy { $0.position == 0 })
                    Button("Remove All Saved Titles…", role: .destructive) { confirmClear = .saved }
                        .disabled(library.saved.isEmpty)
                }
            }

            StorageSection()

            AboutSection()
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirmClear != nil },
                                                               set: { if !$0 { confirmClear = nil } }),
                            presenting: confirmClear) { action in
            switch action {
            case .history: Button("Clear Watch History", role: .destructive) { library.clearHistory() }
            case .saved: Button("Remove All Saved Titles", role: .destructive) { library.removeAllSaved() }
            }
        } message: { action in
            Text(action == .history ? "Continue Watching and resume positions will be reset."
                                    : "Your saved Movies and TV Shows will be removed from the Library.")
        }
    }

    private var confirmTitle: String {
        confirmClear == .saved ? "Remove all saved titles?" : "Clear watch history?"
    }
}
