// Spotify's now playing info passes through with the artist swapped for the current line, and a timer
// sends it again each time the line changes. Spotify itself only ever sees its own dictionary back.
//
// The timer follows the playback rate rather than running from launch: a paused player's line does not
// move, so working it out ten times a second only wakes the phone. The lock screen keeps the line it
// was left on until the sound starts again.
//
// As the artwork, the picture is drawn only when the line changes, so the lock screen is sent a few pictures a
// verse, not a stream of frames. The visualizer is the app's alone and never draws here.
#import <MediaPlayer/MediaPlayer.h>
#import <CoreImage/CoreImage.h>
#import "Core/SGCore.h"
#import "LockScreenLyrics.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Headers/SPTPlayer.h"
#import "Shared/Sing/SGSingController.h"
#import "Shared/Player/PlayerState.h"

// A tenth of a second: a new line is on the lock screen within that of being sung.
static const NSTimeInterval kTick = 0.1;
// Past a line's sung end by this much, with the next line at least this far off, the artist comes back.
static const NSInteger kBreakMs = 4000;
// About what the lock screen's artist row fits before it cuts the text off.
static const NSUInteger kMaxChars = 30;

// Spotify may set the info from any thread; the timer reads it on the main one.
static NSObject *sg_lock;
static NSDictionary *sg_spotifyInfo;
static CFAbsoluteTime sg_spotifyInfoAt;
static NSString *sg_shownLine;
static SGLockScreenLyricsPlace sg_place;
static BOOL sg_resending;
static NSTimer *sg_timer;
// Read at launch.
static BOOL sg_lyricsOn;

static NSString *textOf(NSArray<SGKaraokeWord *> *words) {
    SGKaraokeLine *line = [SGKaraokeLine new];
    line.words = words;
    return SGKaraokeLineText(line);
}

// A line longer than the artist row holds, split into even pieces rather than a full one and a stub.
// Each piece shows from its first word's estimated start.
static NSArray<NSArray<SGKaraokeWord *> *> *piecesOf(SGKaraokeLine *line) {
    NSUInteger length = textOf(line.words).length;
    NSUInteger count = MAX((length + kMaxChars - 1) / kMaxChars, 1);
    NSUInteger target = (length + count - 1) / count;
    NSMutableArray<NSArray<SGKaraokeWord *> *> *pieces = [NSMutableArray array];
    NSMutableArray<SGKaraokeWord *> *piece = [NSMutableArray array];
    NSUInteger pieceLength = 0;
    for (SGKaraokeWord *word in line.words) {
        NSUInteger gap = pieceLength && !word.joined ? 1 : 0;
        NSUInteger withWord = pieceLength ? pieceLength + gap + word.text.length : word.text.length;
        if (pieceLength && (withWord > kMaxChars || (withWord > target && pieces.count + 1 < count))) {
            [pieces addObject:piece];
            piece = [NSMutableArray array];
            withWord = word.text.length;
        }
        [piece addObject:word];
        pieceLength = withWord;
    }
    if (piece.count) [pieces addObject:piece];
    return pieces;
}

// Seconds into the track at `now`, run on from what Spotify last reported.
static double elapsedAt(NSDictionary *info, CFAbsoluteTime reportedAt, CFAbsoluteTime now) {
    SPTPlayerState *state = SGPlayerState();
    double position;
    if ([state.track.trackTitle isEqualToString:info[MPMediaItemPropertyTitle]] && SGSingPosition(state, &position)) return position;
    double rate = [info[MPNowPlayingInfoPropertyPlaybackRate] doubleValue];
    return [info[MPNowPlayingInfoPropertyElapsedPlaybackTime] doubleValue] + rate * (now - reportedAt);
}

