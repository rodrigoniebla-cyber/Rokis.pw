// The home screen widgets, drawn the way Spotify's own are: near black, white bold titles over grey, the
// Spotify mark in the corner, and the cover with rounded corners. Now Playing (the song and its controls, the
// tracks up next on the large one, and the lock screen's), Visualizer (the cover in a ring of the bars in the
// cover's colours) and Lyrics (the line being sung). Spotify writes what they show into an App Group
// (Shared/HomeWidgets), which this extension finds among its own entitlements, and asks WidgetKit to draw
// them again when it changes. A tap on a control is SGWidgetActionIntent, an audio playback intent iOS runs
// inside Spotify. Built with the Live Activity by scripts/build-extension.sh.
import AppIntents
import SwiftUI
import UIKit
import WidgetKit

// MARK: - What Spotify wrote

struct SGWidgetTrack: Codable, Hashable {
    var title: String
    var artist: String
    var uri: String
}

// Shared/HomeWidgets/HomeWidgets.x writes this as JSON; every field may be missing from an older writer.
struct SGWidgetState: Codable {
    var updated: Double?           // seconds since 1970 when it was written
    var track: String?
    var title: String?
    var artist: String?
    var paused: Bool?
    var liked: Bool?
    var shuffle: Bool?
    var repeatMode: Int?
    var duration: Double?          // seconds
    var position: Double?          // seconds into the track when it was written
    var cover: String?             // a file next to the state
    var tint: Int?                 // 0xRRGGBB, -1 unknown
    var colours: [Int]?            // the cover's main colours, darkest first
    var backlight: Bool?
    var bars: String?              // a hex digit a band, lowest first
    var line: String?
    var next: String?
    var upNext: [SGWidgetTrack]?
    var background: Int?           // 0 Spotify's black, 1 the cover's colour
}

private let spotifyGreen = Color(red: 0.118, green: 0.843, blue: 0.376)
private let spotifyBlack = Color(red: 0.071, green: 0.071, blue: 0.071)
private let spotifyGrey = Color(red: 0.702, green: 0.702, blue: 0.702)

// The App Groups this extension is signed with, read the way the app reads its own (LiveActivity.x).
private func entitledGroups() -> [String] {
    typealias Create = @convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?
    typealias Copy = @convention(c) (UnsafeRawPointer, CFString, UnsafeMutableRawPointer?) -> Unmanaged<AnyObject>?
    guard let handle = dlopen(nil, RTLD_NOW),
          let createSymbol = dlsym(handle, "SecTaskCreateFromSelf"),
          let copySymbol = dlsym(handle, "SecTaskCopyValueForEntitlement") else { return [] }
    let create = unsafeBitCast(createSymbol, to: Create.self), copy = unsafeBitCast(copySymbol, to: Copy.self)
    guard let task = create(nil) else { return [] }
    defer { Unmanaged<AnyObject>.fromOpaque(task).release() }
    guard let value = copy(task, "com.apple.security.application-groups" as CFString, nil)?.takeRetainedValue(),
          let groups = value as? [String] else { return [] }
    return groups.sorted()
}

struct SGWidgetEntry: TimelineEntry {
    let date: Date
    let state: SGWidgetState?
    let cover: UIImage?
    // Why there is nothing to show: no App Group to read, or nothing written into it yet.
    let noGroup: Bool
    var preview = false
}

private func loadEntry() -> SGWidgetEntry {
    let groups = entitledGroups()
    var newest: (url: URL, date: Date)?
    for group in groups {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { continue }
        let file = container.appendingPathComponent(SGHomeWidgetFolder).appendingPathComponent("state.json")
        guard let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
        if newest == nil || date > newest!.date { newest = (file, date) }
    }
    guard let file = newest?.url, let data = try? Data(contentsOf: file),
          let state = try? JSONDecoder().decode(SGWidgetState.self, from: data) else {
        return SGWidgetEntry(date: Date(), state: nil, cover: nil, noGroup: groups.isEmpty)
    }
    var cover: UIImage?
    if let name = state.cover, !name.isEmpty {
        cover = UIImage(contentsOfFile: file.deletingLastPathComponent().appendingPathComponent(name).path)
    }
    return SGWidgetEntry(date: Date(), state: state, cover: cover, noGroup: false)
}

