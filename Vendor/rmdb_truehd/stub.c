// x86_64 simulators only (Rust has no x86_64 tvOS simulator target): the
// decoder reports itself unavailable and KSPlayer plays TrueHD via FFmpeg.
#include "include/rmdb_truehd.h"
ThdDecoder *thd_decoder_new(void) { return 0; }
void thd_decoder_free(ThdDecoder *decoder) { (void)decoder; }
void thd_decoder_reset(ThdDecoder *decoder) { (void)decoder; }
int32_t thd_decoder_push(ThdDecoder *decoder, const uint8_t *data, size_t length) { (void)decoder; (void)data; (void)length; return -1; }
int32_t thd_decoder_next(ThdDecoder *decoder, ThdFrame *out) { (void)decoder; (void)out; return 0; }
int32_t thd_decoder_next_rendered(ThdDecoder *decoder, ThdRendered *out) { (void)decoder; (void)out; return 0; }
uint64_t thd_decoder_error_count(const ThdDecoder *decoder) { (void)decoder; return 0; }