// nil between lines and for a track without synced lyrics, plain text included. `full` and `next` are the
// whole line and the one after it, for the artwork.
static NSString *lineFor(NSDictionary *info, double elapsed, NSString **full, NSString **next) {
    if (full) *full = nil;
    if (next) *next = nil;
    if (!sg_lyricsOn) return nil;
    SPTPlayerState *state = [(id<SPTPlayer>)SGKaraokePlayer() state];
    // The player's track can lag behind the now playing info; its lyrics would then be another song's.
    if (![state.track.trackTitle isEqualToString:info[MPMediaItemPropertyTitle]]) return nil;
    NSString *trackID = SGKaraokePlayingTrack();
    NSArray<SGKaraokeLine *> *lines = SGKaraokeLinesForTrack(trackID);
    if (!lines) {
        SGKaraokeRequestLyrics(trackID);
        return nil;
    }
    // Plain text has no line being sung to show.
    if (SGKaraokeLinesTiming(lines) == SGKaraokeTimingNone) return nil;
    NSInteger position = (NSInteger)(elapsed * 1000);
    NSInteger index = SGKaraokeLeadLine(lines, position);
    if (index < 0) return nil;
    BOOL nextFarOff = index + 1 == (NSInteger)lines.count || lines[index + 1].start - position > kBreakMs;
    if (position > lines[index].end + kBreakMs && nextFarOff) return nil;
    if (full) *full = SGKaraokeLineText(lines[index]);
    if (next && !nextFarOff) *next = SGKaraokeLineText(lines[index + 1]);
    NSString *shown = nil;
    for (NSArray<SGKaraokeWord *> *piece in piecesOf(lines[index])) {
        if (!shown || piece.firstObject.start <= position) shown = textOf(piece);
    }
    return shown;
}

#pragma mark - the lyrics as the artwork

// The cover blurred and darkened, made once per cover Spotify hands over.
static NSObject *sg_artworkLock;
static __weak MPMediaItemArtwork *sg_backdropOf;
static UIImage *sg_backdrop;
static const CGFloat kArtworkSide = 600;

// The cover itself, asked of Spotify's artwork once per cover and never on the main thread, where Spotify's
// handler can wait on that thread.
static __weak MPMediaItemArtwork *sg_coverOf;
static UIImage *sg_cover;

static UIImage *coverFor(MPMediaItemArtwork *cover) {
    if (!cover || NSThread.isMainThread) return nil;
    @synchronized (sg_artworkLock) {
        if (cover == sg_coverOf && sg_cover) return sg_cover;
    }
    UIImage *image = [cover imageWithSize:CGSizeMake(kArtworkSide, kArtworkSide)];
    @synchronized (sg_artworkLock) {
        sg_coverOf = cover;
        sg_cover = image;
    }
    return image;
}

static UIImage *backdropFor(MPMediaItemArtwork *cover) {
    @synchronized (sg_artworkLock) {
        if (cover && cover == sg_backdropOf && sg_backdrop) return sg_backdrop;
    }
    UIImage *image = coverFor(cover);
    UIImage *backdrop = nil;
    if (image.CGImage) {
        static CIContext *context;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ context = [CIContext contextWithOptions:nil]; });
        CIImage *input = [[CIImage imageWithCGImage:image.CGImage] imageByClampingToExtent];
        CIImage *blurred = [input imageByApplyingGaussianBlurWithSigma:28];
        CGRect extent = [CIImage imageWithCGImage:image.CGImage].extent;
        CGImageRef cg = [context createCGImage:blurred fromRect:extent];
        if (cg) {
            backdrop = [UIImage imageWithCGImage:cg];
            CGImageRelease(cg);
        }
    }
    @synchronized (sg_artworkLock) {
        sg_backdropOf = cover;
        sg_backdrop = backdrop;
    }
    return backdrop;
}

