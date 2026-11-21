import SwiftUI
import AVKit
import AppKit

// Apple's player with our own controls. AVKit's floating controls can't be reliably hidden on
// macOS 26 (they stay up, dimmed, when the window isn't key, and switching them off leaves an
// empty glass panel behind), so the video draws into a plain AVPlayerLayer and the same glass
// control bar as the mpv player sits on top, shown and hidden by the screen itself.

/// Hosts the AVPlayerLayer. Picture in Picture runs from this layer.
final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        playerLayer.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func makeBackingLayer() -> CALayer { playerLayer }
}

struct PlayerLayerRepresentable: NSViewRepresentable {
    let model: PlayerModel
    func makeNSView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.playerLayer.player = model.player
        model.attach(layer: v.playerLayer)
        return v
    }
    func updateNSView(_ v: PlayerLayerView, context: Context) {
        let g = model.scaling.avGravity
        if v.playerLayer.videoGravity != g {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.35)
            CATransaction.setAnimationTimingFunction(Motion.layerCurve)
            v.playerLayer.videoGravity = g
            CATransaction.commit()
        }
    }
}

/// The system AirPlay route button.
struct AirPlayButton: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.player = player
        v.isRoutePickerButtonBordered = false
        v.setRoutePickerButtonColor(.white, for: .normal)
        v.setRoutePickerButtonColor(.white, for: .normalHighlighted)
        return v
    }
    func updateNSView(_ v: AVRoutePickerView, context: Context) {}
}

/// Same layout and glass as the mpv control bar, driven by PlayerModel.
struct AVControlsBar: View {
    let model: PlayerModel
    @Binding var scrubbing: Double?

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 10) {
                AVScrubberRow(model: model, scrubbing: $scrubbing)
                    .font(.callout)

                HStack(spacing: 16) {
                    optionMenu(model.audioOptions, selected: model.selectedAudio, title: "Audio",
                               systemImage: "speaker.wave.2", allowsOff: false) { model.selectAudio($0) }
                    subtitlesMenu
                    PlayerQualityChips(sourceText: model.request.sourceText, videoHeight: model.videoHeight)
                    Spacer()
                    Button("Back 10 Seconds", systemImage: "gobackward.10") { model.skip(-10) }
                    Button(model.isPaused ? "Play" : "Pause", systemImage: model.isPaused ? "play.fill" : "pause.fill") {
                        model.togglePause()
                    }
                    .font(.title2)
                    .contentTransition(.symbolEffect(.replace))
                    .keyboardShortcut(.space, modifiers: [])
                    Button("Forward 10 Seconds", systemImage: "goforward.10") { model.skip(10) }
                    Spacer()
                    MuteButton(muted: model.isMuted, level: model.volume) { model.toggleMute() }
                    Slider(value: Binding(get: { model.volume }, set: { model.setVolume($0) }), in: 0...1)
                        .frame(width: 90).controlSize(.mini)
                        .accessibilityLabel("Volume")
                    AirPlayButton(player: model.player)
                        .frame(width: 22, height: 22)
                        .help("AirPlay")
                    PictureMenu(scaling: Binding(get: { model.scaling }, set: { model.scaling = $0 }), aspect: nil)
                    if AVPictureInPictureController.isPictureInPictureSupported() {
                        Button("Picture in Picture", systemImage: "pip.enter") { model.togglePictureInPicture() }
                            .disabled(!model.canPictureInPicture)
                            .help("Picture in Picture")
                    }
                    Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") {
                        NSApp.keyWindow?.toggleFullScreen(nil)
                    }
                    .help("Full Screen")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.title3)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20).padding(.vertical, 14)
            .glassSurface(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .environment(\.colorScheme, .dark)
            .frame(maxWidth: 860)
            .padding(.horizontal, 24).padding(.bottom, 22)
        }
    }

    /// Embedded subtitles (from the stream) and add-on subtitles in one menu.
    private var subtitlesMenu: some View {
        let subs = model.subtitles
        return Menu {
            Button {
                model.selectLegible(nil)
                subs.turnOff()
            } label: {
                if model.selectedLegible == nil && subs.selected == nil { Label("Off", systemImage: "checkmark") } else { Text("Off") }
            }
            if !model.legibleOptions.isEmpty {
                Section("In This Stream") {
                    ForEach(Array(model.legibleOptions.enumerated()), id: \.offset) { _, o in
                        Button {
                            subs.turnOff()
                            model.selectLegible(o)
                        } label: {
                            if model.selectedLegible == o { Label(o.displayName, systemImage: "checkmark") } else { Text(o.displayName) }
                        }
                    }
                }
            }
            Section("From Add-ons") {
                SubtitleMenu(controller: subs, onPick: { model.selectLegible(nil) })
            }
        } label: {
            Label("Subtitles", systemImage: model.selectedLegible == nil && subs.selected == nil ? "captions.bubble" : "captions.bubble.fill")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Subtitles")
    }

    private func optionMenu(_ options: [AVMediaSelectionOption], selected: AVMediaSelectionOption?, title: String,
                            systemImage: String, allowsOff: Bool,
                            pick: @escaping (AVMediaSelectionOption?) -> Void) -> some View {
        Menu {
            if allowsOff {
                Button("Off") { pick(nil) }
            }
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                Button { pick(o) } label: {
                    if selected == o { Label(o.displayName, systemImage: "checkmark") } else { Text(o.displayName) }
                }
            }
            if options.isEmpty { Text("Only one \(title.lowercased()) track") }
        } label: {
            Label(title, systemImage: systemImage)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help(title)
        .disabled(options.count < 2)
    }
}

/// The clock and scrubber. Only this view reads the position, so the 2 Hz time updates don't
/// re-evaluate the rest of the bar.
private struct AVScrubberRow: View {
    let model: PlayerModel
    @Binding var scrubbing: Double?

    private var shownTime: Double { scrubbing ?? model.position }

    var body: some View {
        HStack(spacing: 10) {
            Text(format(shownTime)).monospacedDigit()
            Slider(value: Binding(get: { shownTime }, set: { scrubbing = $0 }),
                   in: 0...max(model.duration, 1)) { editing in
                if !editing, let t = scrubbing { model.seek(to: t); scrubbing = nil }
            }
            .controlSize(.small)
            .accessibilityLabel("Playback position")
            .accessibilityValue(Text("\(format(shownTime)) of \(format(model.duration))"))
            Text("-" + format(max(0, model.duration - shownTime))).monospacedDigit()
        }
    }

    private func format(_ t: Double) -> String {
        guard t.isFinite else { return "0:00" }
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
