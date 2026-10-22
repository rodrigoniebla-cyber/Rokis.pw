// Mod Settings > Widgets (App/ModSettings.x links it from the root, under either look): how the widgets are lit,
// how often the moving ones step, how many are placed, and the App Group they are written into.
#import <UIKit/UIKit.h>
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "HomeWidgets.h"

UIViewController *SGHomeWidgetsSettingsPage(void) {
    SGModRow *background = SGChoiceRow(@"Background", nil, SGKeyHomeWidgetsBackground, @[@"Spotify black", @"Cover colour"], 0);
    background.choiceNotes = @[@"Near black, as Spotify's own widgets are", @"The cover's colour fading into black from the top"];
    SGModRow *rate = SGChoiceRow(@"Lyrics step", nil, SGKeyHomeWidgetsRate,
                                 @[@"Every second", @"Every 2 seconds", @"Every 5 seconds"], 1);
    rate.choiceNotes = @[@"The most lively, and the most battery", @"Lively without asking too much", @"Lightest on the battery"];
    rate.choiceFooter = @"A widget is a picture iOS draws again only when Spotify sends it something new, and iOS may hold back "
                         "pictures that come too fast, so the lines step rather than follow the singing exactly.";
    SGModRow *placed = SGStatRow(@"On your screens", ^NSString *{ return SGHomeWidgetsSummary(); });
    SGModRow *group = SGStatRow(@"App Group", ^NSString *{ return SGHomeWidgetsGroup() ?: @"None"; });
    NSString *footer = SGHomeWidgetsGroup()
        ? @"Touch and hold the Home Screen, tap Edit, then Add Widget, and pick Spotify: Now Playing (small, medium, large and the "
           "lock screen's) and Lyrics are the mod's. Their buttons play, pause, skip, like and shuffle in Spotify, and the "
           "large Now Playing plays a track up next when you tap it. The settings apply straight away."
        : @"This copy of Spotify is signed without an App Group, so the widgets have no way to read what Spotify plays. Sign the IPA "
           "with a certificate or app that gives it an App Group (the same one for the app and its extensions).";
    return [[SGModPage alloc] initWithTitle:@"Widgets" intro:nil sections:@[
        SGNotedSection(nil, @[background, rate], nil),
        SGNotedSection(nil, @[placed, group], footer),
    ] footer:nil];
}

NSString *SGHomeWidgetsSummary(void) {
    NSUInteger count = SGHomeWidgetsInstalledCount();
    return count == 0 ? @"None" : count == 1 ? @"1 widget" : [NSString stringWithFormat:@"%lu widgets", (unsigned long)count];
}
