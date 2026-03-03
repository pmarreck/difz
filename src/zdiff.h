#ifndef ZDIFF_H
#define ZDIFF_H

#include <stddef.h>
#include <stdint.h>

/* Compute a binary diff between files A and B.
 * seed: 32-byte rolling hash seed (NULL for random).
 * compression: 0=best, 1=lzma2, 2=bzip2, 3=lz4, 255=none.
 * Returns 0 on success, -1 on error. */
int zdiff_diff(
    const uint8_t *a, size_t a_len,
    const uint8_t *b, size_t b_len,
    const uint8_t seed[32],
    size_t target_chunk_size,
    uint8_t compression,
    uint8_t **out, size_t *out_len);

/* Apply a diff to file A to reconstruct file B.
 * Returns 0 on success, -1 on error. */
int zdiff_patch(
    const uint8_t *a, size_t a_len,
    const uint8_t *diff, size_t diff_len,
    uint8_t **out, size_t *out_len);

/* Inspect a diff blob and produce a human-readable text description.
 * max_data_bytes: truncate INSERT data display (0 = no limit).
 * hexlike: if non-zero, use hexlike encoding for binary data.
 * Returns 0 on success, -1 on error. */
int zdiff_inspect(
    const uint8_t *diff, size_t diff_len,
    size_t max_data_bytes, int hexlike,
    uint8_t **out, size_t *out_len);

/* Free memory returned by zdiff_diff, zdiff_patch, or zdiff_inspect. */
void zdiff_free(uint8_t *ptr, size_t len);

#endif
