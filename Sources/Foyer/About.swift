import SwiftUI
import AppKit

/// App identity in one place: rename the app or change the license here.
enum AppInfo {
    static let name = "Foyer"
    static let version = "0.2.0"
    static let author = "Shaik Jaleel"
    static let year = "2026"
    static let license = "GNU General Public License v3.0 or later"
    static let licenseSPDX = "GPL-3.0-or-later"
    static let licenseURL = URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!
    static let repository = "iamsj7/Foyer-macOS"   // GitHub owner/name: source link and update checks
    static let sourceURL: URL? = URL(string: "https://github.com/\(repository)")

    static var copyright: String { "© \(year) \(author)" }
}

/// Open-source components bundled in the app, plus the services and data it shows.
struct Attribution: Identifiable {
    let name: String
    let purpose: String
    let license: String
    let url: String
    var id: String { name }

    /// Bundled through MPVKit's LGPL build (not the -GPL variant), linked into the app.
    static let components: [Attribution] = [
        .init(name: "mpv (libmpv)", purpose: "Player for MKV and other formats", license: "LGPL-2.1-or-later", url: "https://mpv.io"),
        .init(name: "MPVKit", purpose: "libmpv packaged for Apple platforms", license: "LGPL-3.0", url: "https://github.com/mpvkit/MPVKit"),
        .init(name: "FFmpeg", purpose: "Demuxing and decoding", license: "LGPL-2.1-or-later", url: "https://ffmpeg.org"),
        .init(name: "libplacebo", purpose: "GPU video rendering, HDR tone mapping", license: "LGPL-2.1-or-later", url: "https://code.videolan.org/videolan/libplacebo"),
        .init(name: "libdovi", purpose: "Dolby Vision metadata", license: "MIT", url: "https://github.com/quietvoid/dovi_tool"),
        .init(name: "MoltenVK", purpose: "Vulkan on Metal", license: "Apache-2.0", url: "https://github.com/KhronosGroup/MoltenVK"),
        .init(name: "shaderc", purpose: "Shader compilation", license: "Apache-2.0", url: "https://github.com/google/shaderc"),
        .init(name: "Little CMS", purpose: "Colour management", license: "MIT", url: "https://www.littlecms.com"),
        .init(name: "dav1d", purpose: "AV1 decoding", license: "BSD-2-Clause", url: "https://code.videolan.org/videolan/dav1d"),
        .init(name: "uavs3d", purpose: "AVS3 decoding", license: "BSD-3-Clause", url: "https://github.com/uavs3/uavs3d"),
        .init(name: "libass", purpose: "Subtitle rendering (mpv)", license: "ISC", url: "https://github.com/libass/libass"),
        .init(name: "FreeType", purpose: "Font rendering", license: "FreeType License (FTL)", url: "https://freetype.org"),
        .init(name: "HarfBuzz", purpose: "Text shaping", license: "MIT", url: "https://harfbuzz.github.io"),
        .init(name: "FriBidi", purpose: "Bidirectional text", license: "LGPL-2.1-or-later", url: "https://github.com/fribidi/fribidi"),
        .init(name: "libunibreak", purpose: "Line breaking", license: "zlib", url: "https://github.com/adah1972/libunibreak"),
        .init(name: "uchardet", purpose: "Subtitle encoding detection", license: "MPL-1.1 / GPL-2.0 / LGPL-2.1", url: "https://www.freedesktop.org/wiki/Software/uchardet/"),
        .init(name: "libbluray", purpose: "Blu-ray structures", license: "LGPL-2.1-or-later", url: "https://www.videolan.org/developers/libbluray.html"),
        .init(name: "OpenSSL", purpose: "TLS", license: "Apache-2.0", url: "https://www.openssl.org"),
        .init(name: "GnuTLS, Nettle, GMP", purpose: "TLS and cryptography", license: "LGPL (Nettle/GMP: LGPL-3.0-or-later or GPL-2.0-or-later)", url: "https://www.gnutls.org"),
        .init(name: "LuaJIT", purpose: "mpv scripting", license: "MIT", url: "https://luajit.org"),
    ]

    /// Services whose data appears in the app (through add-ons the user installs).
    static let services: [Attribution] = [
        .init(name: "Stremio add-on protocol", purpose: "How catalogs, details, streams and subtitles are requested", license: "Protocol by Stremio", url: "https://github.com/Stremio/stremio-addon-sdk"),
        .init(name: "Cinemeta", purpose: "Default catalogs and title details", license: "Stremio service", url: "https://v3-cinemeta.strem.io"),
        .init(name: "IMDb", purpose: "Ratings and title ids shown via add-ons", license: "Data © IMDb.com, Inc.", url: "https://www.imdb.com"),
        .init(name: "The Movie Database (TMDB)", purpose: "Catalogs, details and cast photos via the TMDB add-on. This product uses the TMDB API but is not endorsed or certified by TMDB.", license: "TMDB terms of use", url: "https://www.themoviedb.org"),
        .init(name: "OpenSubtitles", purpose: "Subtitles via the OpenSubtitles add-on", license: "OpenSubtitles terms", url: "https://www.opensubtitles.org"),
        .init(name: "Apple frameworks", purpose: "SwiftUI, AVFoundation, AVKit; SF Symbols", license: "Apple SDK license", url: "https://developer.apple.com"),
    ]
}

