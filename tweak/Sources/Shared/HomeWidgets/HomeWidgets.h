// The home screen and lock screen widgets (Mod Settings > Widgets), under either look: Now Playing, Visualizer
// and Lyrics, drawn by extension/LiveActivity/HomeWidgets.swift in the look of Spotify's own widgets.
//
//     HomeWidgets.x               what they show, written into an App Group, and WidgetKit asked to draw them again
//     HomeWidgetsBridge.swift     WidgetKit, which is Swift only
//     HomeWidgetsSettings.m       the page
//
// What they show is state.json and the cover in Library/SpotifyGlass/Widgets of the first App Group the app is
// signed with (sorted, as the App Group shim and the Live Activity pick it); the extension reads the newest of
// those in the groups it is signed with, so a signature that gives the widget none leaves it saying so. A tap on a
// control is SGWidgetActionIntent (Shared/LiveActivity/LiveActivityShared.swift), which runs in Spotify the
// Live Activity's actions. The fields of state.json are a contract with SGWidgetState in the extension.
// Threading: main thread only.
#import <Foundation/Foundation.h>

// How they are lit: Spotify's black (unset) or the cover's colour fading into it.
#define SGKeyHomeWidgetsBackground @"spotifyglass.homeWidgets.background"
// How often the Visualizer and Lyrics widgets are sent something new while a song plays and Spotify is away:
// an index into 1, 2 (unset) and 5 seconds.
#define SGKeyHomeWidgetsRate @"spotifyglass.homeWidgets.rate"

@class UIViewController;
UIViewController *SGHomeWidgetsSettingsPage(void);
NSString *SGHomeWidgetsSummary(void);   // how many are on the home and lock screens
NSUInteger SGHomeWidgetsInstalledCount(void);
NSString *SGHomeWidgetsGroup(void);     // the App Group they are written into, nil for none
void SGHomeWidgetsRefresh(void);        // writes and redraws them all now, for a setting that changed
