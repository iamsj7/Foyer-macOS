import SwiftUI
import AddonKit

/// Liquid Glass on macOS 26+, the closest standard look on macOS 14–25.
/// Availability is fixed for the life of the process, so these branches never flip at runtime.
extension View {
    /// `.glass` / `.glassProminent` buttons, falling back to bordered styles.
    @ViewBuilder func nativeButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }

    /// Round glass icon button (the TV-style "+" next to Play).
    func circleGlassButton() -> some View {
        nativeButtonStyle().buttonBorderShape(.circle)
    }

    /// Keeps a page's drawing inside the detail column. On macOS 26 the detail area runs under the
    /// floating sidebar, so hover lifts, zooms and shadows near the leading edge would otherwise
    /// paint behind the sidebar glass. Layout is unaffected (it already respects the safe area).
    func staysClearOfSidebar() -> some View { clipped() }

    /// A floating glass surface; thick material before macOS 26.
    @ViewBuilder func glassSurface<S: Shape>(_ shape: S) -> some View {
        if #available(macOS 26, *) { glassEffect(.regular, in: shape) }
        else { background(.regularMaterial, in: shape) }
    }

    /// Artwork pages, like the TV app: no title text, no toolbar backing, art runs to the top edge.
    @ViewBuilder func fullBleedChrome() -> some View {
        if #available(macOS 26, *) {
            // The art runs under the toolbar and the back button floats on it. The soft edge effect
            // (a light blur that only builds as content scrolls under the bar) keeps toolbar items
            // legible, as in the TV app; the hard style would draw a solid band.
            toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else if #available(macOS 15, *) {
            toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else { self }
    }

    /// For a ScrollView whose content starts with a large title heading (TV-app / Music category
    /// pages, HIG "Navigation bars" large titles): the toolbar title stays hidden while the heading
    /// is on screen and fades in next to the back button once it scrolls away, so the page is always
    /// named. Apply directly to the ScrollView. macOS 14 shows the toolbar title all the time.
    func collapsingTitle(_ title: String, after threshold: CGFloat = 60) -> some View {
        modifier(CollapsingTitle(title: title, threshold: threshold))
    }

    /// Groups nearby glass so it blends and morphs (no-op before macOS 26).
    @ViewBuilder func glassGroup(spacing: CGFloat = 12) -> some View {
        if #available(macOS 26, *) { GlassEffectContainer(spacing: spacing) { self } } else { self }
    }
}

/// Artwork URLs. Cinemeta catalogs often omit backgrounds and logos; MetaHub serves them by IMDb id.
extension MetaPreview {
    var backdropURL: URL? {
        if let b = background, let u = URL(string: b) { return u }
        guard id.hasPrefix("tt") else { return poster.flatMap(URL.init(string:)) }
        return URL(string: "https://images.metahub.space/background/large/\(id)/img")
    }
    var logoURL: URL? {
        id.hasPrefix("tt") ? URL(string: "https://images.metahub.space/logo/medium/\(id)/img") : nil
    }
}

/// Bottom-weighted scrim so text stays legible over any artwork, in light and dark.
struct ArtworkScrim: View {
    var body: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0.35),
                               .init(color: .black.opacity(0.55), location: 0.75),
                               .init(color: .black.opacity(0.85), location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }
}

/// Fills its frame with remote artwork; quiet placeholder while loading.
struct Artwork: View {
    let url: URL?
    var body: some View {
        AsyncImage(url: url, transaction: .init(animation: .easeOut(duration: 0.3))) { phase in
            if let img = phase.image { img.resizable().aspectRatio(contentMode: .fill) }
            else { Rectangle().fill(.quaternary) }
        }
    }
}

// MARK: - Motion

