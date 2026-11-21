import SwiftUI
import AddonKit

// MARK: - Derived title info
// Everything the title page shows beyond streams, computed once when the meta arrives
// (never in `body`), so lists below have cached collections with stable ids.

struct TitleInfo {
    struct Person: Identifiable, Hashable {
        enum Role: Hashable { case cast, director, writer
            var label: LocalizedStringResource {
                switch self {
                case .cast: "Cast"
                case .director: "Director"
                case .writer: "Writer"
                }
            }
        }
        let name: String
        var roles: [Role]
        var photo: URL? = nil
        var character: String? = nil
        var id: String { name }
        var roleText: String {
            if let character, !character.isEmpty, roles == [.cast] { return character }
            return roles.map { String(localized: $0.label) }.formatted(.list(type: .and))
        }
    }

    struct Fact: Identifiable {
        enum Kind: Hashable { case released, runtime, rating, rated, genre, country, director, writer, status, awards }
        let id: Kind
        let title: LocalizedStringResource
        let value: String
        var accessibilityValue: String?
    }

    let score: Double?
    let certification: String?
    let year: String?
    let runtime: String?
    let genres: [String]
    let awards: String?
    let trailer: URL?
    let imdb: URL?
    let people: [Person]
    let facts: [Fact]
    /// Episodes by season, each sorted by episode number; season 0 (specials) left out.
    let episodesBySeason: [Int: [Video]]
    let seasons: [Int]

    init(_ m: Meta) {
        score = m.imdbScore
        certification = m.certification
        year = m.year ?? m.releaseInfo
        runtime = m.runtimeMinutes.map { Self.formatRuntime($0) } ?? m.runtime
        genres = m.genres ?? []
        awards = m.awards.flatMap { $0.isEmpty || $0 == "N/A" ? nil : $0 }
        trailer = m.trailerURL
        imdb = m.imdbURL

        // One tile per person, roles merged ("Christopher Nolan · Director and Writer").
        var people: [Person] = []
        func add(_ names: [String]?, _ role: Person.Role) {
            for n in names ?? [] {
                if let i = people.firstIndex(where: { $0.name == n }) {
                    if !people[i].roles.contains(role) { people[i].roles.append(role) }
                } else { people.append(Person(name: n, roles: [role])) }
            }
        }
        // Cast first, then crew, like the TV app. Add-ons with headshots (TMDB) list cast with
        // photos and characters; others only give names.
        if let members = m.castMembers {
            for c in members.prefix(20) where !people.contains(where: { $0.name == c.name }) {
                people.append(Person(name: c.name, roles: [.cast], photo: c.photo.flatMap(URL.init(string:)),
                                     character: c.character))
            }
        } else {
            add(m.cast, .cast)
        }
        add(m.director, .director); add(m.writer, .writer)
        self.people = people

        var facts: [Fact] = []
        if let d = m.releaseDate {
            facts.append(Fact(id: .released, title: "Released", value: d.formatted(.addonDay)))
        }
        if let r = runtime { facts.append(Fact(id: .runtime, title: "Runtime", value: r)) }
        if let s = score {
            let v = s.formatted(.number.precision(.fractionLength(1)))
            facts.append(Fact(id: .rating, title: "IMDb Rating", value: "\(v) / 10",
                              accessibilityValue: String(localized: "\(v) out of 10")))
        }
        if let c = certification { facts.append(Fact(id: .rated, title: "Rated", value: c)) }
        if !genres.isEmpty { facts.append(Fact(id: .genre, title: "Genre", value: genres.formatted(.list(type: .and)))) }
        if let c = m.country { facts.append(Fact(id: .country, title: "Country", value: c)) }
        if let d = m.director {
            facts.append(Fact(id: .director, title: d.count > 1 ? "Directors" : "Director", value: d.formatted(.list(type: .and))))
        }
        if let w = m.writer {
            facts.append(Fact(id: .writer, title: w.count > 1 ? "Writers" : "Writer", value: w.formatted(.list(type: .and))))
        }
        if let s = m.status { facts.append(Fact(id: .status, title: "Status", value: s)) }
        if let a = awards { facts.append(Fact(id: .awards, title: "Awards", value: a)) }
        self.facts = facts

        let eps = (m.videos ?? []).filter { ($0.season ?? 0) > 0 }
        let grouped = Dictionary(grouping: eps) { $0.season ?? 0 }
            .mapValues { $0.sorted { ($0.episode ?? 0) < ($1.episode ?? 0) } }
        episodesBySeason = grouped
        seasons = grouped.keys.sorted()
    }

