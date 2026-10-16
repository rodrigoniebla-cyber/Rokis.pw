// iOS's own Music Haptics (iOS 18, Settings > Accessibility > Music Haptics), which keeps playing in the
// background and on the lock screen, where the mod's (MusicHaptics.x) cannot: Apple plays its own haptic
// track for a song it knows by ISRC, for an app that says it takes part (MusicHapticsSupported in the IPA's
// Info.plist, plist/liquid-glass.plist) and puts the song's ISRC in the system's now playing info.
//
// Spotify's player names no ISRC, so it is asked of Spotify's Web API for each track, with the Authorization
// of Spotify's own requests (Shared/Lyrics), which goes nowhere but Spotify, and kept for the session. With
// iOS's on and a haptic track for the song, the mod's own Music Haptics steps aside, so the two never play
// at once; for a song Apple has nothing for, the mod's plays as before, in front.
//
// One recording is often released several times, a single, the album, a deluxe edition, another country's,
// each under an ISRC of its own, and Apple may have a haptic track under one Spotify's track does not carry.
// So when iOS has none for Spotify's code, the same song's other releases are searched for on Spotify (same
// title before any " - " or bracket, same first artist, within a few seconds of the same length), and iOS is
// asked about each of their codes in turn; the first it has a haptic track for is the one sent, and is kept
// on the phone for the track, so the song is found at once the next time it plays.
#import <MediaPlayer/MediaPlayer.h>
#import <MediaAccessibility/MediaAccessibility.h>
#import "Core/SGCore.h"
#import "Headers/SPTPlayer.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/Player/PlayerState.h"
#import "Haptics.h"

static NSMutableDictionary<NSString *, NSString *> *sg_isrcs;   // base62 id: ISRC, "" for none
static NSMutableSet<NSString *> *sg_asking;
static NSString *sg_track;          // the base62 id playing
static NSString *sg_isrc;           // its ISRC once known
static BOOL sg_systemCovers;        // iOS's is on and has a haptic track for it
static BOOL sg_hooked;              // taken part in this launch
static NSInteger sg_lookupStatus;   // the last lookup's HTTP status for the track playing, 0 before one
static BOOL sg_checked;             // iOS has answered whether it has a haptic track for the song
// What the lookup said of each track, for the search for its other releases: title, first artist, length.
static NSMutableDictionary<NSString *, NSDictionary *> *sg_meta;
// Tracks whose other releases have been searched for this launch, and, for the track playing, how far the
// search has come: the code being asked of iOS and how many there are.
static NSMutableSet<NSString *> *sg_searched;
static NSUInteger sg_trying, sg_candidates;
static BOOL sg_searching;
// Track: the code iOS had a haptic track for, kept between launches, at most kMostRemembered of them.
static NSString *const kRememberedKey = @"spotifyglass.haptics.music.system.codes";
static const NSUInteger kMostRemembered = 2000;
// How many other releases are asked about, and how far their length may be from the track's.
static const NSUInteger kMostCandidates = 8;
static const NSInteger kLengthSlackMs = 3000;
// Spotify's token may not be there yet as a track starts; the lookup is tried again this often, this many times.
static const NSTimeInterval kRetryAfter = 3;
static const NSInteger kMostTries = 10;

BOOL SGSystemMusicHapticsCovers(void) { return sg_systemCovers; }

static void tellHaptics(BOOL covers) {
    if (covers == sg_systemCovers) return;
    sg_systemCovers = covers;
    SGLog(@"music haptics: iOS's own %@", covers ? @"plays this song, the mod's steps aside" : @"does not play this song");
    SGMusicHapticsSettingsChanged();
}

static NSDictionary<NSString *, NSString *> *remembered(void) {
    NSDictionary *codes = [NSUserDefaults.standardUserDefaults dictionaryForKey:kRememberedKey];
    return [codes isKindOfClass:NSDictionary.class] ? codes : @{};
}

static void remember(NSString *track, NSString *isrc) {
    NSMutableDictionary *codes = [remembered() mutableCopy];
    if ([codes[track] isEqual:isrc]) return;
    if (codes.count >= kMostRemembered) [codes removeAllObjects];
    codes[track] = isrc;
    [NSUserDefaults.standardUserDefaults setObject:codes forKey:kRememberedKey];
}

