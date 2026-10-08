#ifndef DIFZ_H
#define DIFZ_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct difz_path_rule {
	uint8_t action; /* 1=include, 2=exclude */
	const char *pattern;
} difz_path_rule;

/* Optional stage callback. `total` is 0 when the stage is indeterminate.
 * The library never holds private keys; ceilings are byte/time/RSS caps only. */
typedef void (*difz_progress_fn)(
	const char *stage, uint64_t done, uint64_t total, void *user);
void difz_set_progress_callback(difz_progress_fn fn, void *user);

/* Compute a zstd level-9 prefix patch from file A to file B.
 * Inputs are borrowed. On success, *out is a new buffer owned by the caller
 * and must be released with difz_free(*out, *out_len) using those exact values.
 * On error, output parameters are left unchanged and the return is -1.
 * Returns 0 on success, -1 on error, -4 if the encoded patch exceeds
 * max_output_bytes (0 = unlimited) in difz_diff_limited. */
int difz_diff(
    const uint8_t *a, size_t a_len,
    const uint8_t *b, size_t b_len,
    uint8_t **out, size_t *out_len);
int difz_diff_limited(
    const uint8_t *a, size_t a_len,
    const uint8_t *b, size_t b_len,
    size_t max_output_bytes,
    uint8_t **out, size_t *out_len);

/* Apply a diff to file A to reconstruct file B.
 * Returns 0 on success, -1 on error, -4 if reconstruction would exceed
 * max_output_bytes (0 = unlimited) in difz_patch_limited. */
int difz_patch(
    const uint8_t *a, size_t a_len,
    const uint8_t *diff, size_t diff_len,
    uint8_t **out, size_t *out_len);
int difz_patch_limited(
    const uint8_t *a, size_t a_len,
    const uint8_t *diff, size_t diff_len,
    size_t max_output_bytes,
    uint8_t **out, size_t *out_len);

enum difz_metadata_family {
	DIFZ_METADATA_XATTR = 1,
	DIFZ_METADATA_ACL = 2,
	DIFZ_METADATA_TIMESTAMPS = 4,
	DIFZ_METADATA_FINDER = 8,
	DIFZ_METADATA_SPARSE = 16,
	DIFZ_METADATA_HARDLINK = 32
};

/* Parse a comma-separated omission list into the bits above. Empty text means
 * no omissions. Returns -1 for unknown, empty, or duplicate list elements,
 * leaving *out_mask unchanged. */
int difz_parse_metadata_omit(const char *text, uint32_t *out_mask);

/* Compute a deterministic DIFZTREE patch from two directory paths.
 * Rules are applied in order; later matching rules win.
 * omit_metadata is a bitwise OR of difz_metadata_family values. It is stored
 * in the patch and applied before capture and hashing, including during apply.
 * Returns 0 on success, -1 on error. */
int difz_directory_diff(
	const char *source_path, const char *target_path,
	const difz_path_rule *rules, size_t rule_count,
	uint32_t omit_metadata,
	uint8_t **out, size_t *out_len);

/* Apply a DIFZTREE patch into a new output directory through a verified,
 * uniquely named sibling stage. The source and any existing output are never
 * modified. Returns 0 on success, -2 for a wrong source, -3 when output exists,
 * and -1 for other errors. */
int difz_directory_patch(
	const char *source_path,
	const uint8_t *patch, size_t patch_len,
	const char *output_path);

/* Write a new file through a uniquely named sibling and non-replacing rename.
 * Returns -3 if the output already exists and -1 for other errors. */
int difz_write_new_file_atomic(
	const char *output_path,
	const uint8_t *data, size_t data_len);

/* Describe a ZDIF v4 patch: sizes, BLAKE3 identities, and the zstd frame.
 * Returns 0 on success, -1 on error. */
int difz_inspect(
    const uint8_t *diff, size_t diff_len,
    uint8_t **out, size_t *out_len);

/* Free a buffer returned by difz_diff, difz_patch, difz_directory_diff, or
 * difz_inspect. Pass the same pointer and length the call returned. Do not
 * use C free(). Null ptr is ignored. */
void difz_free(uint8_t *ptr, size_t len);

#ifdef __cplusplus
}
#endif

#endif