private let sample = SGWidgetState(updated: Date().timeIntervalSince1970, track: "", title: "Song title", artist: "Artist",
                                   paused: false, liked: true, shuffle: false, repeatMode: 0, duration: 200, position: 70,
                                   cover: nil, tint: 0x1DB954, colours: [0x0B3D20, 0x1DB954, 0x9BF0B8], backlight: false,
                                   bars: "6a9c7b5869a7c8b6957a8c6b", line: "The line being sung", next: "and the one after it",
                                   upNext: [SGWidgetTrack(title: "Next song", artist: "Artist", uri: ""),
                                            SGWidgetTrack(title: "And another", artist: "Artist", uri: "")],
                                   background: 0)

struct SGWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> SGWidgetEntry {
        SGWidgetEntry(date: Date(), state: sample, cover: nil, noGroup: false, preview: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (SGWidgetEntry) -> Void) {
        let entry = loadEntry()
        completion(context.isPreview && entry.state == nil ? placeholder(in: context) : entry)
    }

    // One entry; Spotify asks for a new one whenever what it shows changes. A song playing is looked at again
    // when it should have ended, so a widget whose app has gone does not run its bar on forever.
    func getTimeline(in context: Context, completion: @escaping (Timeline<SGWidgetEntry>) -> Void) {
        let entry = loadEntry()
        let end = entry.state.flatMap { state in playing(state, at: entry.date) ? trackRange(state)?.upperBound : nil }
        completion(Timeline(entries: [entry], policy: end.map { .after($0.addingTimeInterval(2)) } ?? .never))
    }
}

// MARK: - Reading the state

private func trackRange(_ state: SGWidgetState) -> ClosedRange<Date>? {
    guard let duration = state.duration, duration > 0, let updated = state.updated else { return nil }
    let start = Date(timeIntervalSince1970: updated - (state.position ?? 0))
    return start...start.addingTimeInterval(duration)
}

// Playing, and still within the song it was playing when written.
private func playing(_ state: SGWidgetState, at date: Date) -> Bool {
    guard state.paused == false, let range = trackRange(state) else { return false }
    return date < range.upperBound
}

private func rgb(_ value: Int) -> Color {
    Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
}

private func luminance(_ value: Int) -> Double {
    0.2126 * Double((value >> 16) & 0xFF) / 255 + 0.7152 * Double((value >> 8) & 0xFF) / 255 + 0.0722 * Double(value & 0xFF) / 255
}

// Spotify's black, or the cover's colour fading into it from the top, the way Spotify's player is lit.
private struct WidgetBackground: View {
    let state: SGWidgetState?

    var body: some View {
        if let state, state.background == 1, let tint = state.tint, tint >= 0 {
            LinearGradient(colors: [rgb(tint).opacity(0.85), spotifyBlack], startPoint: .top, endPoint: .bottom)
                .background(spotifyBlack)
        } else {
            spotifyBlack
        }
    }
}

// MARK: - Pieces

// The Spotify mark: the green disc and its three sound waves.
struct SpotifyMark: View {
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            Circle().fill(spotifyGreen)
            Waves()
                .stroke(Color.black, style: StrokeStyle(lineWidth: size * 0.085, lineCap: .round))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Spotify")
    }

    private struct Waves: Shape {
        func path(in rect: CGRect) -> Path {
            let w = rect.width, h = rect.height
            var path = Path()
            for (y, inset, rise) in [(0.38, 0.22, 0.13), (0.54, 0.26, 0.10), (0.69, 0.30, 0.075)] {
                path.move(to: CGPoint(x: w * inset, y: h * y))
                path.addQuadCurve(to: CGPoint(x: w * (1 - inset + 0.02), y: h * (y + rise * 0.55)),
                                  control: CGPoint(x: w * 0.5, y: h * (y - rise)))
            }
            return path
        }
    }
}

private struct Cover: View {
    let image: UIImage?
    let state: SGWidgetState?
    var corner: CGFloat = 6

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [rgb(state?.tint ?? 0x333333).opacity(0.9), Color(white: 0.16)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.title2.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

private struct Titles: View {
    let state: SGWidgetState
    var titleSize: CGFloat = 15

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.title ?? "")
                .font(.system(size: titleSize, weight: .bold))
                .foregroundStyle(.white)
            Text(state.artist ?? "")
                .font(.system(size: titleSize - 2, weight: .regular))
                .foregroundStyle(spotifyGrey)
        }
        .lineLimit(1)
        .invalidatableContent()
    }
}

private struct TrackBar: View {
    let state: SGWidgetState
    let date: Date
    var times = true

