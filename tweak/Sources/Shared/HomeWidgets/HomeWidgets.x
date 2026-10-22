// What the home screen widgets show (HomeWidgets.h), written whenever it changes: the song, paused or playing,
// liked, shuffle, the tracks up next and the cover with its colours at once, on every change the player
// reports; and, while a Lyrics widget is placed and a song plays, the line being sung as often as Mod Settings >
// Widgets asks. A widget is a picture iOS draws again only when asked, and it may hold back asks that come too
// fast, so the line steps rather than moves with the singing. The visualizer is the app's alone: no widget has bars.
#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Headers/SPTPlayer.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Player/SGLibrary.h"
#import "Shared/LiveActivity/LiveActivity.h"
#import "Shared/Visualizer/Visualizer.h"
#import "Shared/Visualizer/SGCoverPalette.h"
#import "HomeWidgets.h"

typedef struct __SecTask *SecTaskRef;
extern SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error);

@interface SGHomeWidgetsBridge : NSObject
@property (class, nonatomic, readonly, copy) NSString *nowPlayingKind;
@property (class, nonatomic, readonly, copy) NSString *lyricsKind;
+ (void)reload:(NSArray<NSString *> *)kinds;
+ (void)placed:(void (^)(NSArray<NSString *> *kinds))done;
@end

static const NSTimeInterval kTick = 1;
// How often the widgets placed are asked after, should one be added or taken away while Spotify runs.
static const NSTimeInterval kPlacedEvery = 30;
static const CGFloat kCoverSide = 360;
static const NSUInteger kUpNext = 3;
static const NSInteger kBreakMs = 4000;

static NSArray<NSString *> *sg_placed;
static NSTimer *sg_ticker;
// What was last written: the part every widget shows and the line, and when the line went.
static NSString *sg_common, *sg_line = @"", *sg_next = @"";
static CFTimeInterval sg_lineAt;
static NSString *sg_askedLyrics;

static void update(BOOL force);

// MARK: - Where it goes

static NSURL *widgetFolder(NSString **groupOut) {
    static NSURL *folder;
    static NSString *group;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SecTaskRef task = SecTaskCreateFromSelf(NULL);
        NSArray *groups = nil;
        if (task) {
            groups = CFBridgingRelease(SecTaskCopyValueForEntitlement(task, CFSTR("com.apple.security.application-groups"), NULL));
            CFRelease(task);
        }
        if (![groups isKindOfClass:NSArray.class]) groups = @[];
        for (NSString *candidate in [groups sortedArrayUsingSelector:@selector(compare:)]) {
            if (![candidate isKindOfClass:NSString.class]) continue;
            NSURL *container = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:candidate];
            if (!container) continue;
            folder = [container URLByAppendingPathComponent:@"Library/SpotifyGlass/Widgets" isDirectory:YES];
            [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
            group = candidate;
            break;
        }
        SGLog(@"widgets: %@", group ? [@"written into the App Group " stringByAppendingString:group] : @"no App Group to write into");
    });
    if (groupOut) *groupOut = group;
    return folder;
}

NSString *SGHomeWidgetsGroup(void) {
    NSString *group = nil;
    widgetFolder(&group);
    return group;
}

// MARK: - The cover

static NSString *sg_coverTrack, *sg_coverFile;
static NSInteger sg_tint = -1;
static NSArray<NSNumber *> *sg_colours;
static BOOL sg_coverReading;
static __weak MPMediaItemArtwork *sg_coverArtwork;
static NSInteger sg_coverWay;
// Spotify hands the system a new track a moment before its cover; the last cover is not read for the new
// track until it has stayed this long.
static CFTimeInterval sg_coverStaleSince;

static NSInteger rgbOf(UIColor *colour) {
    CGFloat r = 0, g = 0, b = 0;
    [colour getRed:&r green:&g blue:&b alpha:NULL];
    return (NSInteger)lround(r * 255) << 16 | (NSInteger)lround(g * 255) << 8 | (NSInteger)lround(b * 255);
}

