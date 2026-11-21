import SwiftUI
import AddonKit

struct AddonsView: View {
    @Environment(AddonStore.self) private var store
    @State private var url = ""
    @State private var installing = false
    @State private var error: String?
    @State private var installingSuggestion: String?
    @State private var pendingRemoval: InstalledAddon?

    var body: some View {
        Form {
            Section {
                TextField("Manifest URL", text: $url,
                          prompt: Text("https://… or stremio://…/manifest.json"))
                    .onSubmit { Task { await install() } }
                    .disabled(installing)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.callout)
                }
            } header: {
                Text("Install Add-on")
            } footer: {
                HStack {
                    Spacer()
                    if installing { ProgressView().controlSize(.small) }
                    Button("Install", systemImage: "plus") { Task { await install() } }
                        .keyboardShortcut(.defaultAction)
                        .nativeButtonStyle(prominent: true)
                        .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty || installing)
                }
            }

            if !suggestions.isEmpty {
                Section {
                    ForEach(suggestions) { s in
                        SuggestedAddonRow(addon: s, installing: installingSuggestion == s.id) {
                            Task { await install(s) }
                        }
                        .disabled(installingSuggestion != nil)
                    }
                } header: {
                    Text("Suggested Add-ons")
                } footer: {
                    Text("Only legal add-ons are suggested: catalogs, title details, subtitles and trailers. \(AppInfo.name) never suggests stream sources. “Configure” opens the add-on's website: set it up there, then paste your manifest URL above.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if store.addons.isEmpty {
                    Text("No add-ons installed.").foregroundStyle(.secondary)
                }
                ForEach(store.addons) { addon in
                    AddonRow(addon: addon) { pendingRemoval = addon }
                }
                .onMove { store.move(from: $0, to: $1) }
            } header: {
                Text("Installed")
            } footer: {
                Text("Drag to reorder. Order sets Home rows and stream priority.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Add-ons")
        .confirmationDialog("Remove \(pendingRemoval?.manifest.name ?? "add-on")?",
                            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                            presenting: pendingRemoval) { addon in
            Button("Remove", role: .destructive) { store.remove(addon) }
        } message: { addon in
            Text("Its catalogs, streams and subtitles will no longer appear. You can install it again later.")
        }
    }

    /// Suggestions not installed yet (matched by manifest id or URL).
    private var suggestions: [SuggestedAddon] {
        SuggestedAddon.all.filter { s in
            !store.addons.contains { a in
                s.configureURL == nil ? (a.id == s.id || a.manifestURL == s.manifestURL)
                                      : a.id.localizedCaseInsensitiveContains(s.id)
            }
        }
    }

    @MainActor private func install(_ s: SuggestedAddon) async {
        installingSuggestion = s.id; error = nil
        defer { installingSuggestion = nil }
        do { try await store.install(s.manifestURL) }
        catch { self.error = "\(s.name): \(error.localizedDescription)" }
    }

    @MainActor private func install() async {
        installing = true; error = nil
        defer { installing = false }
        do {
            try await store.install(url)
            url = ""
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct AddonRow: View {
    let addon: InstalledAddon
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: addon.manifest.logo.flatMap(URL.init(string:))) { phase in
                if let img = phase.image { img.resizable().aspectRatio(contentMode: .fit) }
                else { Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(.secondary) }
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(addon.manifest.name).font(.headline)
                    Text(addon.manifest.version ?? "").font(.caption).foregroundStyle(.secondary)
                }
                if let d = addon.manifest.description {
                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 6) {
                    ForEach((addon.manifest.resources ?? []).map(\.name), id: \.self) { r in
                        Text(r).font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                    // Host only: manifest URLs often contain a private token.
                    Text(URL(string: addon.manifestURL)?.host ?? "").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button("Remove", systemImage: "trash", role: .destructive, action: onRemove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Remove \(addon.manifest.name)")
        }
        .padding(.vertical, 4)
        .contextMenu { Button("Remove", role: .destructive, action: onRemove) }
    }
}

/// Suggested add-ons: legal only (catalogs, metadata, subtitles, trailers). Stream sources are never
/// suggested; users add those themselves. Most install in one click;
/// AIOMetadata needs setup on its site first (`configureURL`), then its manifest URL is pasted above.
struct SuggestedAddon: Identifiable {
    let id: String          // manifest id (or id fragment for per-user manifests), to hide it once installed
    let name: String
    let summary: String
    let systemImage: String
    let manifestURL: String
    var configureURL: String? = nil

    static let all: [SuggestedAddon] = [
        SuggestedAddon(id: "tmdb-addon", name: "The Movie Database",
                       summary: "TMDB catalogs and title details: popular, trending and by genre.",
                       systemImage: "film.stack",
                       manifestURL: "https://tmdb.elfhosted.com/manifest.json"),
        SuggestedAddon(id: "org.stremio.opensubtitlesv3", name: "OpenSubtitles",
                       summary: "Subtitles in dozens of languages, shown in the player's Subtitles menu.",
                       systemImage: "captions.bubble",
                       manifestURL: "https://opensubtitles-v3.strem.io/manifest.json"),
        SuggestedAddon(id: "pw.ers.netflix-catalog", name: "Streaming Catalogs",
                       summary: "What's on Netflix, Disney+, HBO Max, Prime Video and Apple TV+, as Home rows.",
                       systemImage: "rectangle.stack",
                       manifestURL: "https://7a82163c306e-stremio-netflix-catalog-addon.baby-beamup.club/manifest.json"),
        SuggestedAddon(id: "community.anime.kitsu", name: "Anime Kitsu",
                       summary: "Anime catalogs and details from Kitsu.",
                       systemImage: "sparkles.tv",
                       manifestURL: "https://anime-kitsu.strem.fun/manifest.json"),
        SuggestedAddon(id: "org.streailer.trailer", name: "Streailer",
                       summary: "Trailers for movies and shows.",
                       systemImage: "play.rectangle",
                       manifestURL: "https://streailer.elfhosted.com/manifest.json"),
        SuggestedAddon(id: "com.aio.metadata", name: "AIOMetadata",
                       summary: "The community's pick to replace Cinemeta: TMDB, TVDB, IMDb and MDBList in one. Set up on its site.",
                       systemImage: "info.circle",
                       manifestURL: "", configureURL: "https://aiometadata.elfhosted.com/configure"),
    ]
}

struct SuggestedAddonRow: View {
    let addon: SuggestedAddon
    let installing: Bool
    let onInstall: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: addon.systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(addon.name).font(.headline)
                Text(addon.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if installing {
                ProgressView().controlSize(.small)
            } else if let configure = addon.configureURL.flatMap(URL.init(string:)) {
                Link("Configure…", destination: configure)
                    .help("Set up \(addon.name) on its website")
            } else {
                Button("Install", action: onInstall)
                    .nativeButtonStyle()
                    .help("Install \(addon.name)")
            }
        }
        .padding(.vertical, 4)
    }
}
