/* zdiff CLI — dogfoods the zdiff C FFI.
 * Computes binary diffs (CDC + Elder/Myers O(ND)) and applies patches.
 *
 * Build: linked against libzdiff.a via build.zig
 * Usage: zdiff <file_a> <file_b> [-o output]
 *        zdiff --patch <file_a> <diff_file> [-o output]
 */

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>

#include "zdiff.h"

#define ZDIFF_VERSION "0.1.0"

/* ── Platform / arch detection ─────────────────────────────────────── */

#if defined(__APPLE__)
	#define ZDIFF_PLATFORM "macOS"
#elif defined(_WIN32) || defined(_WIN64)
	#define ZDIFF_PLATFORM "Windows"
#elif defined(__linux__)
	#define ZDIFF_PLATFORM "Linux"
#elif defined(__FreeBSD__)
	#define ZDIFF_PLATFORM "FreeBSD"
#else
	#define ZDIFF_PLATFORM "Unknown"
#endif

#if defined(__aarch64__) || defined(_M_ARM64)
	#define ZDIFF_ARCH "aarch64"
#elif defined(__x86_64__) || defined(_M_X64)
	#define ZDIFF_ARCH "x86_64"
#elif defined(__i386__) || defined(_M_IX86)
	#define ZDIFF_ARCH "x86"
#elif defined(__arm__) || defined(_M_ARM)
	#define ZDIFF_ARCH "arm"
#else
	#define ZDIFF_ARCH "unknown"
#endif

/* ── Helpers ───────────────────────────────────────────────────────── */

static void print_usage(FILE *out) {
	fprintf(out,
		"Usage: zdiff [options] <file_a> <file_b>\n"
		"       zdiff --patch [options] <file_a> <diff_file>\n"
		"\n"
		"Modes:\n"
		"  (default)     Compute a binary diff between file_a and file_b\n"
		"  --patch       Apply a diff to file_a to reconstruct file_b\n"
		"\n"
		"Options:\n"
		"  -h, --help         Show this help message\n"
		"  --about            Show version, platform, architecture\n"
		"  -o <file>          Output file (default: stdout)\n"
		"  --seed <hex>       32-byte seed as 64-char hex string\n"
		"  --chunk-size <n>   Target CDC chunk size (default: 1024)\n"
		"  --no-progress      Suppress progress/stats output\n"
		"  --no-ansi, --no-color  Suppress ANSI escape codes\n"
		"  --simple           Suppress both ANSI and emoji\n"
		"\n"
		"Special paths:\n"
		"  -  or @stdin   Read from stdin\n"
		"  -  or @stdout  Write to stdout\n"
		"  @stderr        Write to stderr\n"
	);
}

static void print_about(void) {
	fprintf(stdout, "zdiff %s -- fast binary differ (CDC + Elder/Myers O(ND)) -- %s %s\n",
		ZDIFF_VERSION, ZDIFF_PLATFORM, ZDIFF_ARCH);
}

/* Parse a single hex character to its value (0-15), or -1 on error. */
static int hex_digit(char c) {
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return 10 + (c - 'a');
	if (c >= 'A' && c <= 'F') return 10 + (c - 'A');
	return -1;
}

/* Parse a 64-char hex string into a 32-byte seed buffer.
 * Returns 0 on success, -1 on error. */
static int parse_hex_seed(const char *hex, uint8_t seed[32]) {
	if (strlen(hex) != 64) return -1;
	for (int i = 0; i < 32; i++) {
		int hi = hex_digit(hex[i * 2]);
		int lo = hex_digit(hex[i * 2 + 1]);
		if (hi < 0 || lo < 0) return -1;
		seed[i] = (uint8_t)((hi << 4) | lo);
	}
	return 0;
}

/* Read an entire file into a malloc'd buffer. Sets *out_len.
 * Returns the buffer on success, NULL on error (message printed to stderr). */