// The cover's average colour, a little brightened, as the Live Activity tints its card.
static NSInteger tintOf(UIImage *image) {
    if (!image.CGImage) return -1;
    unsigned char pixel[4] = {0};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixel, 1, 1, 8, 4, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!context) return -1;
    CGContextSetInterpolationQuality(context, kCGInterpolationMedium);
    CGContextDrawImage(context, CGRectMake(0, 0, 1, 1), image.CGImage);
    CGContextRelease(context);
    CGFloat hue, saturation, brightness;
    UIColor *average = [UIColor colorWithRed:pixel[0] / 255.0 green:pixel[1] / 255.0 blue:pixel[2] / 255.0 alpha:1];
    [average getHue:&hue saturation:&saturation brightness:&brightness alpha:NULL];
    return rgbOf([UIColor colorWithHue:hue saturation:MIN(1, saturation * 1.2) brightness:MAX(0.45, brightness) alpha:1]);
}

// Read once per track, off the main thread (Spotify's artwork handler may wait on it), from the artwork Spotify
// hands the system's now playing; written as cover-<track>.jpg, the last one's file going.
static void refreshCover(NSString *trackID) {
    NSURL *folder = widgetFolder(NULL);
    if (!trackID || !folder || sg_coverReading) return;
    id artwork = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo[MPMediaItemPropertyArtwork];
    if (![artwork isKindOfClass:MPMediaItemArtwork.class]) return;
    NSInteger way = SGCoverPaletteWay();
    BOOL sameTrack = [trackID isEqualToString:sg_coverTrack];
    if (sameTrack && artwork == sg_coverArtwork && way == sg_coverWay) return;
    if (!sameTrack && artwork == sg_coverArtwork) {
        CFTimeInterval now = CACurrentMediaTime();
        if (!sg_coverStaleSince) sg_coverStaleSince = now;
        if (now - sg_coverStaleSince < 4) return;
    }
    sg_coverStaleSince = 0;
    sg_coverArtwork = artwork;
    sg_coverTrack = [trackID copy];
    sg_coverWay = way;
    sg_coverReading = YES;
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("spotifyglass.widgets.cover", DISPATCH_QUEUE_SERIAL); });
    MPMediaItemArtwork *cover = artwork;
    NSString *track = sg_coverTrack;
    dispatch_async(queue, ^{
        UIImage *image = [cover imageWithSize:CGSizeMake(kCoverSide, kCoverSide)];
        NSString *name = nil;
        NSInteger tint = -1;
        NSMutableArray<NSNumber *> *colours = [NSMutableArray array];
        if (image.CGImage) {
            UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
            format.scale = 1;
            format.opaque = YES;
            UIImage *square = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(kCoverSide, kCoverSide) format:format]
                               imageWithActions:^(UIGraphicsImageRendererContext *context) {
                [image drawInRect:CGRectMake(0, 0, kCoverSide, kCoverSide)];
            }];
            NSString *file = [NSString stringWithFormat:@"cover-%@.jpg", [track stringByReplacingOccurrencesOfString:@"/" withString:@"_"]];
            if ([UIImageJPEGRepresentation(square, 0.82) writeToURL:[folder URLByAppendingPathComponent:file] options:NSDataWritingAtomic error:nil]) {
                name = file;
                for (NSURL *old in [NSFileManager.defaultManager contentsOfDirectoryAtURL:folder includingPropertiesForKeys:nil options:0 error:nil]) {
                    if ([old.lastPathComponent hasPrefix:@"cover-"] && ![old.lastPathComponent isEqualToString:file])
                        [NSFileManager.defaultManager removeItemAtURL:old error:nil];
                }
            }
            tint = tintOf(square);
            NSArray<UIColor *> *palette = SGCoverPaletteOfImage(square);
            NSArray<UIColor *> *ordered = SGVisualizerGradientStops(palette, SGVisualizerGradientAlong, NO, NO);
            for (UIColor *colour in palette.count > 1 ? ordered : palette) [colours addObject:@(rgbOf(colour))];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            sg_coverReading = NO;
            if (![track isEqualToString:sg_coverTrack]) return;
            sg_coverFile = name;
            sg_tint = tint;
            sg_colours = colours;
            update(NO);
        });
    });
}

// MARK: - What they show

static NSString *uriOf(SPTPlayerTrack *track) {
    id uri = track.URI;
    if ([uri isKindOfClass:NSURL.class]) return [(NSURL *)uri absoluteString];
    return [uri isKindOfClass:NSString.class] ? uri : nil;
}

