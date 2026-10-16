// Follow the lyrics (Mod Settings > Karaoke): the separated vocals are only taken out where the song's timed
// lyrics say someone sings, so intros, breaks and solos play as they were mixed instead of losing whatever
// the separator took for a voice. It learns each song as it plays: it lines the lyrics up with the vocals
// the separator hears (how far early or late the lyrics run, up to 1.5 s either way), and when the singing
// keeps going where the lyrics have none (ad-libs, another version), it stops following them for that song.
// What it learned is kept per song (SingGuide.m), so the next play starts lined up.
// Plain C, no allocation in Process; one lock, never taken on the render thread: Process runs on Sing's
// worker, the rest on the main thread. Tested by harness/sing/guide_test.c.
#pragma once
#include <stdbool.h>
#include <stdint.h>

// A sung line, in milliseconds of the song as the lyrics time it.
typedef struct { int32_t start, end; } SGSingGuideSpan;

// What a song taught it, to be kept and handed back the next time it plays: how far to move the lyrics
// (ms, added to their times), and the voiced evidence behind it.
typedef struct {
    int32_t shift;
    float energy;     // the vocals' level summed over voiced 50 ms blocks
    float outside;    // of it, what fell where the lyrics say nobody sings
    uint32_t blocks;  // voiced blocks heard
} SGSingGuideMemory;

typedef enum {
    SGSingGuideOff,          // the switch is off, or the song has no timed lyrics
    SGSingGuideLearning,     // following the lyrics with wide margins until they are lined up
    SGSingGuideFollowing,    // lined up: the vocals go only where the lyrics say
    SGSingGuideMismatch,     // the singing goes on outside the lyrics: vocals go everywhere, as without it
} SGSingGuideState;

void SGSingGuideSetEnabled(bool enabled);
bool SGSingGuideEnabled(void);
// A song's sung lines, sorted by start, copied; `memory` (or NULL) is what an earlier play learned. A few
// songs are held at once (the one playing and the one queued after it); the oldest makes room.
void SGSingGuideSetLyrics(uint64_t track, const SGSingGuideSpan *spans, uint32_t count, const SGSingGuideMemory *memory);
void SGSingGuideDrop(uint64_t track);
// Worker: `frames` stereo interleaved frames of vocals starting `seconds` into `track`, learned from and
// written to `out` with the lyrics' gate applied (copied unchanged when there is nothing to follow).
void SGSingGuideProcess(uint64_t track, double seconds, const float *vocals, float *out, uint32_t frames);
SGSingGuideState SGSingGuideStateOf(uint64_t track, int32_t *shift);
bool SGSingGuideMemoryOf(uint64_t track, SGSingGuideMemory *memory);
void SGSingGuideReset(void);   // forgets every song held
