#ifndef DIFZ_RUST_H
#define DIFZ_RUST_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* Experimental Rust boundary. Native filesystem entry points are pending.
 * Inputs are borrowed pointer/length pairs; NULL is allowed only at length 0.
 * Other pointers must be aligned, valid and live for the complete call.
 * Out parameters are unchanged on error. Rust panics are caught; native
 * zstdz process failures and allocator/OS aborts cannot be caught here. */
enum difz_status {
    DIFZ_OK = 0, DIFZ_INVALID_DATA = -1, DIFZ_WRONG_SOURCE = -2,
    DIFZ_LIMIT = -4, DIFZ_OUT_OF_MEMORY = -5, DIFZ_ARGUMENT = -6,
    DIFZ_PANIC = -7
};
typedef struct difz_buffer difz_buffer;

/* Encode bounds are checked after compression. Apply rejects an advertised
 * output above max_bytes before allocating it. Zero means the codec limit. */
int32_t difz_file_encode(const uint8_t *source, size_t source_len,
    const uint8_t *target, size_t target_len, size_t max_bytes, difz_buffer **out);
int32_t difz_file_apply(const uint8_t *source, size_t source_len,
    const uint8_t *patch, size_t patch_len, size_t max_bytes, difz_buffer **out);

/* Only handles returned by a successful call are valid. Data is immutable and
 * remains live until free; empty data is NULL. NULL handles may be queried or
 * freed. Free exactly once. Callers never supply an allocation size/capacity. */
const uint8_t *difz_buffer_data(const difz_buffer *buffer);
size_t difz_buffer_len(const difz_buffer *buffer);
void difz_buffer_free(difz_buffer *buffer);

/* Length-delimited omission grammar, including rejection of embedded NUL. */
int32_t difz_metadata_omit_parse(const uint8_t *text, size_t len, uint32_t *out);
#ifdef __cplusplus
}
#endif
#endif