static UIImage *lyricsImage(UIImage *backdrop, NSString *line, NSString *next) {
    CGSize size = CGSizeMake(kArtworkSide, kArtworkSide);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGRect bounds = (CGRect){CGPointZero, size};
        if (backdrop) [backdrop drawInRect:bounds];
        [[UIColor colorWithWhite:0 alpha:backdrop ? 0.5 : 1] setFill];
        UIRectFillUsingBlendMode(bounds, kCGBlendModeNormal);
        CGFloat side = 44, width = size.width - 2 * side;
        NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
        paragraph.lineBreakMode = NSLineBreakByWordWrapping;
        paragraph.lineSpacing = 2;
        NSDictionary *lineStyle = @{NSFontAttributeName: [UIFont systemFontOfSize:52 weight:UIFontWeightBold],
                                    NSForegroundColorAttributeName: UIColor.whiteColor, NSParagraphStyleAttributeName: paragraph};
        NSDictionary *nextStyle = @{NSFontAttributeName: [UIFont systemFontOfSize:34 weight:UIFontWeightBold],
                                    NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.45], NSParagraphStyleAttributeName: paragraph};
        CGRect lineBox = [line boundingRectWithSize:CGSizeMake(width, size.height * 0.62) options:NSStringDrawingUsesLineFragmentOrigin attributes:lineStyle context:nil];
        CGRect nextBox = next.length ? [next boundingRectWithSize:CGSizeMake(width, size.height * 0.25) options:NSStringDrawingUsesLineFragmentOrigin attributes:nextStyle context:nil] : CGRectZero;
        CGFloat gap = next.length ? 22 : 0;
        CGFloat lineHeight = MIN(ceil(lineBox.size.height), size.height * 0.62), nextHeight = MIN(ceil(nextBox.size.height), size.height * 0.25);
        CGFloat top = MAX(side, (size.height - lineHeight - gap - nextHeight) / 2);
        [line drawWithRect:CGRectMake(side, top, width, lineHeight) options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine attributes:lineStyle context:nil];
        if (next.length) {
            [next drawWithRect:CGRectMake(side, top + lineHeight + gap, width, nextHeight) options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine attributes:nextStyle context:nil];
        }
    }];
}

// The line and the next one over the cover, drawn when the lock screen asks for the picture.
static MPMediaItemArtwork *lyricsArtwork(MPMediaItemArtwork *cover, NSString *line, NSString *next) {
    CGSize size = CGSizeMake(kArtworkSide, kArtworkSide);
    return [[MPMediaItemArtwork alloc] initWithBoundsSize:size requestHandler:^UIImage *(CGSize wanted) {
        // Spotify's own handler can wait on the main thread, so it is never asked from there.
        if (NSThread.isMainThread) {
            @synchronized (sg_artworkLock) {
                return lyricsImage(sg_backdropOf == cover ? sg_backdrop : nil, line, next);
            }
        }
        return lyricsImage(backdropFor(cover), line, next);
    }];
}

// Under the cover: the cover as it is, darkened towards the bottom, and the line along its foot in white with a
// black outline, in the app's font (Mod Settings > Appearance > Font: Spotify's own face asked for by name goes
// through the font hooks to the one picked, if one is).
static UIFont *coverLineFont(CGFloat size) {
    return [UIFont fontWithName:@"SpotifyMixUI-Bold" size:size] ?: [UIFont systemFontOfSize:size weight:UIFontWeightBold];
}

