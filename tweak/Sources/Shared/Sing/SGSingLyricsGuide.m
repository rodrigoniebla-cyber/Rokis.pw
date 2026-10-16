#import "Core/SGCore.h"
#import "SGSingLyricsGuide.h"
#import "SGSingGuide.h"
#import "SGSingController.h"
#import "Shared/Lyrics/Lyrics.h"

NSNotificationName const SGSingGuideDidChangeNotification = @"spotifyglass.singGuideChanged";
// What each song taught it, by SGSingTrackIdentifier in hex: [shift ms, energy, outside, blocks, last heard].
static NSString *const kSongsKey = @"spotifyglass.sing.lyricsGuide.songs";
static const NSUInteger kKept = 2000;
static const NSTimeInterval kSaveEvery = 5;
// A line with no end lasts until the next one, but never longer than this.
static const NSInteger kLongestLine = 6000;

static NSString *sg_track, *sg_next;
static NSString *sg_status;
static CFTimeInterval sg_saved;
static BOOL sg_observing;

static NSString *idOf(NSString *uri) { return [uri hasPrefix:@"spotify:track:"] ? [uri substringFromIndex:14] : nil; }
static NSString *keyOf(uint64_t track) { return [NSString stringWithFormat:@"%016llx", track]; }
static NSDictionary *songs(void) { return [NSUserDefaults.standardUserDefaults dictionaryForKey:kSongsKey] ?: @{}; }

static BOOL remembered(uint64_t track, SGSingGuideMemory *memory) {
    NSArray *song = songs()[keyOf(track)];
    if (![song isKindOfClass:NSArray.class] || song.count < 4) return NO;
    memory->shift = [song[0] intValue];
    memory->energy = [song[1] floatValue];
    memory->outside = [song[2] floatValue];
    memory->blocks = [song[3] unsignedIntValue];
    return YES;
}

// What the songs being followed learned so far, into the defaults.
static void save(void) {
    NSMutableDictionary *all = [songs() mutableCopy];
    BOOL changed = NO;
    for (NSString *uri in @[sg_track ?: @"", sg_next ?: @""]) {
        uint64_t track = uri.length ? SGSingTrackIdentifier(uri) : 0;
        SGSingGuideMemory memory;
        if (!track || !SGSingGuideMemoryOf(track, &memory)) continue;
        all[keyOf(track)] = @[@(memory.shift), @(memory.energy), @(memory.outside), @(memory.blocks), @(NSDate.date.timeIntervalSince1970)];
        changed = YES;
    }
    if (!changed) return;
    if (all.count > kKept) {
        NSArray *oldest = [all keysSortedByValueUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
            return [a.lastObject compare:b.lastObject];
        }];
        [all removeObjectsForKeys:[oldest subarrayWithRange:NSMakeRange(0, all.count - kKept)]];
    }
    [NSUserDefaults.standardUserDefaults setObject:all forKey:kSongsKey];
}

static void install(NSString *uri, NSArray<SGKaraokeLine *> *lines) {
    NSMutableArray<SGKaraokeLine *> *timed = [NSMutableArray array];
    for (SGKaraokeLine *line in lines) if (line.timing != SGKaraokeTimingNone && SGKaraokeSungEnd(line) >= line.start) [timed addObject:line];
    [timed sortUsingComparator:^NSComparisonResult(SGKaraokeLine *a, SGKaraokeLine *b) { return [@(a.start) compare:@(b.start)]; }];
    NSMutableData *data = [NSMutableData dataWithLength:timed.count * sizeof(SGSingGuideSpan)];
    SGSingGuideSpan *spans = data.mutableBytes;
    for (NSUInteger n = 0; n < timed.count; n++) {
        NSInteger start = timed[n].start, end = SGKaraokeSungEnd(timed[n]);
        if (end <= start) end = MIN(n + 1 < timed.count ? timed[n + 1].start : start + kLongestLine, start + kLongestLine);
        spans[n] = (SGSingGuideSpan){(int32_t)start, (int32_t)end};
    }
    uint64_t track = SGSingTrackIdentifier(uri);
    SGSingGuideMemory memory;
    BOOL known = remembered(track, &memory);
    SGSingGuideSetLyrics(track, spans, (uint32_t)timed.count, known ? &memory : NULL);
    SGLog(@"Sing follows %lu timed lines of %@%@", (unsigned long)timed.count, idOf(uri),
          known ? [NSString stringWithFormat:@", lyrics moved %d ms from before", memory.shift] : @"");
}

static void load(NSString *uri) {
    NSString *trackID = idOf(uri);
    if (!trackID) return;
    NSArray<SGKaraokeLine *> *lines = SGKaraokeLinesForTrack(trackID);
    if (lines) { install(uri, lines); return; }
    if (SGLyricsOfflineHas(trackID)) SGLyricsOfflineRead(trackID, ^(NSArray<SGKaraokeLine *> *saved) {
        if (saved && !SGKaraokeLinesForTrack(trackID) && ([uri isEqualToString:sg_track] || [uri isEqualToString:sg_next]))
            install(uri, saved);
    });
}