    var body: some View {
        VStack(spacing: 3) {
            Group {
                if playing(state, at: date), let range = trackRange(state) {
                    ProgressView(timerInterval: range, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                } else {
                    ProgressView(value: min(1, max(0, (state.position ?? 0) / max(1, state.duration ?? 1))))
                }
            }
            .progressViewStyle(.linear)
            .tint(.white)
            .scaleEffect(x: 1, y: 0.75, anchor: .center)
            if times, let range = trackRange(state) {
                HStack {
                    if playing(state, at: date) {
                        Text(timerInterval: range, countsDown: false)
                        Spacer(minLength: 0)
                        Text(timerInterval: range, countsDown: true)
                    } else {
                        Text(clock(state.position ?? 0))
                        Spacer(minLength: 0)
                        Text("-" + clock((state.duration ?? 0) - (state.position ?? 0)))
                    }
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(spotifyGrey)
            }
        }
    }
}

private func clock(_ seconds: Double) -> String {
    let whole = max(0, Int(seconds.rounded()))
    return String(format: "%d:%02d", whole / 60, whole % 60)
}

// The play button: a white disc with a black glyph, as in Spotify's player. A toggle, so its look flips the
// moment it is tapped, before Spotify has answered.
private struct PlayStyle: ToggleStyle {
    var size: CGFloat = 36

    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            Circle().fill(.white)
            Image(systemName: configuration.isOn ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.black)
                .offset(x: configuration.isOn ? 0 : size * 0.04)
        }
        .frame(width: size, height: size)
    }
}

private struct GlyphStyle: ToggleStyle {
    let symbol: String
    let onSymbol: String
    var size: CGFloat = 18

    func makeBody(configuration: Configuration) -> some View {
        Image(systemName: configuration.isOn ? onSymbol : symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(configuration.isOn ? spotifyGreen : .white)
            .frame(minWidth: 28, minHeight: 28)
            .contentShape(Rectangle())
    }
}

private struct Glyph: View {
    let symbol: String
    let action: String
    var size: CGFloat = 18