/// One motion vocabulary for the app. Springs retarget from their current velocity, so hover and
/// press stay interruptible. Callers pass Reduce Motion to swap movement for a plain fade, or for nothing.
enum Motion {
    /// Pointer hover lift on cards.
    static var hover: Animation { .spring(duration: 0.35, bounce: 0.15) }
    /// Press down is quick and flat. Release has a little bounce, which reads as physical.
    static func press(_ pressed: Bool) -> Animation { .spring(duration: pressed ? 0.12 : 0.3, bounce: pressed ? 0 : 0.3) }
    /// Content arriving or leaving (catalog rows, search results, library items).
    static func content(_ reduceMotion: Bool) -> Animation { reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.35) }
    /// Sidebar page switches: brief, so navigation never waits on the animation.
    static var page: Animation { .easeOut(duration: 0.18) }
    /// Hero slide crossfade.
    static func slide(_ reduceMotion: Bool) -> Animation { .easeInOut(duration: reduceMotion ? 0.4 : 0.8) }

    /// Insertion that fades and rises a few points. Under Reduce Motion it only fades.
    static func rise(_ reduceMotion: Bool, by distance: CGFloat = 10) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: distance))
    }
}

/// Press feedback for card links (posters, landscape cards). A small, springy press-in that releases
/// with a little bounce. Under Reduce Motion it dims instead of scaling.
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { PressBody(configuration: configuration) }

    private struct PressBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let pressed = configuration.isPressed
            // The scoped `animation(_:body:)` animates only these two effects, never the label's own layout.
            configuration.label
                .animation(Motion.press(pressed)) { label in
                    label
                        .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
                        .opacity(pressed && reduceMotion ? 0.75 : 1)
                }
        }
    }
}

extension ButtonStyle where Self == CardButtonStyle {
    static var card: CardButtonStyle { CardButtonStyle() }
}

extension View {
    /// Gives this view's glass a stable identity inside a `glassGroup`, so glass that appears or
    /// disappears together morphs (no-op before macOS 26).
    @ViewBuilder func glassID<ID: Hashable & Sendable>(_ id: ID, in namespace: Namespace.ID) -> some View {
        if #available(macOS 26, *) { glassEffectID(id, in: namespace) } else { self }
    }

    /// Hover lift for artwork cards. Scale springs on hover, which keeps it interruptible, and is skipped
    /// under Reduce Motion. The shadows are cast by a plain shape behind the art, not by the artwork's
    /// pixels. Their blur radius never changes; only the lifted shadow's opacity animates.
    func hoverLift(_ lifted: Bool, cornerRadius: CGFloat, scale: CGFloat = 1.04) -> some View {
        modifier(HoverLift(lifted: lifted, cornerRadius: cornerRadius, scale: scale))
    }
}

private struct HoverLift: ViewModifier {
    let lifted: Bool
    let cornerRadius: CGFloat
    let scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                ZStack {
                    shape.fill(.background).shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                    shape.fill(.background).shadow(color: .black.opacity(0.32), radius: 14, y: 9)
                        .opacity(lifted ? 1 : 0)
                        .animation(Motion.hover, value: lifted)
                }
            }
            .animation(Motion.hover) { $0.scaleEffect(lifted && !reduceMotion ? scale : 1) }
    }
}

private struct CollapsingTitle: ViewModifier {
    let title: String
    let threshold: CGFloat
    @State private var scrolledPast = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .onScrollGeometryChange(for: Bool.self) { geo in
                    geo.contentOffset.y + geo.contentInsets.top > threshold
                } action: { _, past in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { scrolledPast = past }
                }
                .navigationTitle(title)          // names the window (Window menu, VoiceOver)
                .toolbar(removing: .title)       // shown by the item below instead, only when scrolled
                .toolbar {
                    if #available(macOS 26, *) {
                        ToolbarItem(placement: .navigation) { titleText }.sharedBackgroundVisibility(.hidden)
                    } else {
                        ToolbarItem(placement: .navigation) { titleText }
                    }
                }
        } else {
            content.navigationTitle(title)
        }
    }

    private var titleText: some View {
        Text(title)
            .font(.headline)
            .lineLimit(1)
            .opacity(scrolledPast ? 1 : 0)
            .accessibilityHidden(!scrolledPast)
    }
}