static NSString *seconds(int32_t ms) { return [NSString stringWithFormat:@"%.1f s", fabs(ms / 1000.0)]; }

NSString *SGSingGuideStatus(void) {
    if (!SGSingGuideEnabled()) return @"Off";
    if (!sg_track) return @"Play a song with Sing on";
    int32_t shift = 0;
    switch (SGSingGuideStateOf(SGSingTrackIdentifier(sg_track), &shift)) {
        case SGSingGuideOff: return @"No timed lyrics";
        case SGSingGuideLearning: return @"Learning this song";
        case SGSingGuideMismatch: return @"Lyrics don't match";
        case SGSingGuideFollowing:
            if (!shift) return @"Following the lyrics";
            return [NSString stringWithFormat:@"Following · lyrics %@ %@", seconds(shift), shift > 0 ? @"early" : @"late"];
    }
    return nil;
}

NSString *SGSingGuideExplanation(void) {
    if (!sg_track || !SGSingGuideEnabled()) return @"Turn Sing on in the lyrics while a song plays. Sing then takes the vocals out only where the song's "
        "timed lyrics say someone sings, and learns the song as it goes.";
    int32_t shift = 0;
    switch (SGSingGuideStateOf(SGSingTrackIdentifier(sg_track), &shift)) {
        case SGSingGuideOff: return @"This song has no lyrics timed by the line or the word, so Sing takes the vocals out everywhere, as it does without Follow the lyrics.";
        case SGSingGuideLearning: return @"Sing is lining the lyrics up with the voice it hears. Until it has heard about 20 seconds of singing, it leaves "
            "wider room around each line.";
        case SGSingGuideMismatch: return @"The singing goes on where the lyrics have none (ad-libs, a different version or wrong lyrics), so for this song Sing "
            "takes the vocals out everywhere. It remembers this for the next time the song plays.";
        case SGSingGuideFollowing:
            return [NSString stringWithFormat:@"Sing takes the vocals out only around the lyrics' lines, so the intro, breaks and solos play as they were mixed. %@ "
                    "It remembers this for the next time the song plays.",
                    shift ? [NSString stringWithFormat:@"The lyrics run %@ %@ of the voice, and Sing has moved them to match.", seconds(shift), shift > 0 ? @"early" : @"late"]
                          : @"The lyrics line up with the voice."];
    }
    return nil;
}

static void linesChanged(NSNotification *note) {
    NSString *trackID = note.object;
    for (NSString *uri in @[sg_track ?: @"", sg_next ?: @""])
        if (uri.length && [idOf(uri) isEqualToString:trackID]) install(uri, SGKaraokeLinesForTrack(trackID));
}

void SGSingGuideFollow(NSString *track, NSString *next) {
    if (!SGSingGuideEnabled()) return;
    if (!sg_observing) {
        sg_observing = YES;
        [NSNotificationCenter.defaultCenter addObserverForName:SGKaraokeLinesDidChangeNotification object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) { linesChanged(note); }];
    }
    BOOL moved = !(track == sg_track || [track isEqualToString:sg_track]) || !(next == sg_next || [next isEqualToString:sg_next]);
    CFTimeInterval now = CACurrentMediaTime();
    if (moved || now - sg_saved >= kSaveEvery) { save(); sg_saved = now; }
    if (moved) {
        BOOL newTrack = !(track == sg_track || [track isEqualToString:sg_track]), newNext = !(next == sg_next || [next isEqualToString:sg_next]);
        sg_track = track; sg_next = next;
        if (newTrack && track) load(track);
        if (newNext && next && ![next isEqualToString:track]) load(next);
    }
    NSString *status = SGSingGuideStatus();
    if (![status isEqualToString:sg_status]) {
        sg_status = status;
        [NSNotificationCenter.defaultCenter postNotificationName:SGSingGuideDidChangeNotification object:nil];
    }
}

void SGSingGuideApplySwitch(void) {
    BOOL on = SGFlag(SGKeySingLyricsGuide, NO);
    if (on == SGSingGuideEnabled()) return;
    if (!on) { save(); SGSingGuideReset(); sg_track = sg_next = nil; }
    SGSingGuideSetEnabled(on);
    sg_status = nil;
    [NSNotificationCenter.defaultCenter postNotificationName:SGSingGuideDidChangeNotification object:nil];
}

NSUInteger SGSingGuideLearnedCount(void) { return songs().count; }

void SGSingGuideForget(void) {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kSongsKey];
    SGSingGuideReset();
    // The songs being followed start over, from their lyrics alone.
    NSString *track = sg_track, *next = sg_next;
    sg_track = sg_next = nil; sg_status = nil;
    if (track || next) SGSingGuideFollow(track, next);
    else [NSNotificationCenter.defaultCenter postNotificationName:SGSingGuideDidChangeNotification object:nil];
}