static uint8_t *read_file(const char *path, size_t *out_len) {
	FILE *f;
	int is_stdin = 0;

	if (strcmp(path, "-") == 0 || strcmp(path, "@stdin") == 0) {
		f = stdin;
		is_stdin = 1;
	} else {
		f = fopen(path, "rb");
		if (!f) {
			fprintf(stderr, "zdiff: cannot open '%s': %s\n", path, strerror(errno));
			return NULL;
		}
	}

	/* Read in chunks into a growing buffer */
	size_t cap = 4096;
	size_t len = 0;
	uint8_t *buf = malloc(cap);
	if (!buf) {
		fprintf(stderr, "zdiff: out of memory\n");
		if (!is_stdin) fclose(f);
		return NULL;
	}

	while (1) {
		if (len == cap) {
			cap *= 2;
			uint8_t *new_buf = realloc(buf, cap);
			if (!new_buf) {
				fprintf(stderr, "zdiff: out of memory\n");
				free(buf);
				if (!is_stdin) fclose(f);
				return NULL;
			}
			buf = new_buf;
		}
		size_t n = fread(buf + len, 1, cap - len, f);
		if (n == 0) break;
		len += n;
	}

	if (ferror(f)) {
		fprintf(stderr, "zdiff: read error on '%s': %s\n", path, strerror(errno));
		free(buf);
		if (!is_stdin) fclose(f);
		return NULL;
	}

	if (!is_stdin) fclose(f);
	*out_len = len;
	return buf;
}

/* Write a buffer to a file/stdout/stderr.
 * Returns 0 on success, -1 on error (message printed to stderr). */
static int write_output(const char *path, const uint8_t *data, size_t len) {
	FILE *f;
	int needs_close = 0;

	if (path == NULL || strcmp(path, "-") == 0 || strcmp(path, "@stdout") == 0) {
		f = stdout;
	} else if (strcmp(path, "@stderr") == 0) {
		f = stderr;
	} else {
		f = fopen(path, "wb");
		if (!f) {
			fprintf(stderr, "zdiff: cannot open output '%s': %s\n", path, strerror(errno));
			return -1;
		}
		needs_close = 1;
	}

	if (len > 0) {
		size_t written = fwrite(data, 1, len, f);
		if (written != len) {
			fprintf(stderr, "zdiff: write error: %s\n", strerror(errno));
			if (needs_close) fclose(f);
			return -1;
		}
	}

	if (needs_close) fclose(f);
	return 0;
}

/* Format a byte count into a human-readable string (e.g. "12.4 KB"). */
static void format_size(size_t bytes, char *buf, size_t buf_size) {
	if (bytes < 1024) {
		snprintf(buf, buf_size, "%zu B", bytes);
	} else if (bytes < 1024 * 1024) {
		snprintf(buf, buf_size, "%.1f KB", (double)bytes / 1024.0);
	} else if (bytes < 1024 * 1024 * 1024) {
		snprintf(buf, buf_size, "%.1f MB", (double)bytes / (1024.0 * 1024.0));
	} else {
		snprintf(buf, buf_size, "%.1f GB", (double)bytes / (1024.0 * 1024.0 * 1024.0));
	}
}

/* ── Main ──────────────────────────────────────────────────────────── */

