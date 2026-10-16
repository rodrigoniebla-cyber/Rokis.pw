// SGSingGuide.h. Plain C (compiled as Objective-C in the tweak, as C by harness/sing/guide_test.c).
#include "SGSingGuide.h"
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

enum {
    kRate = 44100,
    kBlock = kRate / 20,          // 50 ms: the vocals' level is heard in blocks this long
    kStep = 50,                   // ms between the shifts tried
    kReach = 30,                  // shifts tried either way: 1.5 s
    kShifts = kReach * 2 + 1,
    kSongs = 4,
    kSegment = kRate / 100,       // the gate is worked out every 10 ms and slid between
    kLearnBlocks = 400,           // 20 s of singing before the lyrics are lined up
    kTrustBlocks = 600,           // 30 s before deciding the lyrics don't match
    kMemoryBlocks = 6000,         // what an earlier play counts for at most, so new plays still move it
};
static const float kVoiced = 0.008f;      // a block quieter than this (RMS) is not singing
static const float kMismatch = 0.30f;     // this share of the singing outside the lyrics and they don't match
static const float kGain = 0.05f;         // how much better another shift has to line up to move to it
// Around each line: before it (breaths, early entries), after it (held notes, reverb), and the fade to none.
static const int32_t kLead = 350, kTail = 600, kLearningLead = 800, kLearningTail = 1200, kRamp = 250;

typedef struct {
    uint64_t track;
    uint64_t used;
    SGSingGuideSpan *spans;
    uint32_t count;
    // Heard this play: per shift tried, the level inside the lines (for lining up) and outside the gate
    // (for trusting); and in all, the level and the blocks.
    double inside[kShifts], outsideGate[kShifts], within[kShifts];
    double energy;
    uint32_t heard, blocks;      // all blocks, and the voiced ones
    SGSingGuideMemory memory;    // what earlier plays learned
    int32_t shift;
    bool lined, mismatch;
} Song;

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static Song songs[kSongs];
static uint64_t uses;
static atomic_bool enabled;

void SGSingGuideSetEnabled(bool on) { atomic_store(&enabled, on); }
bool SGSingGuideEnabled(void) { return atomic_load(&enabled); }

static Song *find(uint64_t track) {
    if (!track) return NULL;
    for (int n = 0; n < kSongs; n++) if (songs[n].track == track) return &songs[n];
    return NULL;
}
static void clear(Song *s) { free(s->spans); memset(s, 0, sizeof *s); }

// Whether `ms` (lyrics time) falls in a line, widened by lead and tail; and the distance past them if not.
static int32_t distance(const Song *s, int32_t ms, int32_t lead, int32_t tail) {
    uint32_t lo = 0, hi = s->count;
    // The last line starting at or before ms + lead.
    while (lo < hi) {
        uint32_t mid = (lo + hi) / 2;
        if (s->spans[mid].start - lead <= ms) lo = mid + 1; else hi = mid;
    }
    int32_t best = INT32_MAX;
    // Lines overlap (two voices), so a few before it are looked at too.
    for (uint32_t n = lo; n > 0 && n + 8 > lo; n--) {
        const SGSingGuideSpan *span = &s->spans[n - 1];
        int32_t end = span->end + tail;
        if (ms <= end) return 0;
        if (ms - end < best) best = ms - end;
    }
    if (lo < s->count) {
        int32_t ahead = s->spans[lo].start - lead - ms;
        if (ahead < best) best = ahead;
    }
    return best;
}
static bool inLine(const Song *s, int32_t ms) { return distance(s, ms, 0, 0) == 0; }

static void decide(Song *s) {
    SGSingGuideMemory *m = &s->memory;
    int32_t shift = m->blocks ? m->shift : 0;
    bool lined = m->blocks >= kLearnBlocks;
    if (s->blocks >= kLearnBlocks) {
        // Pearson's r of the level against "in a line" for each shift; the level's spread is the same for
        // all, so it is left out.
        double b = s->heard, mean = s->energy / b, best = -INFINITY, current = -INFINITY;
        int bestShift = 0;
        for (int k = 0; k < kShifts; k++) {
            double p = s->within[k] / b;
            if (p <= 0 || p >= 1) continue;
            double r = (s->inside[k] / b - mean * p) / sqrt(p * (1 - p));
            int32_t at = (k - kReach) * kStep;
            if (at == shift) current = r;
            // Ties go to the shift nearest none.
            if (r > best + 1e-12 || (fabs(r - best) <= 1e-12 && abs(at) < abs(bestShift))) { best = r; bestShift = at; }
        }
        if (!isfinite(current) || best > current + fabs(current) * kGain) shift = bestShift;
        lined = true;
    }
    s->shift = shift; s->lined = lined;
    double energy = s->energy + m->energy, outside = s->outsideGate[shift / kStep + kReach] + m->outside;
    // The singing heard outside the lyrics is a share of what was heard at all, once there has been enough.
    s->mismatch = s->blocks + m->blocks >= kTrustBlocks && energy > 0 && outside / energy > kMismatch;
}