    /// "2 hr 28 min", locale-aware.
    static func formatRuntime(_ minutes: Int) -> String {
        Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}

extension FormatStyle where Self == Date.FormatStyle {
    /// Add-on dates are calendar days stamped at midnight UTC; format them in UTC so they
    /// don't slip to the previous day west of Greenwich.
    static var addonDay: Date.FormatStyle {
        var f = Date.FormatStyle(date: .long, time: .omitted)
        f.timeZone = TimeZone(identifier: "UTC") ?? .current
        return f
    }
    static var addonShortDay: Date.FormatStyle {
        var f = Date.FormatStyle(date: .abbreviated, time: .omitted)
        f.timeZone = TimeZone(identifier: "UTC") ?? .current
        return f
    }
}

// MARK: - Motion

/// The page's motion vocabulary. Reduce Motion keeps fades (they convey change without
/// movement) and drops slides, scales and springs.
enum DetailMotion {
    static func reveal(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.5)
    }
    static func select(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.3)
    }
    /// Fade and rise from below; fade only with Reduce Motion.
    static func rise(_ reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 14))
    }
}

extension View {
    /// Lets nearby glass morph between states (macOS 26+; no-op earlier).
    @ViewBuilder func detailGlassID(_ id: String, in namespace: Namespace.ID) -> some View {
        if #available(macOS 26, *) { glassEffectID(id, in: namespace) } else { self }
    }

    /// Section titles on the title page.
    func detailSectionHeader() -> some View {
        font(.title2.bold()).accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Hero pieces

/// "IMDb ★ 8.8". VoiceOver: "IMDb rating 8.8 out of 10".
struct RatingPill: View {
    let score: Double
    var body: some View {
        let value = score.formatted(.number.precision(.fractionLength(1)))
        HStack(spacing: 5) {
            Text(verbatim: "IMDb")
                .font(.caption.weight(.heavy))
                .foregroundStyle(.black)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color(red: 0.96, green: 0.77, blue: 0.09), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("IMDb rating \(value) out of 10"))
    }
}

/// Outlined age-rating badge, like "PG-13" in the TV app.
struct CertificationBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(.white.opacity(0.7), lineWidth: 1))
            .accessibilityLabel(Text("Rated \(text)"))
    }
}

/// Rating pill, age badge, then "2010 · 2 hr 28 min · Adventure, Sci-Fi, Thriller".
struct HeroFacts: View {
    let score: Double?
    let certification: String?
    let year: String?
    let runtime: String?
    let genres: [String]

    var body: some View {
        let genreText = genres.isEmpty ? nil : Array(genres.prefix(3)).formatted(.list(type: .and, width: .narrow))
        let parts = [year, runtime, genreText].compactMap { $0 }.filter { !$0.isEmpty }
        HStack(spacing: 10) {
            if let score { RatingPill(score: score) }
            if let certification { CertificationBadge(text: certification) }
            if !parts.isEmpty {
                Text(parts.joined(separator: " · "))
                    .font(.callout.weight(.medium)).foregroundStyle(.white.opacity(0.8))
            }
        }
    }
}

/// "Won 4 Oscars. 160 wins & 220 nominations total".
struct AwardsLine: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "trophy.fill")
            .font(.callout)
            .foregroundStyle(.white.opacity(0.8))
            .labelStyle(.titleAndIcon)
            .accessibilityLabel(Text("Awards: \(text)"))
    }
}

/// Description clamped to a few lines with a More/Less toggle, shown only when it's truncated.
struct ExpandableText: View {
    let text: String
    var lineLimit = 3
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var shownHeight: CGFloat = 0

