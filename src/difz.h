#ifndef DIFZ_H
#define DIFZ_H

#include <stddef.h>
#include <stdint.h>

typedef struct difz_path_rule {
	uint8_t action; /* 1=include, 2=exclude */
	const char *pattern;
} difz_path_rule;

/* Compute a binary diff between files A and B.
 * seed: 32-byte rolling hash seed (NULL for random).
 * compression: 0=best, 1=lzma2, 2=bzip2, 3=lz4, 4=zstd, 255=none.
 * Returns 0 on success, -1 on error. */
int difz_diff(
    const uint8_t *a, size_t a_len,
    const uint8_t *b, size_t b_len,
    const uint8_t seed[32],
    size_t target_chunk_size,
    uint8_t compression,
    uint8_t **out, size_t *out_len);

/* Apply a diff to file A to reconstruct file B.
 * Returns 0 on success, -1 on error. */
int difz_patch(
    const uint8_t *a, size_t a_len,
    const uint8_t *diff, size_t diff_len,
    uint8_t **out, size_t *out_len);

/* Compute a deterministic DIFZTREE patch from two directory paths.
 * Rules are applied in order; later matching rules win.
 * Returns 0 on success, -1 on error. */
int difz_directory_diff(
	const char *source_path, const char *target_path,
	const difz_path_rule *rules, size_t rule_count,
	const uint8_t seed[32], size_t target_chunk_size, uint8_t compression,
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

/* Inspect a diff blob and produce a human-readable text description.
 * max_data_bytes: truncate INSERT data display (0 = no limit).
 * hexlike: if non-zero, use hexlike encoding for binary data.
 * Returns 0 on success, -1 on error. */
int difz_inspect(
    const uint8_t *diff, size_t diff_len,
    size_t max_data_bytes, int hexlike,
    uint8_t **out, size_t *out_len);

/* Free memory returned by difz_diff, difz_patch, or difz_inspect. */
void difz_free(uint8_t *ptr, size_t len);

#endif
