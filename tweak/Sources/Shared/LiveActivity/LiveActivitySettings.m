// The Live Activity page (App/ModSettings.x links it from the root, under either look).
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "LiveActivity.h"

static NSArray<NSString *> *viewNames(void) {
    return @[@"Lyrics", @"Queue", @"Control menu", @"Player"];
}

UIViewController *SGLiveActivitySettingsPage(void) {
    SGModRow *on = SGOptionRow(@"Live Activity", nil, SGKeyLiveActivity);
    on.changed = ^(BOOL value) { SGSetLiveActivityEnabled(value); };
    SGModRow *view = SGChoiceRow(@"Shows", nil, SGKeyLiveActivityView, viewNames(), SGLiveActivityLyrics);
    SGModRow *translation = SGSwitchRow(@"Translation", @"Under the line, where the lyrics have one", SGKeyLiveActivityTranslation);
    translation.visible = ^BOOL { return SGInt(SGKeyLiveActivityView, SGLiveActivityLyrics) == SGLiveActivityLyrics; };
    view.choiceNotes = @[@"The line being sung, and the next one", @"The tracks up next, a tap playing one",
                         @"Tabs of controls, the queue and a sleep timer", @"The cover, the controls and a bar to seek on"];
    return [[SGModPage alloc] initWithTitle:@"Live Activity" intro:nil sections:@[
        SGNotedSection(nil, @[on, view, translation],
                       @"The card takes the cover's colour and shows how far into the song you are; in Player, a tap along the bar "
                        "jumps there. It also appears on Apple Watch, in CarPlay and in StandBy, where iOS shows it."),
    ] footer:nil];
}

NSString *SGLiveActivitySummary(void) {
    if (!SGFlag(SGKeyLiveActivity, NO)) return @"Off";
    NSInteger index = SGInt(SGKeyLiveActivityView, SGLiveActivityLyrics);
    NSArray<NSString *> *names = viewNames();
    return index >= 0 && index < (NSInteger)names.count ? names[index] : names.firstObject;
}
