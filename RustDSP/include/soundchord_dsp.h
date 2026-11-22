#ifndef SOUNDCHORD_DSP_H
#define SOUNDCHORD_DSP_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
    int32_t root;       // 0..11 (C..B)
    int32_t quality;    // 0=maj, 1=min, 2=7, 3=maj7, 4=m7
    double confidence;
    double start_time;
    double end_time;
} ScChordSegment;

typedef struct {
    int32_t bar_index;
    int32_t beat_index; // 0..beats_per_bar-1
    int32_t root;       // -1 if no chord
    int32_t quality;    // 0..4
    uint8_t is_chord_change;
    double start_time;
    double end_time;
} ScBeatCell;

typedef struct {
    int32_t kind;       // 0=Intro, 1=Verse, 2=PreChorus, 3=Chorus, 4=Bridge, 5=Outro
    double start_time;
    double end_time;
} ScSection;

typedef struct {
    ScChordSegment* segments;
    size_t segment_count;
    ScBeatCell* beats;
    size_t beat_count;
    ScSection* sections;
    size_t section_count;
    int32_t key_root;
    uint8_t key_is_minor;
    uint8_t has_key;
    double bpm;
    int32_t beats_per_bar;
    double duration;
} ScTimelineResult;

typedef struct {
    int32_t root;
    int32_t quality;
    double confidence;
    int32_t key_root;
    uint8_t key_is_minor;
    uint8_t has_key;
    float chroma[12];
    uint8_t has_chord;
} ScRealtimeSnapshot;

ScTimelineResult* sc_analyze_pcm(const float* samples, size_t len, double sample_rate, uint8_t simple_mode, double known_duration);
void sc_free_timeline(ScTimelineResult* res);
void* sc_realtime_new(void);
void sc_realtime_ingest(void* handle, const float* samples, size_t count, double sample_rate);
ScRealtimeSnapshot sc_realtime_analyze(void* handle, uint8_t simple_mode);
void sc_realtime_reset(void* handle);
void sc_realtime_free(void* handle);
#ifdef __cplusplus
}
#endif
#endif