// Sends Spotify's last now playing info again, for the hook below to add the ISRC to.
static void resend(void) {
    MPNowPlayingInfoCenter *center = MPNowPlayingInfoCenter.defaultCenter;
    NSDictionary *info = center.nowPlayingInfo;
    if (info) center.nowPlayingInfo = info;
}

static void settle(NSString *track, NSString *isrc, BOOL available) {
    sg_searching = NO;
    sg_checked = YES;
    if (available && isrc.length) {
        sg_isrcs[track] = isrc;
        remember(track, isrc);
        if (![isrc isEqualToString:sg_isrc]) {
            sg_isrc = isrc;
            resend();
        }
    }
    tellHaptics(available);
}

// The title as releases share it: lower case, before any " - " or bracket ("Song - Remastered 2011",
// "Song (feat. X)", "Song [Live]").
static NSString *baseTitle(NSString *title) {
    NSString *lower = title.lowercaseString ?: @"";
    for (NSString *cut in @[@" - ", @" (", @" ["]) {
        NSRange at = [lower rangeOfString:cut];
        if (at.location != NSNotFound) lower = [lower substringToIndex:at.location];
    }
    return [lower stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

static void askEach(NSString *track, NSArray<NSString *> *codes, NSUInteger index) API_AVAILABLE(ios(18.0)) {
    if (![track isEqualToString:sg_track]) return;
    if (index >= codes.count) {
        SGLog(@"music haptics: Apple has none for %@ under any of %lu other releases", track, (unsigned long)codes.count);
        settle(track, nil, NO);
        return;
    }
    sg_trying = index + 1;
    NSString *code = codes[index];
    [MAMusicHapticsManager.sharedManager checkHapticTrackAvailabilityForMediaMatchingCode:code completionHandler:^(BOOL available) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![track isEqualToString:sg_track]) return;
            if (!available) {
                askEach(track, codes, index + 1);
                return;
            }
            SGLog(@"music haptics: Apple has %@ under another release's code, %@", track, code);
            settle(track, code, YES);
        });
    }];
}

// Spotify's other releases of the track playing, by title and first artist, whose codes iOS is asked about.
static void searchReleases(NSString *track) API_AVAILABLE(ios(18.0)) {
    NSDictionary *meta = sg_meta[track];
    NSString *authorization = SGKaraokeSpotifyAuthorization();
    if (!meta || !authorization || [sg_searched containsObject:track]) {
        settle(track, nil, NO);
        return;
    }
    [sg_searched addObject:track];
    sg_searching = YES;
    sg_trying = 0;
    sg_candidates = 0;
    NSString *(^plain)(NSString *) = ^NSString *(NSString *text) { return [text stringByReplacingOccurrencesOfString:@"\"" withString:@""]; };
    NSString *query = [NSString stringWithFormat:@"track:\"%@\" artist:\"%@\"", plain(baseTitle(meta[@"title"])), plain(meta[@"artist"])];
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://api.spotify.com/v1/search"];
    components.queryItems = @[[NSURLQueryItem queryItemWithName:@"q" value:query], [NSURLQueryItem queryItemWithName:@"type" value:@"track"],
                              [NSURLQueryItem queryItemWithName:@"limit" value:@"30"]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL];
    [request setValue:authorization forHTTPHeaderField:@"Authorization"];
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *reply = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        id items = [reply isKindOfClass:NSDictionary.class] ? reply[@"tracks"] : nil;
        items = [items isKindOfClass:NSDictionary.class] ? items[@"items"] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![track isEqualToString:sg_track]) return;
            NSString *title = baseTitle(meta[@"title"]), *artist = [meta[@"artist"] lowercaseString];
            NSInteger length = [meta[@"ms"] integerValue];
            NSMutableOrderedSet<NSString *> *codes = [NSMutableOrderedSet orderedSet];
            for (id item in [items isKindOfClass:NSArray.class] ? items : @[]) {
                if (![item isKindOfClass:NSDictionary.class] || codes.count >= kMostCandidates) continue;
                id ids = item[@"external_ids"], artists = item[@"artists"];
                NSString *code = [ids isKindOfClass:NSDictionary.class] ? ids[@"isrc"] : nil;
                NSString *name = [item[@"name"] isKindOfClass:NSString.class] ? item[@"name"] : nil;
                NSString *first = [artists isKindOfClass:NSArray.class] && [artists count] && [artists[0] isKindOfClass:NSDictionary.class]
                                ? artists[0][@"name"] : nil;
                NSInteger ms = [item[@"duration_ms"] respondsToSelector:@selector(integerValue)] ? [item[@"duration_ms"] integerValue] : 0;
                if (![code isKindOfClass:NSString.class] || !code.length || [code isEqualToString:sg_isrc]) continue;
                if (![baseTitle(name) isEqualToString:title] || ![first isKindOfClass:NSString.class] || ![first.lowercaseString isEqualToString:artist]) continue;
                if (length > 0 && labs(ms - length) > kLengthSlackMs) continue;
                [codes addObject:code.uppercaseString];
            }
            sg_candidates = codes.count;
            SGLog(@"music haptics: %lu other releases of %@ to ask about", (unsigned long)codes.count, track);
            askEach(track, codes.array, 0);
        });
    }] resume];
}

