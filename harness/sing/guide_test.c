// Follow the lyrics (Shared/Sing/SGSingGuide.m): lines the lyrics up with the vocals the separator heard, keeps
// the vocals only around the lines, and lets go of lyrics that don't match the singing.
// python3 harness/sing/test.py (all of Sing's C tests), or on its own:
// cc -std=c11 -I tweak/Sources -x c harness/sing/guide_test.c tweak/Sources/Shared/Sing/SGSingGuide.m -lm -pthread
#include "Shared/Sing/SGSingGuide.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

enum { kRate = 44100, kHop = 66150, kSong = 180 };
static SGSingGuideSpan lines[64];
static uint32_t lineCount;

// Lines of 3 s, a second apart, from `from` to `to` seconds of the lyrics.
static void verse(int from, int to) {
    for (int at = from * 1000; at + 3000 <= to * 1000; at += 4000) lines[lineCount++] = (SGSingGuideSpan){at, at + 3000};
}
static bool sung(int32_t ms) {
    for (uint32_t n = 0; n < lineCount; n++) if (ms >= lines[n].start && ms <= lines[n].end) return true;
    return false;
}
// The separator's vocals at `seconds`: the lines sung `late` ms after the lyrics time them, faint leaking
// elsewhere, and a solo from 105 to 125 s it mistook for a voice.
static float vocal(double seconds, int32_t late, bool solo) {
    int32_t ms = (int32_t)(seconds * 1000);
    float level = sung(ms - late) ? 0.14f : 0.002f;
    if (solo && seconds >= 105 && seconds < 125) level = 0.04f;
    return level * sinf((float)(seconds * 2 * M_PI * 220));
}
static float buffer[kHop * 2], out[kHop * 2];
static void fill(uint64_t hop, int32_t late, bool solo) {
    for (uint32_t n = 0; n < kHop; n++) {
        double t = (hop * kHop + n) / (double)kRate;
        buffer[n * 2] = buffer[n * 2 + 1] = vocal(t, late, solo);
    }
}
// Plays the song through, returning the vocals' level left in the output from `from` to `to` seconds,
// against the level that went in there.
static double play(uint64_t track, int32_t late, bool solo, double from, double to, double *before) {
    double kept = 0, in = 0;
    for (uint64_t hop = 0; hop * kHop < (uint64_t)kSong * kRate; hop++) {
        fill(hop, late, solo);
        SGSingGuideProcess(track, hop * kHop / (double)kRate, buffer, out, kHop);
        for (uint32_t n = 0; n < kHop; n++) {
            double t = (hop * kHop + n) / (double)kRate;
            if (t >= from && t < to) { kept += fabsf(out[n * 2]); in += fabsf(buffer[n * 2]); }
        }
    }
    if (before) *before = in;
    return kept;
}

static void linesUp(void) {
    SGSingGuideReset();
    SGSingGuideSetLyrics(1, lines, lineCount, NULL);
    double in, kept = play(1, 400, true, 108, 122, &in);
    int32_t shift;
    assert(SGSingGuideStateOf(1, &shift) == SGSingGuideFollowing);
    assert(abs(shift - 400) <= 50);
    // The solo, well away from any line, is left as it was mixed: none of it is taken out.
    assert(kept < in * 0.01);
    // Inside a line, sung late, everything is taken out as before.
    double inLine, keptLine = play(1, 400, true, 21.0, 22.5, &inLine);
    assert(fabs(keptLine - inLine) < inLine * 1e-6);
    SGSingGuideMemory memory;
    assert(SGSingGuideMemoryOf(1, &memory) && abs(memory.shift - 400) <= 50 && memory.blocks >= 400);
    printf("lined up: lyrics moved %d ms, solo kept %.4f of its level\n", shift, kept / in);

    // The next play starts lined up, from what this one learned.
    SGSingGuideReset();
    SGSingGuideSetLyrics(1, lines, lineCount, &memory);
    assert(SGSingGuideStateOf(1, &shift) == SGSingGuideFollowing && shift == memory.shift);
}

static void early(void) {
    SGSingGuideReset();
    SGSingGuideSetLyrics(2, lines, lineCount, NULL);
    play(2, -600, false, 0, 0, NULL);
    int32_t shift;
    assert(SGSingGuideStateOf(2, &shift) == SGSingGuideFollowing);
    assert(abs(shift + 600) <= 50);
    printf("lyrics late: moved %d ms\n", shift);
}

static void onTime(void) {
    SGSingGuideReset();
    SGSingGuideSetLyrics(3, lines, lineCount, NULL);
    play(3, 0, true, 0, 0, NULL);
    int32_t shift;
    assert(SGSingGuideStateOf(3, &shift) == SGSingGuideFollowing && abs(shift) <= 50);
}

// Lyrics for the first verse only, the song sung all through: they don't match, and the vocals go everywhere.
static void mismatch(void) {
    SGSingGuideSpan saved[64];
    uint32_t savedCount = lineCount;
    for (uint32_t n = 0; n < lineCount; n++) saved[n] = lines[n];
    SGSingGuideReset();
    SGSingGuideSetLyrics(4, lines, 5, NULL);
    lineCount = savedCount;
    double in, kept = play(4, 0, false, 140, 170, &in);
    assert(SGSingGuideStateOf(4, NULL) == SGSingGuideMismatch);
    assert(kept > in * 0.9);
    for (uint32_t n = 0; n < lineCount; n++) lines[n] = saved[n];
    printf("mismatch: kept %.3f of the late vocals\n", kept / in);
}

static void untouched(void) {
    SGSingGuideReset();
    double in, kept = play(5, 0, true, 108, 122, &in);   // no lyrics
    assert(fabs(kept - in) < in * 1e-6 && SGSingGuideStateOf(5, NULL) == SGSingGuideOff);
    SGSingGuideSetLyrics(5, lines, lineCount, NULL);
    SGSingGuideSetEnabled(false);
    kept = play(5, 0, true, 108, 122, &in);
    assert(fabs(kept - in) < in * 1e-6 && SGSingGuideStateOf(5, NULL) == SGSingGuideOff);
    SGSingGuideSetEnabled(true);
}

// The same lines handed over again keep what the play heard; a fifth song pushes out the oldest.
static void holding(void) {
    SGSingGuideReset();
    SGSingGuideSetLyrics(6, lines, lineCount, NULL);
    play(6, 300, false, 0, 0, NULL);
    SGSingGuideSetLyrics(6, lines, lineCount, NULL);
    int32_t shift;
    assert(SGSingGuideStateOf(6, &shift) == SGSingGuideFollowing && abs(shift - 300) <= 50);
    for (uint64_t t = 7; t < 11; t++) SGSingGuideSetLyrics(t, lines, lineCount, NULL);
    assert(SGSingGuideStateOf(6, NULL) == SGSingGuideOff);
}

int main(void) {
    verse(20, 60); verse(70, 100); verse(130, 170);
    SGSingGuideSetEnabled(true);
    linesUp(); early(); onTime(); mismatch(); untouched(); holding();
    puts("guide ok");
    return 0;
}