/// Settings ▸ About.
struct AboutSection: View {
    var body: some View {
        Section {
            LabeledContent(AppInfo.name) {
                Text("Version \(AppInfo.version)").foregroundStyle(.secondary)
            }
            LabeledContent("Made by") { Text(AppInfo.copyright) }
            LabeledContent("License") {
                Link(AppInfo.licenseSPDX, destination: AppInfo.licenseURL)
                    .help(AppInfo.license)
            }
            if let source = AppInfo.sourceURL {
                LabeledContent("Source Code") { Link("View on GitHub", destination: source) }
            }
            UpdatesRow()
            NavigationLink {
                AttributionsView()
            } label: {
                Label("Acknowledgements", systemImage: "heart.text.square")
            }
            LabeledContent("Liquid Glass") {
                if #available(macOS 26, *) { Text("On") } else { Text("Requires macOS 26") }
            }
        } header: {
            Text("About")
        } footer: {
            Text("\(AppInfo.name) is free and open-source software. It doesn't host or provide any content: catalogs, streams and subtitles come from the add-ons you install, and you're responsible for how you use them.")
        }
    }
}

struct AttributionsView: View {
    var body: some View {
        Form {
            Section {
                Text("\(AppInfo.name) \(AppInfo.version)  ·  \(AppInfo.copyright)")
                Text("Licensed under the \(AppInfo.license). This program comes with ABSOLUTELY NO WARRANTY; you may redistribute it under the terms of that license.")
                    .foregroundStyle(.secondary)
                Link("Read the License", destination: AppInfo.licenseURL)
            } header: { Text("License") }

            Section {
                ForEach(Attribution.components) { row($0) }
            } header: {
                Text("Open-Source Components")
            } footer: {
                Text("Bundled through MPVKit's LGPL build. Each component remains under its own license; the source for every component is available at the linked project.")
            }

            Section {
                ForEach(Attribution.services) { row($0) }
            } header: {
                Text("Data and Services")
            } footer: {
                Text("Names and marks belong to their owners. \(AppInfo.name) is not affiliated with or endorsed by any of them.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Acknowledgements")
        .floatingToolbarChrome()
    }

    private func row(_ a: Attribution) -> some View {
        LabeledContent {
            Text(a.license).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                if let url = URL(string: a.url) { Link(a.name, destination: url) } else { Text(a.name) }
                Text(a.purpose).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Storage

/// Settings ▸ Storage: cache sizes and clearing.
struct StorageSection: View {
    @Environment(LibraryStore.self) private var library
    @State private var cacheBytes = URLCache.shared.currentDiskUsage
    @State private var recents = RecentSearches.shared
    @State private var confirm = false

    var body: some View {
        Section {
            LabeledContent("Image and Response Cache") {
                Text(ByteCountFormatter.string(fromByteCount: Int64(cacheBytes), countStyle: .file))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            HStack {
                Button("Clear Cache…") { confirm = true }
                    .disabled(cacheBytes == 0)
                Button("Clear Recent Searches") { recents.clear() }
                    .disabled(recents.items.isEmpty)
            }
            LabeledContent("App Data") {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Disk.dir]) }
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("The cache holds posters and artwork so pages open instantly; it refills as you browse. Your library, watch progress and add-ons aren't affected.")
        }
        .confirmationDialog("Clear the cache?", isPresented: $confirm) {
            Button("Clear Cache", role: .destructive) {
                URLCache.shared.removeAllCachedResponses()
                cacheBytes = URLCache.shared.currentDiskUsage
            }
        } message: {
            Text("Posters and artwork will download again as you browse.")
        }
        .task {
            // Keep the size current while Settings is open.
            while !Task.isCancelled {
                cacheBytes = URLCache.shared.currentDiskUsage
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

// MARK: - About panel

/// The standard macOS About panel, filled from AppInfo so it's complete with or without a bundle.
enum AboutPanel {
    @MainActor static func show() {
        let body = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        func line(_ text: String, link: URL? = nil) -> NSAttributedString {
            var attrs: [NSAttributedString.Key: Any] = [.font: body, .paragraphStyle: center,
                                                        .foregroundColor: NSColor.secondaryLabelColor]
            if let link { attrs[.link] = link }
            return NSAttributedString(string: text + "\n", attributes: attrs)
        }
        let credits = NSMutableAttributedString()
        credits.append(line("A native macOS player for Stremio-compatible add-ons."))
        credits.append(line(""))
        credits.append(line("Licensed under \(AppInfo.licenseSPDX)", link: AppInfo.licenseURL))
        if let source = AppInfo.sourceURL { credits.append(line("Source code on GitHub", link: source)) }
        credits.append(line(""))
        credits.append(line("Plays with Apple's AVFoundation and mpv (MPVKit, LGPL). Full list in Settings ▸ About ▸ Acknowledgements."))
        credits.append(line(""))
        credits.append(line("Foyer doesn't host or provide content; everything comes from add-ons you install."))

        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: AppInfo.name,
            .applicationVersion: AppInfo.version,
            .version: "",                       // no separate build number
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): AppInfo.copyright,
        ]
        if let icon = NSApp.applicationIconImage { options[.applicationIcon] = icon }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}
