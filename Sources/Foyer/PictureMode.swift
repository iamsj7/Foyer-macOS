import SwiftUI
import AddonKit
import AVKit

// MARK: - Picture modes (both players)

/// How the picture fills the window, like a TV's picture size setting.
enum VideoScaling: String, CaseIterable, Identifiable {
    case fit, fill, stretch, actual
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .fit: "Fit (Original Aspect)"
        case .fill: "Zoom to Fill"
        case .stretch: "Stretch"
        case .actual: "Actual Size"
        }
    }
    var systemImage: String {
        switch self {
        case .fit: "rectangle.arrowtriangle.2.inward"
        case .fill: "rectangle.arrowtriangle.2.outward"
        case .stretch: "arrow.left.and.right.square"
        case .actual: "1.square"
        }
    }
}

/// Picture shape override. Cinema and IMAX ratios reshape the frame the way a theater screen
/// would; "Auto" keeps the video's own aspect.
enum AspectPreset: String, CaseIterable, Identifiable {
    case auto, wide16x9, classic4x3, flat185, scope239, imax190, imax143
    var id: Self { self }
    var ratio: Double? {
        switch self {
        case .auto: nil
        case .wide16x9: 16.0 / 9.0
        case .classic4x3: 4.0 / 3.0
        case .flat185: 1.85
        case .scope239: 2.39
        case .imax190: 1.90
        case .imax143: 1.43
        }
    }
    var title: LocalizedStringKey {
        switch self {
        case .auto: "Original"
        case .wide16x9: "16:9 (TV)"
        case .classic4x3: "4:3 (Classic)"
        case .flat185: "1.85:1 (Cinema Flat)"
        case .scope239: "2.39:1 (Cinema Scope)"
        case .imax190: "1.90:1 (IMAX Digital)"
        case .imax143: "1.43:1 (IMAX Film)"
        }
    }
}

/// Where the video's frame goes inside `bounds` for a mode. Pure geometry, shared and testable.
enum PictureLayout {
    /// - videoAspect: the video's display aspect (or the forced one).
    /// - pixelSize: the video's pixel size in points, for Actual Size.
    static func target(in bounds: CGRect, videoAspect a: Double, scaling: VideoScaling, pixelSize: CGSize?) -> CGRect {
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0, a > 0 else { return bounds }
        var size: CGSize
        switch scaling {
        case .stretch: size = bounds.size
        case .fit: size = a >= w / h ? CGSize(width: w, height: w / a) : CGSize(width: h * a, height: h)
        case .fill: size = a >= w / h ? CGSize(width: h * a, height: h) : CGSize(width: w, height: w / a)
        case .actual:
            guard let p = pixelSize, p.height > 0 else {
                return target(in: bounds, videoAspect: a, scaling: .fit, pixelSize: nil)
            }
            size = CGSize(width: p.height * a, height: p.height)
        }
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}

extension PictureLayout {
    /// The layer frame that puts the video's rectangle (mpv letterboxes it inside the drawable)
    /// onto the mode's target rectangle.
    static func layerFrame(bounds: CGRect, drawable d: CGSize, videoAspect: Double?, override: Double?,
                           scaling: VideoScaling, pixelSize: CGSize?) -> CGRect {
        let ds = d.width / d.height
        guard let va = videoAspect, va > 0 else {
            // Unknown yet: show the drawable fitted, as mpv would.
            return PictureLayout.target(in: bounds, videoAspect: ds, scaling: .fit, pixelSize: nil)
        }
        // Fraction of the drawable the video occupies (mpv fits it, centered).
        let fx = va >= ds ? 1 : va / ds
        let fy = va >= ds ? ds / va : 1
        let t = PictureLayout.target(in: bounds, videoAspect: override ?? va, scaling: scaling, pixelSize: pixelSize)
        let size = CGSize(width: t.width / fx, height: t.height / fy)
        return CGRect(x: t.midX - size.width / 2, y: t.midY - size.height / 2, width: size.width, height: size.height)
    }
}

// MARK: - Quality chips

/// What's playing, as the TV app labels it: 4K · Dolby Vision · Atmos · 5.1. From the source's label,
/// corrected by what the player reports (actual height; HDR in mpv).
struct PlayerQualityChips: View {
    let sourceText: String
    var videoHeight: Int? = nil
    var liveHDR: Bool? = nil

    private var chips: [String] {
        let q = StreamQuality(parsing: sourceText)
        var out: [String] = []
        if let h = videoHeight, h > 0 {
            out.append(h >= 2000 ? "4K" : h >= 1400 ? "1440p" : h >= 1000 ? "1080p" : h >= 700 ? "720p" : "SD")
        } else if let r = q.resolution.label { out.append(r) }
        if q.hdr.contains(.dolbyVision) { out.append("Dolby Vision") }
        else if let h = q.hdr.first { out.append(h.rawValue) }
        else if liveHDR == true { out.append("HDR") }
        if let a = q.audio.first { out.append(a.contains("Atmos") ? "Dolby Atmos" : a) }
        if let ch = q.channels, ch != "2.0" { out.append(ch) }
        return out
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(chips, id: \.self) { t in
                Text(t)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.65), lineWidth: 1))
            }
        }
        .foregroundStyle(.white.opacity(0.9))
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Playing in \(chips.joined(separator: ", "))"))
    }
}

// MARK: - Mute

/// Apple-style mute button: slashed speaker when muted, otherwise the wave bars fill with the
/// volume (SF Symbols variable value). Click toggles mute.
struct MuteButton: View {
    let muted: Bool
    /// 0…1
    let level: Double
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Group {
                if muted || level <= 0 {
                    Image(systemName: "speaker.slash.fill")
                } else {
                    Image(systemName: "speaker.wave.3.fill", variableValue: level)
                }
            }
            .frame(width: 26, alignment: .leading)   // the bars don't shift the slider
            .contentTransition(.symbolEffect(.replace))
        }
        .help(muted ? "Unmute" : "Mute")
        .accessibilityLabel(muted ? "Unmute" : "Mute")
    }
}

// MARK: - Menu

/// The picture menu used by both players' controls.
struct PictureMenu: View {
    @Binding var scaling: VideoScaling
    /// nil hides the aspect presets (Apple's player can't reshape the picture).
    var aspect: Binding<AspectPreset>?

    var body: some View {
        Menu {
            Picker("Picture Size", selection: $scaling) {
                ForEach(VideoScaling.allCases.filter { aspect != nil || $0 != .actual }) { s in
                    Label(s.title, systemImage: s.systemImage).tag(s)
                }
            }
            .pickerStyle(.inline)
            if let aspect {
                Picker("Aspect Ratio", selection: aspect) {
                    ForEach(AspectPreset.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            }
        } label: {
            Label("Picture Size", systemImage: "aspectratio")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Picture size and aspect ratio")
    }
}

extension VideoScaling {
    /// Apple's player supports the first three directly.
    var avGravity: AVLayerVideoGravity {
        switch self {
        case .fill: .resizeAspectFill
        case .stretch: .resize
        case .fit, .actual: .resizeAspect
        }
    }
}
