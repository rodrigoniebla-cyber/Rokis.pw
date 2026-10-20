// WidgetKit is Swift only, so HomeWidgets.x reaches it through this class.
import Foundation
import WidgetKit

@objc(SGHomeWidgetsBridge)
public final class SGHomeWidgetsBridge: NSObject {
    @objc public static let nowPlayingKind = SGHomeWidgetKind.nowPlaying
    @objc public static let visualizerKind = SGHomeWidgetKind.visualizer
    @objc public static let lyricsKind = SGHomeWidgetKind.lyrics

    @objc public static func reload(_ kinds: [String]) {
        for kind in kinds { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
    }

    // The kinds on the home and lock screens now, one entry per widget placed; `done` runs on the main queue.
    @objc public static func placed(_ done: @escaping ([String]) -> Void) {
        WidgetCenter.shared.getCurrentConfigurations { result in
            let kinds = (try? result.get())?.map(\.kind) ?? []
            DispatchQueue.main.async { done(kinds) }
        }
    }
}