int main(int argc, char *argv[]) {
	/* Debug build announcement */
#ifdef ZDIFF_DEBUG
	if (isatty(STDERR_FILENO)) {
		fprintf(stderr, "\033[33mDEBUG BUILD\033[0m\n");
	} else {
		fprintf(stderr, "DEBUG BUILD\n");
	}
#endif

	/* Defaults */
	int patch_mode = 0;
	const char *output_path = NULL;  /* NULL = stdout */
	const char *seed_hex = NULL;
	size_t chunk_size = 1024;
	int no_progress = 0;
	/* int no_ansi = 0; */  /* reserved for future use */
	/* int simple = 0; */   /* reserved for future use */

	/* Positional args collector */
	const char *positional[2] = {NULL, NULL};
	int pos_count = 0;

	/* Parse arguments — later args override earlier ones */
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
			print_usage(stdout);
			return 0;
		}
		if (strcmp(argv[i], "--about") == 0) {
			print_about();
			return 0;
		}
		if (strcmp(argv[i], "--patch") == 0) {
			patch_mode = 1;
			continue;
		}
		if (strcmp(argv[i], "-o") == 0) {
			if (i + 1 >= argc) {
				fprintf(stderr, "zdiff: -o requires an argument\n");
				return 1;
			}
			output_path = argv[++i];
			continue;
		}
		if (strcmp(argv[i], "--seed") == 0) {
			if (i + 1 >= argc) {
				fprintf(stderr, "zdiff: --seed requires a 64-character hex argument\n");
				return 1;
			}
			seed_hex = argv[++i];
			continue;
		}
		if (strcmp(argv[i], "--chunk-size") == 0) {
			if (i + 1 >= argc) {
				fprintf(stderr, "zdiff: --chunk-size requires a numeric argument\n");
				return 1;
			}
			char *endptr;
			long val = strtol(argv[++i], &endptr, 10);
			if (*endptr != '\0' || val <= 0) {
				fprintf(stderr, "zdiff: invalid chunk-size: '%s'\n", argv[i]);
				return 1;
			}
			chunk_size = (size_t)val;
			continue;
		}
		if (strcmp(argv[i], "--no-progress") == 0) {
			no_progress = 1;
			continue;
		}
		if (strcmp(argv[i], "--no-ansi") == 0 || strcmp(argv[i], "--no-color") == 0) {
			/* no_ansi = 1; */
			continue;
		}
		if (strcmp(argv[i], "--simple") == 0) {
			/* simple = 1; */
			/* no_ansi = 1; */
			continue;
		}

		/* Unknown option */
		if (argv[i][0] == '-' && argv[i][1] == '-') {
			fprintf(stderr, "zdiff: unknown option '%s'\n", argv[i]);
			return 1;
		}

		/* Positional argument */
		if (pos_count < 2) {
			positional[pos_count++] = argv[i];
		} else {
			fprintf(stderr, "zdiff: too many arguments\n");
			return 1;
		}
	}

	/* Validate positional args */
	if (pos_count < 2) {
		fprintf(stderr, "zdiff: expected 2 file arguments, got %d\n", pos_count);
		fprintf(stderr, "Try 'zdiff --help' for usage.\n");
		return 1;
	}

	/* Parse seed if provided */
	uint8_t seed_buf[32];
	uint8_t *seed_ptr = NULL;
	if (seed_hex) {
		if (parse_hex_seed(seed_hex, seed_buf) != 0) {
			fprintf(stderr, "zdiff: invalid seed: must be exactly 64 hex characters\n");
			return 1;
		}
		seed_ptr = seed_buf;
	}

	/* Read input files */
	size_t a_len = 0, b_len = 0;
	uint8_t *a_data = read_file(positional[0], &a_len);
	if (!a_data) return 1;

	uint8_t *b_data = read_file(positional[1], &b_len);
	if (!b_data) {
		free(a_data);
		return 1;
	}

	int exit_code = 0;

	if (patch_mode) {
		/* ── Patch mode ──────────────────────────────────── */
		uint8_t *result_ptr = NULL;
		size_t result_len = 0;

		int rc = zdiff_patch(a_data, a_len, b_data, b_len, &result_ptr, &result_len);
		if (rc != 0) {
			fprintf(stderr, "zdiff: patch failed\n");
			exit_code = 1;
		} else {
			if (write_output(output_path, result_ptr, result_len) != 0) {
				exit_code = 1;
			} else if (!no_progress && isatty(STDERR_FILENO)) {
				char size_str[64];
				format_size(result_len, size_str, sizeof(size_str));
				fprintf(stderr, "zdiff: Done. Reconstructed: %s\n", size_str);
			}
			zdiff_free(result_ptr, result_len);
		}
	} else {
		/* ── Diff mode ───────────────────────────────────── */
		uint8_t *diff_ptr = NULL;
		size_t diff_len = 0;

		int rc = zdiff_diff(a_data, a_len, b_data, b_len, seed_ptr, chunk_size,
		                    &diff_ptr, &diff_len);
		if (rc != 0) {
			fprintf(stderr, "zdiff: diff failed\n");
			exit_code = 1;
		} else {
			if (write_output(output_path, diff_ptr, diff_len) != 0) {
				exit_code = 1;
			} else if (!no_progress && isatty(STDERR_FILENO)) {
				/* Show stats */
				size_t original = (a_len > b_len) ? a_len : b_len;
				char diff_size_str[64];
				format_size(diff_len, diff_size_str, sizeof(diff_size_str));
				if (original > 0) {
					double pct = 100.0 * (double)diff_len / (double)original;
					fprintf(stderr, "zdiff: Done. Diff: %s (%.1f%% of original)\n",
						diff_size_str, pct);
				} else {
					fprintf(stderr, "zdiff: Done. Diff: %s\n", diff_size_str);
				}
			}
			zdiff_free(diff_ptr, diff_len);
		}
	}

	free(a_data);
	free(b_data);
	return exit_code;
}