    private var truncated: Bool { fullHeight > shownHeight + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .lineLimit(expanded ? nil : lineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shownHeight = $0 }
                .background(alignment: .topLeading) {
                    // Same text, unclamped and invisible: its height says whether the visible copy is cut off.
                    Text(text)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                        .accessibilityHidden(true)
                }
            if truncated || expanded {
                // The TV app's small "MORE" capsule.
                Button(expanded ? "LESS" : "MORE") {
                    withAnimation(DetailMotion.reveal(reduceMotion)) { expanded.toggle() }
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.white.opacity(0.18), in: Capsule())
                .contentShape(Capsule())
                .accessibilityLabel(expanded ? "Show less" : "Show full description")
                .accessibilityHint(expanded ? "Shows less of the description" : "Shows the full description")
            }
        }
        .onChange(of: text) { expanded = false }
    }
}

// MARK: - Episodes

/// Apple TV-style episodes shelf: season menu, then 16:9 cards with number, title, air date and synopsis.
struct EpisodesSection: View {
    let episodesBySeason: [Int: [Video]]
    let seasons: [Int]
    @Binding var season: Int
    let selectedId: String?
    let lastVideoId: String?
    let lastProgress: Double
    let isLoading: Bool
    let select: (Video) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Episodes").detailSectionHeader()
                Spacer()
                if seasons.count > 1 {
                    Picker("Season", selection: $season.animation(DetailMotion.reveal(reduceMotion))) {
                        ForEach(seasons, id: \.self) { Text("Season \($0)").tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Season")
                } else if let only = seasons.first {
                    Text("Season \(only)").font(.headline).foregroundStyle(.secondary)
                }
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        if isLoading {
                            // Same size as real cards so nothing below moves when episodes arrive.
                            ForEach(0..<4, id: \.self) { _ in EpisodeCardPlaceholder() }
                        } else {
                            ForEach(episodesBySeason[season] ?? []) { ep in
                                EpisodeCard(episode: ep,
                                            isSelected: ep.id == selectedId,
                                            progress: ep.id == lastVideoId ? lastProgress : nil,
                                            select: select)
                                .id(ep.id)
                            }
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.vertical, 4)   // room for the selection ring
                }
                .shelfPaging(ids: (episodesBySeason[season] ?? []).map(\.id), step: EpisodeCard.width + 16)
                .id(season)                  // new season: start at its first episode, crossfade the shelf
                .transition(.opacity)
                .onChange(of: selectedId, initial: true) { _, id in
                    guard let id else { return }
                    withAnimation(reduceMotion ? nil : .smooth) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }
}

struct EpisodeCard: View {
    static let width: CGFloat = 300
    let episode: Video
    let isSelected: Bool
    /// Playback progress when this is the last episode played.
    let progress: Double?
    let select: (Video) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var upcoming: Bool { episode.releaseDate.map { $0 > .now } ?? false }
    private var number: Int { episode.episode ?? 0 }
    private var title: String { episode.title ?? String(localized: "Episode \(number)") }