void SGSingGuideSetLyrics(uint64_t track, const SGSingGuideSpan *spans, uint32_t count, const SGSingGuideMemory *memory) {
    if (!track) return;
    SGSingGuideSpan *copy = count ? malloc(count * sizeof *copy) : NULL;
    if (count && !copy) return;
    if (count) memcpy(copy, spans, count * sizeof *copy);
    pthread_mutex_lock(&lock);
    Song *s = find(track);
    if (s && s->count == count && (!count || !memcmp(s->spans, copy, count * sizeof *copy))) {
        s->used = ++uses; free(copy);   // the same lines again: keep what this play heard
        pthread_mutex_unlock(&lock);
        return;
    }
    if (!s) {
        s = &songs[0];
        for (int n = 1; n < kSongs; n++) if (songs[n].used < s->used) s = &songs[n];
    }
    clear(s);
    s->track = track; s->used = ++uses; s->spans = copy; s->count = count;
    if (memory) {
        s->memory = *memory;
        if (s->memory.shift < -kReach * kStep || s->memory.shift > kReach * kStep) s->memory.shift = 0;
        s->memory.shift = s->memory.shift / kStep * kStep;
        if (s->memory.blocks > kMemoryBlocks) {
            float scale = (float)kMemoryBlocks / s->memory.blocks;
            s->memory.energy *= scale; s->memory.outside *= scale; s->memory.blocks = kMemoryBlocks;
        }
    }
    decide(s);
    pthread_mutex_unlock(&lock);
}

void SGSingGuideDrop(uint64_t track) {
    pthread_mutex_lock(&lock);
    Song *s = find(track);
    if (s) clear(s);
    pthread_mutex_unlock(&lock);
}

void SGSingGuideReset(void) {
    pthread_mutex_lock(&lock);
    for (int n = 0; n < kSongs; n++) clear(&songs[n]);
    pthread_mutex_unlock(&lock);
}

static void learn(Song *s, double seconds, const float *vocals, uint32_t frames) {
    for (uint32_t at = 0; at + kBlock <= frames; at += kBlock) {
        double sum = 0;
        for (uint32_t n = at; n < at + kBlock; n++) {
            float mid = 0.5f * (vocals[n * 2] + vocals[n * 2 + 1]);
            sum += mid * mid;
        }
        float level = sqrtf((float)(sum / kBlock));
        if (!isfinite(level) || level < kVoiced) level = 0;
        int32_t ms = (int32_t)lround(seconds * 1000 + (at + kBlock / 2) * 1000.0 / kRate);
        s->energy += level;
        s->heard++;
        if (level > 0) s->blocks++;
        for (int k = 0; k < kShifts; k++) {
            int32_t lyric = ms - (k - kReach) * kStep;
            if (inLine(s, lyric)) { s->inside[k] += level; s->within[k] += 1; }
            if (level > 0 && distance(s, lyric, kLead, kTail) > 0) s->outsideGate[k] += level;
        }
    }
}

static float gate(const Song *s, double ms) {
    int32_t lead = s->lined ? kLead : kLearningLead, tail = s->lined ? kTail : kLearningTail;
    int32_t d = distance(s, (int32_t)lround(ms) - s->shift, lead, tail);
    return d <= 0 ? 1 : d >= kRamp ? 0 : 1 - (float)d / kRamp;
}

void SGSingGuideProcess(uint64_t track, double seconds, const float *vocals, float *out, uint32_t frames) {
    if (out != vocals) memcpy(out, vocals, (size_t)frames * 2 * sizeof(float));
    if (!atomic_load(&enabled) || !isfinite(seconds)) return;
    pthread_mutex_lock(&lock);
    Song *s = find(track);
    if (!s || !s->count) { pthread_mutex_unlock(&lock); return; }
    learn(s, seconds, vocals, frames);
    decide(s);
    if (!s->mismatch) {
        double start = seconds * 1000, perFrame = 1000.0 / kRate;
        float from = gate(s, start);
        for (uint32_t at = 0; at < frames; at += kSegment) {
            uint32_t count = frames - at < kSegment ? frames - at : kSegment;
            float to = gate(s, start + (at + count) * perFrame);
            if (from < 1 || to < 1) {
                for (uint32_t n = 0; n < count; n++) {
                    float g = from + (to - from) * (float)n / count;
                    out[(at + n) * 2] *= g; out[(at + n) * 2 + 1] *= g;
                }
            }
            from = to;
        }
    }
    pthread_mutex_unlock(&lock);
}

SGSingGuideState SGSingGuideStateOf(uint64_t track, int32_t *shift) {
    if (!atomic_load(&enabled)) return SGSingGuideOff;
    pthread_mutex_lock(&lock);
    Song *s = find(track);
    SGSingGuideState state = !s || !s->count ? SGSingGuideOff : s->mismatch ? SGSingGuideMismatch :
        s->lined ? SGSingGuideFollowing : SGSingGuideLearning;
    if (shift) *shift = s ? s->shift : 0;
    pthread_mutex_unlock(&lock);
    return state;
}

bool SGSingGuideMemoryOf(uint64_t track, SGSingGuideMemory *memory) {
    pthread_mutex_lock(&lock);
    Song *s = find(track);
    bool heard = s && s->count && s->blocks + s->memory.blocks > 0;
    if (heard) {
        memory->shift = s->shift;
        memory->energy = s->memory.energy + (float)s->energy;
        memory->outside = s->memory.outside + (float)s->outsideGate[s->shift / kStep + kReach];
        memory->blocks = s->memory.blocks + s->blocks;
    }
    pthread_mutex_unlock(&lock);
    return heard;
}