static NSArray<NSDictionary *> *upNextOf(SPTPlayerState *state) {
    NSMutableArray<NSDictionary *> *tracks = [NSMutableArray array];
    id future = [state respondsToSelector:@selector(future)] ? state.future : nil;
    for (id track in [future isKindOfClass:NSArray.class] ? future : @[]) {
        if (tracks.count == kUpNext) break;
        if (![track isKindOfClass:objc_getClass("SPTPlayerTrack")]) continue;
        NSString *title = [(SPTPlayerTrack *)track trackTitle], *uri = uriOf(track);
        if (!title.length || !uri) continue;
        [tracks addObject:@{@"title": title, @"artist": [(SPTPlayerTrack *)track artistName] ?: @"", @"uri": uri}];
    }
    return tracks;
}

// The line being sung and the one after it; "" before the first line, in a long break and without timed lyrics.
static NSString *lineOf(NSString *trackID, NSInteger ms, NSString **next) {
    *next = @"";
    NSArray<SGKaraokeLine *> *lines = trackID ? SGKaraokeLinesForTrack(trackID) : nil;
    if (!lines) {
        if (trackID && ![trackID isEqualToString:sg_askedLyrics]) {
            sg_askedLyrics = trackID;
            SGKaraokeRequestLyrics(trackID);
        }
        return @"";
    }
    if (SGKaraokeLinesTiming(lines) == SGKaraokeTimingNone || ms < 0) return @"";
    NSInteger index = SGKaraokeLeadLine(lines, ms);
    if (index + 1 < (NSInteger)lines.count) *next = SGKaraokeLineText(lines[index + 1]);
    if (index < 0) return @"";
    BOOL farOff = index + 1 == (NSInteger)lines.count || lines[index + 1].start - ms > kBreakMs;
    return ms > SGKaraokeSungEnd(lines[index]) + kBreakMs && farOff ? @"" : SGKaraokeLineText(lines[index]);
}

static NSUInteger placedCount(NSString *kind) {
    NSUInteger count = 0;
    for (NSString *placed in sg_placed) if ([placed isEqualToString:kind]) count++;
    return count;
}

static NSTimeInterval stepEvery(void) {
    static const NSTimeInterval steps[] = {1, 2, 5};
    return steps[MAX(0, MIN(2, SGInt(SGKeyHomeWidgetsRate, 1)))];
}

static void update(BOOL force) {
    NSURL *folder = widgetFolder(NULL);
    id<SPTPlayer> player = SGKaraokePlayer();
    SPTPlayerState *state = player.state ?: SGPlayerState();
    SPTPlayerTrack *track = state.track;
    if (!folder || !track.trackTitle.length) return;
    NSString *trackID = SGKaraokePlayingTrack();
    refreshCover(trackID);
    BOOL paused = state.isPaused || !state.isPlaying;
    double duration = [state respondsToSelector:@selector(duration)] ? state.duration : 0;
    NSInteger ms = SGKaraokePositionMs();
    double position = MAX(0, ms / 1000.0);
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    BOOL liked = SGLiveActivityLiked(trackID) || SGLibrarySavedThisSession(trackID);
    SPTPlayerOptions *options = state.options;
    NSInteger repeatMode = options.repeatingTrack ? 2 : options.repeatingContext ? 1 : 0;
    NSArray<NSDictionary *> *upNext = upNextOf(state);
    NSString *cover = [trackID isEqualToString:sg_coverTrack] && !sg_coverReading ? sg_coverFile : nil;
    NSInteger background = SGInt(SGKeyHomeWidgetsBackground, 0);
    // Playing, the widget's bar runs on its own from the start of the track, so only a seek moves it: the start
    // is compared in steps of two seconds; paused, the position itself.
    long long anchor = paused ? llround(position) : llround((now - position) / 2);
    NSMutableArray<NSString *> *upNextText = [NSMutableArray array];
    for (NSDictionary *upcoming in upNext) [upNextText addObject:upcoming[@"uri"]];
    NSString *common = [@[trackID ?: @"", track.trackTitle, track.artistName ?: @"", paused ? @"1" : @"0", @(anchor).stringValue,
                          liked ? @"1" : @"0", options.shufflingContext ? @"1" : @"0", @(repeatMode).stringValue,
                          cover ?: @"", @(sg_tint).stringValue, [sg_colours componentsJoinedByString:@","],
                          @(background).stringValue, [upNextText componentsJoinedByString:@","]]
                        componentsJoinedByString:@"\n"];

    CFTimeInterval clock = CACurrentMediaTime();
    NSTimeInterval every = stepEvery();
    NSString *line = sg_line, *next = sg_next;
    if (placedCount(SGHomeWidgetsBridge.lyricsKind) > 0 && (clock - sg_lineAt >= every - 0.05 || ![common isEqualToString:sg_common])) {
        line = lineOf(trackID, ms, &next);
        sg_lineAt = clock;
    }

    NSMutableArray<NSString *> *kinds = [NSMutableArray array];
    if (force || ![common isEqualToString:sg_common]) {
        [kinds addObjectsFromArray:@[SGHomeWidgetsBridge.nowPlayingKind, SGHomeWidgetsBridge.lyricsKind]];
    } else {
        if (![line isEqualToString:sg_line] || ![next isEqualToString:sg_next]) [kinds addObject:SGHomeWidgetsBridge.lyricsKind];
    }
    if (!kinds.count) return;
    sg_common = common; sg_line = line; sg_next = next;

    NSDictionary *written = @{
        @"updated": @(now), @"track": trackID ?: @"", @"title": track.trackTitle, @"artist": track.artistName ?: @"",
        @"paused": @(paused), @"liked": @(liked), @"shuffle": @(options.shufflingContext), @"repeatMode": @(repeatMode),
        @"duration": @(duration), @"position": @(position), @"cover": cover ?: @"", @"tint": @(sg_tint), @"colours": sg_colours ?: @[],
        @"line": line, @"next": next, @"upNext": upNext, @"background": @(background),
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:written options:0 error:nil];
    if (![data writeToURL:[folder URLByAppendingPathComponent:@"state.json"] options:NSDataWritingAtomic error:nil]) return;
    [SGHomeWidgetsBridge reload:kinds];
}

