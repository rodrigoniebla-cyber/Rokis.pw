// Follow the lyrics, around SGSingGuide.h: hands it the timed lyrics of the song Sing plays and the one queued
// after it, keeps what it learned of each song in the defaults (up to 2,000 songs, the least recently heard
// going first), and says what it is doing with the song playing for Mod Settings > Karaoke. Main thread.
#import <Foundation/Foundation.h>

#define SGKeySingLyricsGuide @"spotifyglass.sing.lyricsGuide"   // off until switched on; applies straight away
extern NSNotificationName const SGSingGuideDidChangeNotification;

void SGSingGuideApplySwitch(void);
// Sing's controller, while it runs: the song playing and the one after it (spotify:track: URIs or nil).
void SGSingGuideFollow(NSString *track, NSString *next);
NSString *SGSingGuideStatus(void);   // the song playing: learning, following, the lyrics not matching...
NSString *SGSingGuideExplanation(void);
NSUInteger SGSingGuideLearnedCount(void);
void SGSingGuideForget(void);
