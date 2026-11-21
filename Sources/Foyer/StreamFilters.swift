import SwiftUI
import AddonKit

/// Filters for the stream table, shown as a row of pull-down buttons (like the filter buttons in
/// Photos, Music and Mail): each shows its current choice, is tinted while active, and has a tooltip.
struct StreamFilters: Equatable {
    enum Quality: String, CaseIterable, Identifiable {
        case any, uhd, fullHD, hd, sd
        var id: Self { self }
        var title: String {
            switch self {
            case .any: "Any Quality"
            case .uhd: "4K"
            case .fullHD: "1080p"
            case .hd: "720p"
            case .sd: "SD"
            }
        }
    }
    enum HDR: String, CaseIterable, Identifiable {
        case any, dolbyVision, hdr10, sdr
        var id: Self { self }
        var title: String {
            switch self {
            case .any: "Any HDR"
            case .dolbyVision: "Dolby Vision"
            case .hdr10: "HDR10 / HDR10+"
            case .sdr: "SDR"
            }
        }
    }
    enum Audio: String, CaseIterable, Identifiable {
        case any, atmos, surround71, surround51, stereo
        var id: Self { self }
        var title: String {
            switch self {
            case .any: "Any Audio"
            case .atmos: "Dolby Atmos"
            case .surround71: "7.1"
            case .surround51: "5.1"
            case .stereo: "Stereo"
            }
        }
    }
    /// Stored as a preference (Settings ▸ Playback shows the same choice).
    enum Player: String, CaseIterable, Identifiable {
        case any, native, mpv
        var id: Self { self }
        var title: String {
            switch self {
            case .any: "Any Player"
            case .native: "Apple's Player"
            case .mpv: "mpv"
            }
        }
    }

    var quality: Quality = .any
    var hdr: HDR = .any
    var audio: Audio = .any
    /// nil = every add-on.
    var addon: String?

    func matches(_ r: StreamTableRow, player: Player) -> Bool {
        let q = r.quality
        switch quality {
        case .any: break
        case .uhd: guard q.resolution == .uhd else { return false }
        case .fullHD: guard q.resolution == .fullHD || q.resolution == .qhd else { return false }
        case .hd: guard q.resolution == .hd else { return false }
        case .sd: guard q.resolution == .sd else { return false }
        }
        switch hdr {
        case .any: break
        case .dolbyVision: guard q.hdr.contains(.dolbyVision) else { return false }
        case .hdr10: guard q.hdr.contains(where: { $0 == .hdr10 || $0 == .hdr10Plus || $0 == .hdr }) else { return false }
        case .sdr: guard q.hdr.isEmpty else { return false }
        }
        switch audio {
        case .any: break
        case .atmos: guard q.audio.contains(where: { $0.localizedCaseInsensitiveContains("Atmos") }) else { return false }
        case .surround71: guard q.channels == "7.1" else { return false }
        case .surround51: guard q.channels == "5.1" else { return false }
        case .stereo: guard q.channels == "2.0" || q.channels == "Stereo" else { return false }
        }
        switch player {
        case .any: break
        case .native: guard r.nativeRank < 2 else { return false }   // Apple's player, or unknown (try it)
        case .mpv: guard r.nativeRank == 2 else { return false }
        }
        if let addon, r.addonId != addon { return false }
        return true
    }

    func isActive(player: Player) -> Bool {
        quality != .any || hdr != .any || audio != .any || addon != nil || player != .any
    }
}

/// The filter row above the stream table.
struct StreamFilterBar: View {
    @Binding var filters: StreamFilters
    @Binding var player: StreamFilters.Player
    /// Add-ons that returned streams (id, name, count), in the user's add-on order.
    let sources: [(id: String, name: String, count: Int)]
    let shown: Int
    let total: Int

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar
            ScrollView(.horizontal, showsIndicators: false) { bar }   // narrow windows
        }
    }

    private var bar: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(filters.isActive(player: player) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
            chip("Quality", value: filters.quality, all: StreamFilters.Quality.allCases, title: \.title,
                 help: "Show only streams at this resolution") { filters.quality = $0 }
            chip("HDR", value: filters.hdr, all: StreamFilters.HDR.allCases, title: \.title,
                 help: "Show only Dolby Vision, HDR10 or SDR streams") { filters.hdr = $0 }
            chip("Audio", value: filters.audio, all: StreamFilters.Audio.allCases, title: \.title,
                 help: "Show only streams with this audio format or channel layout") { filters.audio = $0 }
            chip("Player", value: player, all: StreamFilters.Player.allCases, title: \.title,
                 help: "Apple's player: MP4 and HLS with HDR, Dolby Vision, Atmos, AirPlay. mpv: MKV and other formats.") { player = $0 }
            if sources.count > 1 { addonChip }
            if filters.isActive(player: player) {
                Button("Clear Filters") {
                    filters = StreamFilters()
                    player = .any
                }
                .buttonStyle(.link)
                .help("Show every stream")
                .transition(.opacity)
            }
            Spacer(minLength: 12)
            Text(shown == total ? "\(total) streams" : "Showing \(shown) of \(total)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .font(.callout)
        .animation(.spring(duration: 0.25, bounce: 0), value: filters.isActive(player: player))
    }

    private func chip<T: Hashable & Identifiable>(_ name: String, value: T, all: [T], title: KeyPath<T, String>,
                                                  help: String, set: @escaping (T) -> Void) -> some View {
        let active = value != all.first
        return Menu {
            ForEach(all) { option in
                Button { set(option) } label: {
                    if option == value { Label(option[keyPath: title], systemImage: "checkmark") }
                    else { Text(option[keyPath: title]) }
                }
                if option == all.first { Divider() }
            }
        } label: {
            FilterChipLabel(text: active ? value[keyPath: title] : name, active: active)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
        .accessibilityLabel("\(name) filter")
        .accessibilityValue(value[keyPath: title])
    }

    private var addonChip: some View {
        let current = sources.first { $0.id == filters.addon }
        return Menu {
            Button { filters.addon = nil } label: {
                if filters.addon == nil { Label("All Add-ons", systemImage: "checkmark") } else { Text("All Add-ons") }
            }
            Divider()
            ForEach(sources, id: \.id) { src in
                Button { filters.addon = src.id } label: {
                    let t = "\(src.name) (\(src.count))"
                    if filters.addon == src.id { Label(t, systemImage: "checkmark") } else { Text(t) }
                }
            }
        } label: {
            FilterChipLabel(text: current?.name ?? "Add-on", active: current != nil)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show streams from one add-on")
        .accessibilityLabel("Add-on filter")
        .accessibilityValue(current?.name ?? "All Add-ons")
    }
}

/// Capsule label for a filter button: neutral when off, tinted when a value is chosen.
private struct FilterChipLabel: View {
    let text: String
    let active: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(text).lineLimit(1)
            Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).opacity(0.7)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        .background {
            Capsule().fill(active ? AnyShapeStyle(.tint.opacity(0.18))
                                  : AnyShapeStyle(.quaternary.opacity(hovering ? 1 : 0.6)))
        }
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .animation(.spring(duration: 0.2, bounce: 0), value: hovering)
        .animation(.spring(duration: 0.25, bounce: 0), value: active)
    }
}
