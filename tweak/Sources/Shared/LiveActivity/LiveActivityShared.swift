// Compiled into both the tweak and extension/LiveActivity: ActivityKit pairs the two sides by the
// attributes' type name and App Intents by the intent's, so this must stay identical in both.
import ActivityKit
import AppIntents
import Foundation

@available(iOS 16.1, *)
struct SGLyricsAttributes: ActivityAttributes {
    // Which of the four the activity shows, SGLiveActivityView's values.
    enum View: Int, Codable, Hashable {
        case lyrics, queue, panel, player
    }

    // The control menu's tabs.
    enum Tab: Int, Codable, Hashable, CaseIterable {
        case controls, queue, timer
    }

    struct Track: Codable, Hashable {
        var title: String
        var artist: String
        // What a tap on the track asks the player for.
        var uri: String
    }

    struct ContentState: Codable, Hashable {
        var view: View
        var paused: Bool
        // Lyrics: the line being sung and the one after it.
        var line: String
        var nextLine: String
        // Queue, and the control menu's queue tab: the tracks up next.
        var tracks: [Track]
        // The control menu.
        var tab: Tab
        var title: String
        var artist: String
        var shuffle: Bool
        var repeatMode: Int   // 0 off, 1 the playlist or album, 2 the track
        var timerEnd: Date?   // the sleep timer's end, nil when none is set
        var timerEndOfTrack: Bool
        // The track playing was saved to Liked Songs from the card this session.
        var liked: Bool
        // The sung line in the Lyrics page's translation language, "" for none.
        var translation: String
        // The cover's colour as 0xRRGGBB, -1 before it is known.
        var tint: Int
        // How far into the track: while it plays the bar runs on its own from start to end; paused, it
        // stands at progress (0...1), and start and end are nil.
        var progress: Double
        var trackStart: Date?
        var trackEnd: Date?
        // The player view. Optional, so a state from before them still decodes.
        // The visualizer's bars, a hex digit (0...f) each, lowest band first; "" without them.
        var bars: String?
        // The cover's main colours as 0xRRGGBB, darkest first, for the bars' gradient.
        var barColours: [Int]?
        // The cover: a file the app writes into an App Group, read when the widget may open that group, and a
        // small picture carried in the state for when it may not (left out when the state would be too big).
        var coverGroup: String?
        var coverKey: String?
        var coverThumbnail: Data?
        // The track's length in seconds, for the times by the bar and for a tap on it to seek to.
        var duration: Double?
        // The visualizer's Backlight: a glow behind the bars, white behind dark ones and black behind light ones.
        var backlight: Bool?
    }
}

// LiveActivityIntents run in the app's process, where the tweak acts on these notifications.
let SGLiveActivityPlayNotification = Notification.Name("SGLiveActivityPlay")
let SGLiveActivityActionNotification = Notification.Name("SGLiveActivityAction")

@available(iOS 17.0, *)
struct SGPlayQueuedTrackIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Play a track up next"
    static let isDiscoverable = false

    @Parameter(title: "Track")
    var uri: String

    init() {}

    init(_ uri: String) {
        self.uri = uri
    }

    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: SGLiveActivityPlayNotification, object: uri)
        return .result()
    }
}

// A control menu action: tab:N, toggle, previous, next, shuffle, repeat, like, dislike,
// timer:15|30|60|track|add|cancel, seek:F (F the share of the track, 0...1).
@available(iOS 17.0, *)
struct SGLiveActivityActionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Control menu action"
    static let isDiscoverable = false

    @Parameter(title: "Action")
    var action: String

    init() {}

    init(_ action: String) {
        self.action = action
    }

    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: SGLiveActivityActionNotification, object: action)
        return .result()
    }
}

// Where the app keeps the cover for the player view, inside an App Group's container.
let SGLiveActivityCoverFolder = "Library/SpotifyGlass/LiveActivity"

// MARK: - The home screen widgets (extension/LiveActivity/HomeWidgets.swift, Shared/HomeWidgets)

// Their kinds, which Spotify names to have them drawn again.
enum SGHomeWidgetKind {
    static let nowPlaying = "rokis.nowPlaying"
    static let visualizer = "rokis.visualizer"
    static let lyrics = "rokis.lyrics"
}

// Where Spotify writes what they show (state.json and the cover), inside an App Group's container.
let SGHomeWidgetFolder = "Library/SpotifyGlass/Widgets"

// A tap on a home screen or lock screen widget: one of SGLiveActivityActionIntent's actions, or queue:URI to skip
// ahead to a track up next. An audio playback intent, so iOS runs it inside Spotify, waking it in the background
// when it is not running, rather than in the widget's extension.
@available(iOS 17.0, *)
struct SGWidgetActionIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Widget control"
    static let isDiscoverable = false

    @Parameter(title: "Action")
    var action: String

    init() {}

    init(_ action: String) {
        self.action = action
    }

    func perform() async throws -> some IntentResult {
        if action.hasPrefix("queue:") {
            NotificationCenter.default.post(name: SGLiveActivityPlayNotification, object: String(action.dropFirst(6)))
        } else {
            NotificationCenter.default.post(name: SGLiveActivityActionNotification, object: action)
        }
        return .result()
    }
}