    var body: some View {
        Button { select(episode) } label: {
            VStack(alignment: .leading, spacing: 6) {
                thumbnail
                Text("E\(number) · \(title)")
                    .font(.headline).lineLimit(1)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                Group {
                    if let d = episode.releaseDate, upcoming {
                        Text("Coming \(d.formatted(.addonShortDay))")
                    } else if let d = episode.releaseDate {
                        Text(d.formatted(.addonShortDay))
                    } else {
                        Text(verbatim: " ")
                    }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(episode.overview ?? "")
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(3, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            .frame(width: Self.width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(upcoming ? 0.6 : 1)
        .scaleEffect(hovering && !reduceMotion ? 1.02 : 1)
        .animation(DetailMotion.select(reduceMotion), value: hovering)
        .animation(DetailMotion.select(reduceMotion), value: isSelected)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Episode \(number), \(title)"))
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Shows streams for this episode")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var accessibilityValue: Text {
        var parts: [String] = []
        if let d = episode.releaseDate {
            parts.append(upcoming ? String(localized: "Coming \(d.formatted(.addonDay))") : d.formatted(.addonDay))
        }
        if let p = progress {
            parts.append(p >= 0.92 ? String(localized: "Watched")
                                   : String(localized: "\(p.formatted(.percent.precision(.fractionLength(0)))) watched"))
        }
        if let o = episode.overview { parts.append(o) }
        return Text(parts.joined(separator: ". "))
    }

    private var thumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return ZStack(alignment: .bottomLeading) {
            Artwork(url: episode.thumbnail.flatMap(URL.init(string:)))
                .frame(width: Self.width, height: Self.width * 9 / 16)
                .clipped()

            if let p = progress {
                if p >= 0.92 {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3).symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.45))
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                } else if p > 0 {
                    ProgressView(value: min(max(p, 0), 1))
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .padding(10)
                }
            }

            if isSelected {
                Image(systemName: "play.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .glassSurface(Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .frame(width: Self.width, height: Self.width * 9 / 16)
        .clipShape(shape)
        .overlay(shape.strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                                    lineWidth: isSelected ? 3 : 1))
        .shadow(color: .black.opacity(hovering ? 0.25 : 0.12), radius: hovering ? 10 : 4, y: hovering ? 6 : 2)
    }
}

struct EpisodeCardPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary)
                .frame(width: EpisodeCard.width, height: EpisodeCard.width * 9 / 16)
            Text(verbatim: "E1 · Episode title").font(.headline)
            Text(verbatim: "Jan 1, 2000").font(.caption)
            Text(verbatim: "Episode synopsis").font(.callout).lineLimit(3, reservesSpace: true)
        }
        .frame(width: EpisodeCard.width, alignment: .leading)
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }
}

// MARK: - Cast & Crew

struct CastCrewSection: View {
    let people: [TitleInfo.Person]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cast & Crew").detailSectionHeader()
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 20) {
                    ForEach(people) { PersonTile(person: $0) }
                }
                .scrollTargetLayout()
            }
            .shelfPaging(ids: people.map(\.id), step: 112 + 20)
        }
    }
}

/// The add-on's headshot when it provides one (TMDB does, Cinemeta doesn't); otherwise a monogram
/// tinted from the name.
struct PersonTile: View {
    let person: TitleInfo.Person

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Monogram(name: person.name)
                if let photo = person.photo {
                    AsyncImage(url: photo, transaction: .init(animation: .easeOut(duration: 0.25))) { phase in
                        if let image = phase.image { image.resizable().scaledToFill().transition(.opacity) }
                    }
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.12)))
                    .accessibilityHidden(true)
                }
            }
            .frame(width: 96, height: 96)
            VStack(spacing: 2) {
                Text(person.name).font(.callout.weight(.medium)).lineLimit(2)
                Text(person.roleText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .multilineTextAlignment(.center)
        }
        .frame(width: 112)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(person.name))
        .accessibilityValue(Text(person.roleText))
    }
}

struct Monogram: View {
    let name: String

    private var initials: String {
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }
        let letters = [words.first, words.count > 1 ? words.last : nil].compactMap { $0?.first }
        return String(letters).uppercased()
    }
    /// Stable across launches (unlike `hashValue`), so a person keeps their color.
    private var hue: Double {
        Double(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % 360) / 360
    }

    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [Color(hue: hue, saturation: 0.32, brightness: 0.62),
                                          Color(hue: hue, saturation: 0.42, brightness: 0.38)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                Text(verbatim: initials)
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .overlay(Circle().strokeBorder(.white.opacity(0.12)))
            .accessibilityHidden(true)
    }
}

// MARK: - Information

/// The TV app's "Information" block: labelled facts in columns, plus a link out to IMDb.
struct InformationSection: View {
    let facts: [TitleInfo.Fact]
    let imdb: URL?
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Information").detailSectionHeader()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 28, alignment: .topLeading)],
                      alignment: .leading, spacing: 18) {
                ForEach(facts) { f in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(f.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        Text(f.value).font(.body).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(f.title))
                    .accessibilityValue(Text(f.accessibilityValue ?? f.value))
                }
            }
            if let imdb {
                Button { openURL(imdb) } label: {
                    Label("View on IMDb", systemImage: "arrow.up.right.square")
                }
                .nativeButtonStyle()
                .controlSize(.large)
                .help(imdb.absoluteString)
                .padding(.top, 4)
            }
        }
    }
}