static UIImage *coverLineImage(UIImage *cover, NSString *line) {
    CGSize size = CGSizeMake(kArtworkSide, kArtworkSide);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGRect bounds = (CGRect){CGPointZero, size};
        if (cover) [cover drawInRect:bounds];
        else {
            [UIColor.blackColor setFill];
            UIRectFill(bounds);
        }
        // The background the line sits on: a shade rising from the foot, so the cover stays itself above it.
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGFloat components[] = {0, 0, 0, 0, 0, 0, 0, 0.78};
        CGFloat locations[] = {0, 1};
        CGGradientRef shade = CGGradientCreateWithColorComponents(space, components, locations, 2);
        CGContextDrawLinearGradient(context.CGContext, shade, CGPointMake(0, size.height * 0.5), CGPointMake(0, size.height), 0);
        CGGradientRelease(shade);
        CGColorSpaceRelease(space);
        CGFloat side = 36, bottom = 34, width = size.width - 2 * side, most = size.height * 0.42;
        NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
        paragraph.alignment = NSTextAlignmentCenter;
        paragraph.lineBreakMode = NSLineBreakByWordWrapping;
        UIFont *font = coverLineFont(46);
        NSDictionary *fill = @{NSFontAttributeName: font, NSForegroundColorAttributeName: UIColor.whiteColor, NSParagraphStyleAttributeName: paragraph};
        CGRect box = [line boundingRectWithSize:CGSizeMake(width, most) options:NSStringDrawingUsesLineFragmentOrigin attributes:fill context:nil];
        CGFloat height = MIN(ceil(box.size.height), most);
        CGRect rect = CGRectMake(side, size.height - bottom - height, width, height);
        NSStringDrawingOptions options = NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine;
        // The outline first, wide and black, then the white over it, so the outline sits outside the letters.
        NSMutableDictionary *outline = [fill mutableCopy];
        outline[NSForegroundColorAttributeName] = UIColor.blackColor;
        outline[NSStrokeColorAttributeName] = UIColor.blackColor;
        outline[NSStrokeWidthAttributeName] = @(16);
        CGContextSetLineJoin(context.CGContext, kCGLineJoinRound);
        [line drawWithRect:rect options:options attributes:outline context:nil];
        [line drawWithRect:rect options:options attributes:fill context:nil];
    }];
}

static MPMediaItemArtwork *coverLineArtwork(MPMediaItemArtwork *cover, NSString *line) {
    CGSize size = CGSizeMake(kArtworkSide, kArtworkSide);
    return [[MPMediaItemArtwork alloc] initWithBoundsSize:size requestHandler:^UIImage *(CGSize wanted) {
        // Spotify's own handler can wait on the main thread, so it is never asked from there.
        if (NSThread.isMainThread) {
            @synchronized (sg_artworkLock) {
                return coverLineImage(sg_coverOf == cover ? sg_cover : nil, line);
            }
        }
        return coverLineImage(coverFor(cover), line);
    }];
}

static BOOL lineInArtist(void) { return sg_place == SGLockScreenLyricsArtist || sg_place == SGLockScreenLyricsBoth; }
static BOOL lineInArtwork(void) { return sg_place != SGLockScreenLyricsArtist; }

static NSDictionary *withLine(NSDictionary *info, NSString *line, NSString *full, NSString *next, double elapsed) {
    NSMutableDictionary *shown = [info mutableCopy];
    if (line && lineInArtist()) shown[MPMediaItemPropertyArtist] = line;
    if (full.length && lineInArtwork()) {
        id cover = info[MPMediaItemPropertyArtwork];
        MPMediaItemArtwork *artwork = [cover isKindOfClass:MPMediaItemArtwork.class] ? cover : nil;
        shown[MPMediaItemPropertyArtwork] = sg_place == SGLockScreenLyricsCover ? coverLineArtwork(artwork, full)
                                                                              : lyricsArtwork(artwork, full, next);
    }
    // iOS reads a resent elapsed time as the position now, so Spotify's older one would jump the bar back.
    shown[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(elapsed);
    return shown;
}

static void tick(void) {
    NSDictionary *info;
    CFAbsoluteTime reportedAt;
    @synchronized (sg_lock) {
        info = sg_spotifyInfo;
        reportedAt = sg_spotifyInfoAt;
    }
    if (!info[MPNowPlayingInfoPropertyElapsedPlaybackTime]) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    double elapsed = elapsedAt(info, reportedAt, now);
    NSString *full, *next;
    NSString *line = lineFor(info, elapsed, &full, &next);
    // What is on show: the artist row's piece and, for the artwork, the whole line and the next.
    NSString *key = [NSString stringWithFormat:@"%@\n%@\n%@", line ?: @"", lineInArtwork() ? full ?: @"" : @"", lineInArtwork() && sg_place != SGLockScreenLyricsCover ? next ?: @"" : @""];
    if ([key isEqualToString:sg_shownLine]) return;
    sg_shownLine = key;
    sg_resending = YES;
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = withLine(info, line, full, next, elapsed);
    sg_resending = NO;
}

// Sends Spotify's info again as it should show now, whether or not the line moved.
static void resend(void) {
    NSDictionary *info;
    CFAbsoluteTime reportedAt;
    @synchronized (sg_lock) {
        info = sg_spotifyInfo;
        reportedAt = sg_spotifyInfoAt;
    }
    if (!info) return;
    double elapsed = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] ? elapsedAt(info, reportedAt, CFAbsoluteTimeGetCurrent()) : 0;
    NSString *full, *next;
    NSString *line = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] ? lineFor(info, elapsed, &full, &next) : nil;
    sg_shownLine = [NSString stringWithFormat:@"%@\n%@\n%@", line ?: @"", lineInArtwork() ? full ?: @"" : @"", lineInArtwork() && sg_place != SGLockScreenLyricsCover ? next ?: @"" : @""];
    NSMutableDictionary *shown = [withLine(info, line, full, next, elapsed) mutableCopy];
    if (!info[MPNowPlayingInfoPropertyElapsedPlaybackTime]) [shown removeObjectForKey:MPNowPlayingInfoPropertyElapsedPlaybackTime];
    sg_resending = YES;
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = shown;
    sg_resending = NO;
}

