import SwiftUI

/// "What's New in Foyer", like Apple's apps: shown once after an update (not on a first install),
/// and from Foyer ▸ What's New. Add an entry for each version that has something to tell.
struct WhatsNewItem: Identifiable {
    let symbol: String
    let tint: Color
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    var id: String { symbol + "\(title)" }
}

enum WhatsNew {
    /// Newest first. The sheet shows the current version's entry.
    static let releases: [(version: String, items: [WhatsNewItem])] = [
        ("0.2.0", [
            .init(symbol: "sparkles.tv.fill", tint: .orange, title: "Best quality, automatically",
                  detail: "Play checks sources from the highest quality down and starts the first that works."),
            .init(symbol: "arrow.triangle.2.circlepath", tint: .green, title: "Never stuck on a dead link",
                  detail: "If a stream fails, Foyer moves to the next best source at the same spot. Resume checks your last source first."),
            .init(symbol: "line.3.horizontal.decrease.circle.fill", tint: .blue, title: "Stream filters",
                  detail: "Narrow the stream list by quality, HDR, audio, AirPlay & Picture in Picture, and add-on."),
            .init(symbol: "gauge.with.dots.needle.67percent", tint: .purple, title: "Smoother and lighter",
                  detail: "Pages stay fluid while something plays, artwork uses less memory, and quitting saves exactly where you stopped."),
            .init(symbol: "gearshape.fill", tint: .gray, title: "Organised Settings",
                  detail: "Settings are grouped into Add-ons, Playback, Subtitles, Library, Storage and About."),
        ]),
    ]

    static var current: [WhatsNewItem]? { releases.first { $0.version == AppInfo.version }?.items }

    private static let seenKey = "whatsNew.lastSeenVersion"

    /// True once per version after an update. A first install records the version silently.
    static func shouldShowOnLaunch() -> Bool {
        let d = UserDefaults.standard
        let seen = d.string(forKey: seenKey)
        d.set(AppInfo.version, forKey: seenKey)
        guard let seen else { return false }   // first launch ever: nothing is "new" yet
        return seen != AppInfo.version && current != nil
    }
}

struct WhatsNewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let items: [WhatsNewItem]

    var body: some View {
        VStack(spacing: 28) {
            Text("What's New in \(AppInfo.name)")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .padding(.top, 36)

            VStack(alignment: .leading, spacing: 22) {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 16) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 30))
                            .foregroundStyle(item.tint)
                            .frame(width: 44)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.headline)
                            Text(item.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, 44)

            Spacer(minLength: 0)

            Button { dismiss() } label: {
                Text("Continue").frame(maxWidth: 280).padding(.vertical, 4)
            }
            .nativeButtonStyle(prominent: true)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.bottom, 32)
        }
        .frame(width: 520, height: 560)
    }
}

/// Foyer ▸ What's New asks the main window to show the sheet.
extension Notification.Name {
    static let showWhatsNew = Notification.Name("foyer.showWhatsNew")
}