// Whether iOS has a haptic track for the song playing, and is playing haptics at all: its own code first,
// then its other releases'.
static void checkSystem(NSString *isrc) API_AVAILABLE(ios(18.0)) {
    MAMusicHapticsManager *manager = MAMusicHapticsManager.sharedManager;
    NSString *track = sg_track;
    if (!isrc.length || !manager.isActive || !track) {
        tellHaptics(NO);
        return;
    }
    [manager checkHapticTrackAvailabilityForMediaMatchingCode:isrc completionHandler:^(BOOL available) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![isrc isEqualToString:sg_isrc] || ![track isEqualToString:sg_track]) return;
            if (available) settle(track, isrc, YES);
            else searchReleases(track);
        });
    }];
}

static void found(NSString *track, NSString *isrc) {
    sg_isrcs[track] = isrc ?: @"";
    [sg_asking removeObject:track];
    if (![track isEqualToString:sg_track]) return;
    sg_isrc = isrc.length ? isrc : nil;
    resend();
    if (@available(iOS 18.0, *)) checkSystem(sg_isrc);
}

static void askISRC(NSString *track, NSInteger tries);

// Asked again in a moment, while the same track plays: Spotify's token comes with its first requests, which a
// track that starts as Spotify opens can beat, and a lookup can fail on a bad connection.
static void askAgain(NSString *track, NSInteger tries) {
    if (tries >= kMostTries) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRetryAfter * (tries + 1) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([track isEqualToString:sg_track] && !sg_isrc) askISRC(track, tries + 1);
    });
}

static void askISRC(NSString *track, NSInteger tries) {
    NSString *kept = sg_isrcs[track] ?: remembered()[track];
    if ([kept isKindOfClass:NSString.class]) {
        found(track, kept);
        return;
    }
    if ([sg_asking containsObject:track]) return;
    NSString *authorization = SGKaraokeSpotifyAuthorization();
    if (!authorization) {
        askAgain(track, tries);
        return;
    }
    [sg_asking addObject:track];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[@"https://api.spotify.com/v1/tracks/" stringByAppendingString:track]]];
    [request setValue:authorization forHTTPHeaderField:@"Authorization"];
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *reply = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        NSDictionary *ids = [reply isKindOfClass:NSDictionary.class] ? reply[@"external_ids"] : nil;
        NSString *isrc = [ids isKindOfClass:NSDictionary.class] && [ids[@"isrc"] isKindOfClass:NSString.class] ? ids[@"isrc"] : nil;
        NSString *title = [reply isKindOfClass:NSDictionary.class] && [reply[@"name"] isKindOfClass:NSString.class] ? reply[@"name"] : nil;
        id artists = [reply isKindOfClass:NSDictionary.class] ? reply[@"artists"] : nil;
        NSString *artist = [artists isKindOfClass:NSArray.class] && [artists count] && [artists[0] isKindOfClass:NSDictionary.class]
                         && [artists[0][@"name"] isKindOfClass:NSString.class] ? artists[0][@"name"] : nil;
        id length = [reply isKindOfClass:NSDictionary.class] ? reply[@"duration_ms"] : nil;
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([track isEqualToString:sg_track]) sg_lookupStatus = status;
            if (status != 200) {
                [sg_asking removeObject:track];   // not kept as none: asked again in a moment
                SGLog(@"music haptics: no ISRC for %@ (HTTP %ld, try %ld)", track, (long)status, (long)tries + 1);
                if (status != 404) askAgain(track, tries);
                return;
            }
            if (title && artist) sg_meta[track] = @{@"title": title, @"artist": artist,
                                                    @"ms": [length respondsToSelector:@selector(integerValue)] ? @([length integerValue]) : @0};
            found(track, isrc);
        });
    }] resume];
}