// Main thread, as everything the timer touches is.
static void setTicking(BOOL on) {
    if (!sg_lyricsOn) on = NO;
    if (on == (sg_timer != nil)) return;
    if (!on) {
        [sg_timer invalidate];
        sg_timer = nil;
        return;
    }
    sg_timer = [NSTimer timerWithTimeInterval:kTick repeats:YES block:^(NSTimer *t) { tick(); }];
    [NSRunLoop.mainRunLoop addTimer:sg_timer forMode:NSRunLoopCommonModes];
}

// Whether the sound is moving. A rate Spotify did not report at all counts as moving: the line would
// stand still either way, and a missing key is no reason to leave the feature switched off for good.
static BOOL playingBy(NSDictionary *info) {
    NSNumber *rate = info[MPNowPlayingInfoPropertyPlaybackRate];
    return !rate || rate.doubleValue > 0;
}

%hook MPNowPlayingInfoCenter
- (void)setNowPlayingInfo:(NSDictionary *)info {
    if (sg_resending) {
        %orig;
        return;
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    @synchronized (sg_lock) {
        sg_spotifyInfo = info;
        sg_spotifyInfoAt = now;
    }
    BOOL playing = playingBy(info) && info[MPNowPlayingInfoPropertyElapsedPlaybackTime] != nil;
    // Karaoke's lyrics are main-thread state; off it the info goes out as it is and the next tick adds the line.
    if (!NSThread.isMainThread || !info[MPNowPlayingInfoPropertyElapsedPlaybackTime]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            sg_shownLine = nil;
            setTicking(playing);
        });
        %orig;
        return;
    }
    setTicking(playing);
    double elapsed = elapsedAt(info, now, now);
    NSString *full, *next;
    NSString *line = lineFor(info, elapsed, &full, &next);
    sg_shownLine = [NSString stringWithFormat:@"%@\n%@\n%@", line ?: @"", lineInArtwork() ? full ?: @"" : @"", lineInArtwork() && sg_place != SGLockScreenLyricsCover ? next ?: @"" : @""];
    %orig(withLine(info, line, full, next, elapsed));
}

- (NSDictionary *)nowPlayingInfo {
    NSDictionary *info;
    @synchronized (sg_lock) {
        info = sg_spotifyInfo;
    }
    return info ?: %orig;
}
%end

%ctor {
    sg_lyricsOn = !SGOff("lockscreen") && SGFlag(SGKeyLockScreenLyrics, NO);
    if (!sg_lyricsOn) return;
    sg_lock = [NSObject new];
    sg_artworkLock = [NSObject new];
    sg_place = (SGLockScreenLyricsPlace)MAX(0, MIN(SGLockScreenLyricsCover, SGInt(SGKeyLockScreenLyricsPlace, SGLockScreenLyricsArtist)));
    %init;
    // The timer waits for Spotify to report a playing track; nothing before that has a line to show.
    SGLog(@"lock screen: lyrics on, place %ld", (long)sg_place);
}
