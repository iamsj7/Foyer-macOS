import SwiftUI
import AppKit

// MARK: - Menu bar commands (HIG: every shortcut lives in a menu)

/// What the Playback menu drives; both players (AVPlayer and mpv) conform.
@MainActor protocol PlaybackControls: AnyObject {
    func togglePause()
    func skip(_ seconds: Double)
    func nudgeVolume(_ delta: Double)
    func toggleMute()
}

struct PlaybackKey: FocusedValueKey { typealias Value = any PlaybackControls }
struct SidebarSelectionKey: FocusedValueKey { typealias Value = Binding<SidebarItem?> }
/// Reloads the page in front (Home, Movies, TV Shows, a genre).
struct ReloadAction { let run: () -> Void; init(_ run: @escaping () -> Void) { self.run = run } }
struct ReloadKey: FocusedValueKey { typealias Value = ReloadAction }

extension FocusedValues {
    var playback: (any PlaybackControls)? {
        get { self[PlaybackKey.self] }
        set { self[PlaybackKey.self] = newValue }
    }
    var reload: ReloadAction? {
        get { self[ReloadKey.self] }
        set { self[ReloadKey.self] = newValue }
    }
    var sidebarSelection: Binding<SidebarItem?>? {
        get { self[SidebarSelectionKey.self] }
        set { self[SidebarSelectionKey.self] = newValue }
    }
}

struct AppCommands: Commands {
    @FocusedValue(\.playback) private var playback
    @FocusedValue(\.sidebarSelection) private var selection
    @FocusedValue(\.reload) private var reload

    var body: some Commands {
        // Foyer ▸ About Foyer. The standard panel reads the app bundle's Info.plist, which a build
        // run from the build folder doesn't have, so fill it from AppInfo.
        CommandGroup(replacing: .appInfo) {
            Button("About \(AppInfo.name)") { AboutPanel.show() }
            Button("What's New in \(AppInfo.name)") { NotificationCenter.default.post(name: .showWhatsNew, object: nil) }
                .disabled(WhatsNew.current == nil)
            Button("Check for Updates…") { Task { await UpdateChecker.shared.check(userInitiated: true) } }
        }
        // View ▸ sections, like the TV app's ⌘1…⌘4, plus Find.
        CommandGroup(after: .sidebar) {
            Divider()
            section(.home, "1")
            section(.movies, "2")
            section(.shows, "3")
            section(.search, "4")
            Divider()
            Button("Reload") { reload?.run() }
                .keyboardShortcut("r")
                .disabled(reload == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Find") { selection?.wrappedValue = .search }
                .keyboardShortcut("f")
                .disabled(selection == nil)
        }
        // Bare Space/arrow keys stay in the player window itself (a menu key equivalent would
        // also catch them in text fields); the menu uses ⌘ shortcuts like QuickTime Player.
        CommandMenu("Playback") {
            Button("Play/Pause") { playback?.togglePause() }
                .keyboardShortcut(.return, modifiers: .command)
            Divider()
            Button("Skip Back 10 Seconds") { playback?.skip(-10) }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button("Skip Forward 10 Seconds") { playback?.skip(10) }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Divider()
            Button("Volume Up") { playback?.nudgeVolume(0.1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Volume Down") { playback?.nudgeVolume(-0.1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button("Mute") { playback?.toggleMute() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        }
    }

    private func section(_ item: SidebarItem, _ key: KeyEquivalent) -> some View {
        Button(item.title) { selection?.wrappedValue = item }
            .keyboardShortcut(key)
            .disabled(selection == nil)
    }
}

// MARK: - Window tweaks

/// Reaches the hosting NSWindow once the view is in one.
struct WindowConfigurator: NSViewRepresentable {
    let configure: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView { Probe(configure) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        let configure: (NSWindow) -> Void
        init(_ c: @escaping (NSWindow) -> Void) { configure = c; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [configure] in configure(window) }
        }
    }
}

extension View {
    /// Player windows aren't brought back at launch: their stream links expire, and a window
    /// that starts playing by itself on launch is a surprise (HIG Windows).
    func playerWindow() -> some View {
        background(WindowConfigurator { $0.isRestorable = false })
    }
}