@interface SGSystemHapticsWatcher : NSObject <SGPlayerStateObserver>
@end

@implementation SGSystemHapticsWatcher
- (void)playerStateDidChange:(SPTPlayerState *)state {
    NSString *uri = SGURIString(state.track.URI);
    NSString *track = [uri hasPrefix:@"spotify:track:"] ? [uri substringFromIndex:@"spotify:track:".length] : nil;
    if (track == sg_track || [track isEqualToString:sg_track]) return;
    sg_track = track;
    sg_isrc = nil;
    sg_lookupStatus = 0;
    sg_checked = NO;
    sg_searching = NO;
    tellHaptics(NO);
    if (track) askISRC(track, 0);
}
@end

static SGSystemHapticsWatcher *sg_watcher;

NSString *SGSystemMusicHapticsStatus(void) {
    if (@available(iOS 18.0, *)) {
        if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPhone) return @"Not on this device";
        if (!SGEnabled(SGKeySystemMusicHaptics)) return @"Off";
        if (!sg_hooked) return @"Restart Spotify";
        if (!MAMusicHapticsManager.sharedManager.isActive) return @"Off in Settings";
        if (!sg_track) return @"Play a song";
        if (sg_systemCovers) return @"Playing for this song";
        if (!sg_isrc) return sg_lookupStatus && sg_lookupStatus != 200 ? [NSString stringWithFormat:@"Song not found (%ld)", (long)sg_lookupStatus]
                                                                      : @"Looking the song up";
        if (sg_searching) return sg_candidates ? [NSString stringWithFormat:@"Trying other releases (%lu of %lu)", (unsigned long)sg_trying, (unsigned long)sg_candidates]
                                               : @"Looking for other releases";
        return sg_checked ? @"Apple has none for this song" : @"Asking iOS";
    }
    return @"Needs iOS 18";
}

%hook MPNowPlayingInfoCenter
- (void)setNowPlayingInfo:(NSDictionary *)info {
    NSString *isrc = sg_isrc;
    if (@available(iOS 18.0, *)) {
        if (isrc && info && ![info[MPNowPlayingInfoPropertyInternationalStandardRecordingCode] isEqual:isrc]) {
            NSMutableDictionary *withCode = [info mutableCopy];
            withCode[MPNowPlayingInfoPropertyInternationalStandardRecordingCode] = isrc;
            %orig(withCode);
            return;
        }
    }
    %orig;
}
%end

%ctor {
    if (@available(iOS 18.0, *)) {
        if (SGOff("syshaptics")) return;
        // An iPad has no Taptic Engine for iOS to play a haptic track on.
        if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPhone || !SGEnabled(SGKeySystemMusicHaptics)) return;
        sg_hooked = YES;
        sg_isrcs = [NSMutableDictionary dictionary];
        sg_asking = [NSMutableSet set];
        sg_meta = [NSMutableDictionary dictionary];
        sg_searched = [NSMutableSet set];
        %init;
        dispatch_async(dispatch_get_main_queue(), ^{
            sg_watcher = [SGSystemHapticsWatcher new];
            SGAddPlayerStateObserver(sg_watcher);
            SPTPlayerState *state = SGPlayerState();
            if (state) [sg_watcher playerStateDidChange:state];
            // Turned on or off in Accessibility while Spotify runs.
            [MAMusicHapticsManager.sharedManager addStatusObserver:^(NSString *code, BOOL active) {
                dispatch_async(dispatch_get_main_queue(), ^{ checkSystem(sg_isrc); });
            }];
        });
        SGLog(@"music haptics: iOS's own taken part in");
    }
}
