// C API of rmdb_truehd (Rust, over the `truehd` crate): TrueHD Atmos
// presentation elements + object audio metadata. See src/lib.rs.
#ifndef RMDB_TRUEHD_H
#define RMDB_TRUEHD_H

#include <stdint.h>
#include <stddef.h>

#define THD_MAX_SAMPLES 160
#define THD_MAX_ELEMENTS 16
#define THD_MAX_UPDATES 4

typedef struct ThdDecoder ThdDecoder;

/// One element of the presentation as of an update.
typedef struct ThdElement {
    /// 1 = bed channel at `speaker`, 0 = object at x, y, z.
    uint8_t is_bed;
    /// 0 L, 1 R, 2 C, 3 LFE, 4 Lss, 5 Rss, 6 Lrs, 7 Rrs, 8 Lfh, 9 Rfh,
    /// 10 Lts, 11 Rts, 12 Lrh, 13 Rrh, 14 Lw, 15 Rw, 16 LFE2.
    uint8_t speaker;
    uint8_t active;
    uint8_t snap;
    uint8_t elevation;
    /// 0 all, 1 no back, 2 no sides, 3 center back, 4 screen only, 5 surround only.
    uint8_t zones;
    uint8_t reserved[2];
    /// x −1 left … 1 right, y −1 back … 1 front, z 0 floor … 1 ceiling.
    float x;
    float y;
    float z;
    float size;
    /// Linear gain, 0 = −∞ dB.
    float gain;
} ThdElement;

/// Applies `sample_offset` samples into the access unit, reached linearly over `ramp` samples.
typedef struct ThdUpdate {
    uint32_t sample_offset;
    uint32_t ramp;
    uint32_t element_count;
    ThdElement elements[THD_MAX_ELEMENTS];
} ThdUpdate;

typedef struct ThdFrame {
    uint32_t sample_rate;
    uint32_t sample_count;
    uint32_t element_count;
    /// Interleaved [sample][element], full scale ±1.
    float pcm[THD_MAX_SAMPLES * THD_MAX_ELEMENTS];
    uint32_t update_count;
    ThdUpdate updates[THD_MAX_UPDATES];
} ThdFrame;

ThdDecoder *thd_decoder_new(void);
void thd_decoder_free(ThdDecoder *decoder);
/// Drops all state (seek). Decoding resumes at the next major sync.
void thd_decoder_reset(ThdDecoder *decoder);
/// Feeds bitstream bytes; returns the number of decoded access units waiting, −1 on a fault.
int32_t thd_decoder_push(ThdDecoder *decoder, const uint8_t *data, size_t length);
/// 1 = `out` filled, 0 = nothing waiting, −1 = fault.
int32_t thd_decoder_next(ThdDecoder *decoder, ThdFrame *out);
uint64_t thd_decoder_error_count(const ThdDecoder *decoder);

#endif
