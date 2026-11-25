#ifndef DIFZ_RUST_H
#define DIFZ_RUST_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* Experimental Rust boundary. Directory filesystem operations currently support
 * Linux; other targets return DIFZ_UNSUPPORTED until their adapters qualify.
 * Inputs are borrowed pointer/length pairs; NULL is allowed only at length 0.
 * Other pointers must be aligned, valid and live for the complete call.
 * Out parameters are unchanged on error. Rust panics are caught; native
 * zstdz process failures and allocator/OS aborts cannot be caught here. */
enum difz_status {
    DIFZ_OK = 0, DIFZ_INVALID_DATA = -1, DIFZ_WRONG_SOURCE = -2, DIFZ_IO = -3,
    DIFZ_LIMIT = -4, DIFZ_OUT_OF_MEMORY = -5, DIFZ_ARGUMENT = -6,
    DIFZ_PANIC = -7, DIFZ_UNSUPPORTED = -8
};
typedef struct difz_buffer difz_buffer;
typedef struct difz_file_info {
    uint8_t source_hash[32], target_hash[32];
    uint64_t source_len, target_len;
    size_t frame_len;
} difz_file_info;
typedef struct difz_path_rule {
    uint8_t action; /* 1 = include, 2 = exclude; later matching rules win */
    const uint8_t *pattern; /* length-delimited UTF-8 glob */
    size_t pattern_len;
} difz_path_rule;

/* Header fields only: no frame/source/digest verification or authorization
 * to allocate the advertised sizes. Output is aligned and disjoint from input;
 * it remains unchanged on every failure. */
int32_t difz_file_inspect(const uint8_t *patch, size_t patch_len, difz_file_info *out);

/* Encode bounds are checked after compression. Apply rejects an advertised
 * output above max_bytes before allocating it. Zero means the codec limit. */
int32_t difz_file_encode(const uint8_t *source, size_t source_len,
    const uint8_t *target, size_t target_len, size_t max_bytes, difz_buffer **out);
int32_t difz_file_apply(const uint8_t *source, size_t source_len,
    const uint8_t *patch, size_t patch_len, size_t max_bytes, difz_buffer **out);

/* Native paths are length-delimited OS bytes, nonempty and without NUL. Directory
 * snapshots have conservative default bounds when the corresponding maximum is
 * zero. Rules and omissions are stored in the v2 patch and govern apply. Encode
 * checks max_patch_bytes after compression; all returned bytes use the matching
 * buffer owner below. The rule array may be NULL only when rule_count is zero. */
int32_t difz_directory_encode(const uint8_t *source, size_t source_len,
    const uint8_t *target, size_t target_len,
    const difz_path_rule *rules, size_t rule_count, uint32_t omit,
    uint64_t max_snapshot_bytes, uint64_t max_patch_bytes, difz_buffer **out);

/* Publish a new child of the opened output parent; output_name is one basename.
 * Existing objects are preserved, including concurrent arrivals. The library
 * owns a private sibling stage and verifies its full identity before publishing.
 * Output inside the captured source is rejected. No native handle is retained.
 * Report bits correspond to compromise code minus one, preserving unsupported
 * metadata through canonical transports. out_report is unchanged on failure. */
int32_t difz_directory_apply(const uint8_t *source, size_t source_len,
    const uint8_t *patch, size_t patch_len,
    const uint8_t *output_parent, size_t output_parent_len,
    const uint8_t *output_name, size_t output_name_len,
    uint64_t max_snapshot_bytes, uint64_t max_output_bytes, uint32_t *out_report);

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