    var body: some View {
        Button(intent: SGWidgetActionIntent(action)) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(minWidth: 28, minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct Controls: View {
    let state: SGWidgetState
    let date: Date
    var play: CGFloat = 36
    var glyph: CGFloat = 18
    var extras = true

    var body: some View {
        HStack(spacing: 0) {
            if extras {
                Toggle(isOn: state.liked == true, intent: SGWidgetActionIntent("like")) { EmptyView() }
                    .toggleStyle(GlyphStyle(symbol: "heart", onSymbol: "heart.fill", size: glyph * 0.9))
                Spacer(minLength: 0)
            }
            Glyph(symbol: "backward.end.fill", action: "previous", size: glyph)
            Spacer(minLength: 0)
            Toggle(isOn: playing(state, at: date), intent: SGWidgetActionIntent("toggle")) { EmptyView() }
                .toggleStyle(PlayStyle(size: play))
            Spacer(minLength: 0)
            Glyph(symbol: "forward.end.fill", action: "next", size: glyph)
            if extras {
                Spacer(minLength: 0)
                Toggle(isOn: state.shuffle == true, intent: SGWidgetActionIntent("shuffle")) { EmptyView() }
                    .toggleStyle(GlyphStyle(symbol: "shuffle", onSymbol: "shuffle", size: glyph * 0.85))
            }
        }
    }
}

// Nothing to show yet: Spotify has not played since the widget was added, or the signature gave the widget no
// App Group to read Spotify's from.
private struct Empty: View {
    let entry: SGWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer()
                SpotifyMark(size: 20)
            }
            Spacer(minLength: 0)
            Text(entry.noGroup ? "Widget can't reach Spotify" : "Play something")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
            Text(entry.noGroup ? "Sign the IPA with an App Group" : "Open Spotify and play a song")
                .font(.system(size: 12))
                .foregroundStyle(spotifyGrey)
        }
        .lineLimit(2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// MARK: - The visualizer's ring

private struct Ring: View {
    let state: SGWidgetState
    let cover: UIImage?
    let size: CGFloat

    var body: some View {
        let heard = (state.bars ?? "").compactMap { $0.hexDigitValue }.map { Double($0) / 15 }
        let bands = heard.isEmpty ? 32 : heard.count
        let count = bands * 2
        let inner = size * 0.32
        let reach = size * 0.16
        let width = max(1.5, size * 0.024)
        let colours = (state.colours ?? []).map(rgb)
        let fill: AnyShapeStyle = colours.count > 1
            ? AnyShapeStyle(LinearGradient(colors: colours, startPoint: .bottom, endPoint: .top))
            : AnyShapeStyle(colours.first ?? spotifyGreen)
        ZStack {
            if state.backlight == true {
                let values = state.colours ?? []
                let light = values.isEmpty ? 1 : values.map(luminance).reduce(0, +) / Double(values.count)
                let glow = light < 0.45 ? Color.white.opacity(0.42) : Color.black.opacity(0.62)
                Circle()
                    .fill(RadialGradient(gradient: Gradient(stops: [
                        .init(color: glow, location: 0),
                        .init(color: glow, location: min(0.95, (inner + 2 + reach * 0.6) / (size / 2))),
                        .init(color: glow.opacity(0), location: 1),
                    ]), center: .center, startRadius: 0, endRadius: size / 2))
            }
            ForEach(0..<count, id: \.self) { index in
                let band = index < bands ? index : count - 1 - index
                let level = band < heard.count ? heard[band] : 0.08
                let length = width + reach * level
                Capsule()
                    .fill(fill)
                    .frame(width: width, height: length)
                    .offset(y: -(inner + 3 + length / 2))
                    .rotationEffect(.degrees((Double(index) + 0.5) * 360 / Double(count)))
            }
            Cover(image: cover, state: state, corner: inner)
                .frame(width: inner * 2, height: inner * 2)
                .clipShape(Circle())
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Now Playing

struct SGNowPlayingView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SGWidgetEntry

    var body: some View {
        Group {
            if let state = entry.state {
                switch family {
                case .accessoryRectangular: rectangular(state)
                case .accessoryCircular: circular(state)
                case .systemMedium: medium(state)
                case .systemLarge: large(state)
                default: small(state)
                }
            } else if family == .accessoryRectangular || family == .accessoryCircular {
                Image(systemName: "music.note")
            } else {
                Empty(entry: entry)
            }
        }
        .widgetURL(URL(string: "spotify:"))
        .containerBackground(for: .widget) { WidgetBackground(state: entry.state) }
    }

    private func small(_ state: SGWidgetState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Cover(image: entry.cover, state: state).frame(width: 52, height: 52)
                Spacer(minLength: 0)
                SpotifyMark(size: 20)
            }
            Spacer(minLength: 4)
            Titles(state: state, titleSize: 14)
            Spacer(minLength: 4)
            Controls(state: state, date: entry.date, play: 30, glyph: 16, extras: false)
        }
    }

    private func medium(_ state: SGWidgetState) -> some View {
        HStack(spacing: 14) {
            Cover(image: entry.cover, state: state)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Titles(state: state)
                    Spacer(minLength: 4)
                    SpotifyMark(size: 20)
                }
                Spacer(minLength: 4)
                TrackBar(state: state, date: entry.date)
                Spacer(minLength: 4)
                Controls(state: state, date: entry.date, play: 34, glyph: 17)
            }
        }
    }

    private func large(_ state: SGWidgetState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                Cover(image: entry.cover, state: state, corner: 8).frame(width: 112, height: 112)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        Spacer(minLength: 0)
                        SpotifyMark(size: 22)
                    }
                    Spacer(minLength: 4)
                    Titles(state: state, titleSize: 17)
                    Spacer(minLength: 8)
                    TrackBar(state: state, date: entry.date)
                }
            }
            Controls(state: state, date: entry.date, play: 44, glyph: 20)
            Text("Up next")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
            let upNext = Array((state.upNext ?? []).prefix(3))
            if upNext.isEmpty {
                Text("Nothing up next").font(.system(size: 13)).foregroundStyle(spotifyGrey)
            }
            ForEach(Array(upNext.enumerated()), id: \.offset) { _, track in
                Button(intent: SGWidgetActionIntent("queue:" + track.uri)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        Text(track.artist).font(.system(size: 12)).foregroundStyle(spotifyGrey)
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    private func rectangular(_ state: SGWidgetState) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(state.title ?? "").font(.headline).widgetAccentable()
            Text(state.artist ?? "").font(.caption).foregroundStyle(.secondary)
            TrackBar(state: state, date: entry.date, times: false)
        }
        .lineLimit(1)
    }