// MARK: - When

// Ticks while a widget is placed, for what the player does not report: the line, a like, a seek.
static void followPlaced(void) {
    if (sg_placed.count && !sg_ticker) {
        sg_ticker = [NSTimer timerWithTimeInterval:kTick repeats:YES block:^(NSTimer *timer) { update(NO); }];
        sg_ticker.tolerance = 0.1;
        [NSRunLoop.mainRunLoop addTimer:sg_ticker forMode:NSRunLoopCommonModes];
    } else if (!sg_placed.count && sg_ticker) {
        [sg_ticker invalidate];
        sg_ticker = nil;
    }
}

static void askPlaced(void) {
    [SGHomeWidgetsBridge placed:^(NSArray<NSString *> *kinds) {
        if (![kinds isEqualToArray:sg_placed]) SGLog(@"widgets: placed %@", kinds.count ? [kinds componentsJoinedByString:@", "] : @"none");
        sg_placed = kinds ?: @[];
        followPlaced();
        update(NO);
    }];
}

NSUInteger SGHomeWidgetsInstalledCount(void) { return sg_placed.count; }

void SGHomeWidgetsRefresh(void) { update(YES); }

@interface SGHomeWidgetsObserver : NSObject <SGPlayerStateObserver>
@end
@implementation SGHomeWidgetsObserver
- (void)playerStateDidChange:(SPTPlayerState *)state {
    // Several reports come together; they are written once.
    static BOOL queued;
    if (queued) return;
    queued = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        queued = NO;
        update(NO);
    });
}
@end

%ctor {
    if (@available(iOS 17.0, *)) {
        if (SGOff("homewidgets")) return;
        static SGHomeWidgetsObserver *observer;
        observer = [SGHomeWidgetsObserver new];
        dispatch_async(dispatch_get_main_queue(), ^{
            SGAddPlayerStateObserver(observer);
            NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
            for (NSNotificationName name in @[UIApplicationDidBecomeActiveNotification, UIApplicationDidEnterBackgroundNotification]) {
                [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { askPlaced(); }];
            }
            // A like has no player report: written once the Live Activity's action has run.
            [center addObserverForName:@"SGLiveActivityAction" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ update(NO); });
            }];
            NSTimer *placed = [NSTimer timerWithTimeInterval:kPlacedEvery repeats:YES block:^(NSTimer *timer) { askPlaced(); }];
            placed.tolerance = 5;
            [NSRunLoop.mainRunLoop addTimer:placed forMode:NSRunLoopCommonModes];
            askPlaced();
        });
    }
}