    // Play and pause on the lock screen.
    private func circular(_ state: SGWidgetState) -> some View {
        Toggle(isOn: playing(state, at: entry.date), intent: SGWidgetActionIntent("toggle")) { EmptyView() }
            .toggleStyle(CircularStyle())
    }

    private struct CircularStyle: ToggleStyle {
        func makeBody(configuration: Configuration) -> some View {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: configuration.isOn ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .bold))
            }
        }
    }
}

struct SGNowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SGHomeWidgetKind.nowPlaying, provider: SGWidgetProvider()) { entry in
            SGNowPlayingView(entry: entry)
        }
        .configurationDisplayName("Now Playing")
        .description("The song playing, with play, skip, like and shuffle.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryCircular])
    }
}

// MARK: - Visualizer

struct SGVisualizerWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SGWidgetEntry

    var body: some View {
        Group {
            if let state = entry.state {
                switch family {
                case .systemMedium:
                    HStack(spacing: 12) {
                        Ring(state: state, cover: entry.cover, size: 130)
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(alignment: .top) {
                                Titles(state: state)
                                Spacer(minLength: 4)
                                SpotifyMark(size: 20)
                            }
                            Spacer(minLength: 4)
                            TrackBar(state: state, date: entry.date, times: false)
                            Spacer(minLength: 4)
                            Controls(state: state, date: entry.date, play: 34, glyph: 17, extras: false)
                        }
                        .padding(.vertical, 16)
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, 16)
                case .systemLarge:
                    ZStack(alignment: .topTrailing) {
                        VStack(spacing: 10) {
                            Ring(state: state, cover: entry.cover, size: 180)
                            Titles(state: state, titleSize: 17)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            TrackBar(state: state, date: entry.date, times: false)
                            Controls(state: state, date: entry.date, play: 44, glyph: 20)
                        }
                        SpotifyMark(size: 22)
                    }
                    .padding(16)
                default:
                    ZStack(alignment: .topTrailing) {
                        Ring(state: state, cover: entry.cover, size: 150)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        SpotifyMark(size: 18)
                            .padding(10)
                    }
                }
            } else {
                Empty(entry: entry).padding(16)
            }
        }
        .widgetURL(URL(string: "spotify:"))
        .containerBackground(for: .widget) { WidgetBackground(state: entry.state) }
    }
}

struct SGVisualizerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SGHomeWidgetKind.visualizer, provider: SGWidgetProvider()) { entry in
            SGVisualizerWidgetView(entry: entry)
        }
        .configurationDisplayName("Visualizer")
        .description("The cover in a ring of bars that move with the music, in the cover's colours.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

// MARK: - Lyrics

struct SGLyricsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SGWidgetEntry

    var body: some View {
        Group {
            if let state = entry.state {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Cover(image: entry.cover, state: state, corner: 4).frame(width: 28, height: 28)
                        Titles(state: state, titleSize: 13)
                        Spacer(minLength: 4)
                        SpotifyMark(size: 20)
                    }
                    Spacer(minLength: 0)
                    let line = state.line ?? ""
                    Text(line.isEmpty ? "♪" : line)
                        .font(.system(size: family == .systemLarge ? 26 : 20, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(family == .systemLarge ? 4 : 2)
                        .minimumScaleFactor(0.75)
                        .contentTransition(.opacity)
                    if let next = state.next, !next.isEmpty {
                        Text(next)
                            .font(.system(size: family == .systemLarge ? 20 : 15, weight: .bold))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(family == .systemLarge ? 3 : 1)
                    }
                    Spacer(minLength: 0)
                    if family == .systemLarge {
                        TrackBar(state: state, date: entry.date, times: false)
                    }
                }
            } else {
                Empty(entry: entry)
            }
        }
        .widgetURL(URL(string: "spotify:"))
        .containerBackground(for: .widget) {
            // The lyrics are lit by the cover the way Spotify's lyrics card is, whatever the background chosen.
            if let tint = entry.state?.tint, tint >= 0 {
                LinearGradient(colors: [rgb(tint).opacity(0.9), rgb(tint).opacity(0.55)], startPoint: .top, endPoint: .bottom)
                    .background(spotifyBlack)
            } else {
                spotifyBlack
            }
        }
    }
}

struct SGLyricsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SGHomeWidgetKind.lyrics, provider: SGWidgetProvider()) { entry in
            SGLyricsWidgetView(entry: entry)
        }
        .configurationDisplayName("Lyrics")
        .description("The line being sung, and the one after it.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
