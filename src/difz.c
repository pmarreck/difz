/* difz CLI — dogfoods the difz C FFI.
 * Computes binary diffs (CDC + Elder/Myers O(ND)) and applies patches.
 *
 * Build: linked against libdifz.a via build.zig
 * Usage: difz <file_a> <file_b> [-o output]
 *        difz --patch <file_a> <diff_file> [-o output]
 *        difz --inspect [--truncate N] [--hexlike] <diff_file>
 */

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/stat.h>
#include <unistd.h>

#include "difz.h"
#include "progrez.h"

#define DIFZ_VERSION "0.1.0"

/* ── Platform / arch detection ─────────────────────────────────────── */

#if defined(__APPLE__)
	#define DIFZ_PLATFORM "macOS"
#elif defined(_WIN32) || defined(_WIN64)
	#define DIFZ_PLATFORM "Windows"
#elif defined(__linux__)
	#define DIFZ_PLATFORM "Linux"
#elif defined(__FreeBSD__)
	#define DIFZ_PLATFORM "FreeBSD"
#else
	#define DIFZ_PLATFORM "Unknown"
#endif

#if defined(__aarch64__) || defined(_M_ARM64)
	#define DIFZ_ARCH "aarch64"
#elif defined(__x86_64__) || defined(_M_X64)
	#define DIFZ_ARCH "x86_64"
#elif defined(__i386__) || defined(_M_IX86)
	#define DIFZ_ARCH "x86"
#elif defined(__arm__) || defined(_M_ARM)
	#define DIFZ_ARCH "arm"
#else
	#define DIFZ_ARCH "unknown"
#endif

/* ── Helpers ───────────────────────────────────────────────────────── */

static void print_usage(FILE *out) {
	fprintf(out,
		"Usage: difz [options] <file_or_dir_a> <file_or_dir_b>\n"
		"       difz --patch [options] <file_or_dir_a> <diff_file>\n"
		"       difz --inspect [options] <diff_file>\n"
		"\n"
		"Modes:\n"
		"  (default)     Compute a binary diff between file_a and file_b\n"
		"  --patch       Apply a diff to file_a to reconstruct file_b\n"
		"  --inspect     Pretty-print the ops in a diff file\n"
		"\n"
		"Options:\n"
		"  -h, --help         Show this help message\n"
		"  --about            Show version, platform, architecture\n"
		"  -o <file>          Output file (default: stdout)\n"
		"  --seed <hex>       32-byte seed as 64-char hex string\n"
		"  --chunk-size <n>   Target CDC chunk size (default: 4096)\n"
		"  --compress <algo>  Compression: best, lzma2, bzip2, lz4, zstd, none (default: best)\n"
		"  --allow <glob>      Include matching directory paths (repeatable, ordered)\n"
		"  --deny <glob>       Exclude matching directory paths (repeatable, ordered)\n"
		"  --truncate <n>     Max bytes of INSERT data to display (default: 64)\n"
		"  --hexlike          Use hexlike encoding for binary data display\n"
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

enum path_kind {
	PATH_KIND_ERROR = -1,
	PATH_KIND_STREAM = 0,
	PATH_KIND_FILE = 1,
	PATH_KIND_DIRECTORY = 2,
	PATH_KIND_SPECIAL = 3
};

static enum path_kind classify_path(const char *path) {
	struct stat info;
	if (strcmp(path, "-") == 0 || strcmp(path, "@stdin") == 0) return PATH_KIND_STREAM;
#if defined(_WIN32) || defined(_WIN64)
	if (stat(path, &info) != 0) {
#else
	if (lstat(path, &info) != 0) {
#endif
		fprintf(stderr, "difz: cannot open or inspect '%s': %s\n", path, strerror(errno));
		return PATH_KIND_ERROR;
	}
	if (S_ISREG(info.st_mode)) return PATH_KIND_FILE;
	if (S_ISDIR(info.st_mode)) return PATH_KIND_DIRECTORY;
	return PATH_KIND_SPECIAL;
}

static void print_about(void) {
	fprintf(stdout, "difz %s -- fast binary differ (CDC + Elder/Myers O(ND)) -- %s %s\n",
		DIFZ_VERSION, DIFZ_PLATFORM, DIFZ_ARCH);
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
			fprintf(stderr, "difz: cannot open '%s': %s\n", path, strerror(errno));
			return NULL;
		}
	}

	/* Read in chunks into a growing buffer */
	size_t cap = 4096;
	size_t len = 0;
	uint8_t *buf = malloc(cap);
	if (!buf) {
		fprintf(stderr, "difz: out of memory\n");
		if (!is_stdin) fclose(f);
		return NULL;
	}

	while (1) {
		if (len == cap) {
			cap *= 2;
			uint8_t *new_buf = realloc(buf, cap);
			if (!new_buf) {
				fprintf(stderr, "difz: out of memory\n");
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
		fprintf(stderr, "difz: read error on '%s': %s\n", path, strerror(errno));
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
			fprintf(stderr, "difz: cannot open output '%s': %s\n", path, strerror(errno));
			return -1;
		}
		needs_close = 1;
	}

	if (len > 0) {
		size_t written = fwrite(data, 1, len, f);
		if (written != len) {
			fprintf(stderr, "difz: write error: %s\n", strerror(errno));
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

static int is_stdout_path(const char *path) {
	return path == NULL || strcmp(path, "-") == 0 || strcmp(path, "@stdout") == 0;
}

static int run_directory_diff(
	const char *source_path,
	const char *target_path,
	const char *output_path,
	const difz_path_rule *rules,
	size_t rule_count,
	const uint8_t *seed,
	size_t chunk_size,
	uint8_t compression
) {
	uint8_t *patch = NULL;
	size_t patch_len = 0;
	int rc = difz_directory_diff(
		source_path, target_path, rules, rule_count, seed,
		chunk_size, compression, &patch, &patch_len);
	if (rc != 0) {
		fprintf(stderr, "difz: directory diff failed\n");
		return 1;
	}
	if (is_stdout_path(output_path)) {
		rc = write_output(output_path, patch, patch_len);
	} else {
		rc = difz_write_new_file_atomic(output_path, patch, patch_len);
		if (rc == -3) fprintf(stderr, "difz: output already exists: '%s'\n", output_path);
		else if (rc != 0) fprintf(stderr, "difz: cannot commit output: '%s'\n", output_path);
	}
	difz_free(patch, patch_len);
	return rc == 0 ? 0 : 1;
}

static int run_directory_patch(
	const char *source_path,
	const char *patch_path,
	const char *output_path
) {
	size_t patch_len = 0;
	uint8_t *patch = read_file(patch_path, &patch_len);
	if (!patch) return 1;
	int rc = difz_directory_patch(source_path, patch, patch_len, output_path);
	free(patch);
	if (rc == -2) fprintf(stderr, "difz: directory patch source identity does not match\n");
	else if (rc == -3) fprintf(stderr, "difz: output already exists: '%s'\n", output_path);
	else if (rc != 0) fprintf(stderr, "difz: directory patch failed\n");
	return rc == 0 ? 0 : 1;
}

/* ── Main ──────────────────────────────────────────────────────────── */

int main(int argc, char *argv[]) {
	/* Debug build announcement */
#ifdef DIFZ_DEBUG
	if (isatty(STDERR_FILENO)) {
		fprintf(stderr, "\033[33mDEBUG BUILD\033[0m\n");
	} else {
		fprintf(stderr, "DEBUG BUILD\n");
	}
#endif

	/* Defaults */
	int patch_mode = 0;
	int inspect_mode = 0;
	const char *output_path = NULL;  /* NULL = stdout */
	const char *seed_hex = NULL;
	size_t chunk_size = 4096;
	uint8_t compression = 0;  /* 0=best, 1=lzma2, 2=bzip2, 3=lz4, 4=zstd, 255=none */
	size_t truncate_bytes = 64;
	int hexlike = 0;
	int no_progress = 0;
	difz_path_rule rules[4096];
	size_t rule_count = 0;
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
		if (strcmp(argv[i], "--inspect") == 0) {
			inspect_mode = 1;
			continue;
		}
		if (strcmp(argv[i], "--truncate") == 0) {
			if (i + 1 >= argc) {
				fprintf(stderr, "difz: --truncate requires a numeric argument\n");
				return 1;
			}
			char *endptr;
			long val = strtol(argv[++i], &endptr, 10);
			if (*endptr != '\0' || val < 0) {
				fprintf(stderr, "difz: invalid truncate value: '%s'\n", argv[i]);
				return 1;
			}
			truncate_bytes = (size_t)val;
			continue;
		}
		if (strcmp(argv[i], "--hexlike") == 0) {
			hexlike = 1;
			continue;
		}
		if (strcmp(argv[i], "-o") == 0) {
			if (i + 1 >= argc) {
				fprintf(stderr, "difz: -o requires an argument\n");
				return 1;
			}
			output_path = argv[++i];
			continue;
		}
		if (strcmp(argv[i], "--seed") == 0) {
			if (i + 1 >= argc) {
				fprintf(stderr, "difz: --seed requires a 64-character hex argument\n");
				return 1;
			}
			seed_hex = argv[++i];
			continue;
		}
		if (strcmp(argv[i], "--chunk-size") == 0) {
			if (i + 1 >= argc) {
				fprintf(stderr, "difz: --chunk-size requires a numeric argument\n");
				return 1;
			}
			char *endptr;
			long val = strtol(argv[++i], &endptr, 10);
			if (*endptr != '\0' || val <= 0) {
				fprintf(stderr, "difz: invalid chunk-size: '%s'\n", argv[i]);
				return 1;
			}
			chunk_size = (size_t)val;
			continue;
		}
		if (strcmp(argv[i], "--compress") == 0) {
			if (i + 1 >= argc) {
				fprintf(stderr, "difz: --compress requires an argument (best, lzma2, bzip2, lz4, zstd, none)\n");
				return 1;
			}
			const char *algo = argv[++i];
			if (strcmp(algo, "best") == 0) compression = 0;
			else if (strcmp(algo, "lzma2") == 0) compression = 1;
			else if (strcmp(algo, "bzip2") == 0) compression = 2;
			else if (strcmp(algo, "lz4") == 0) compression = 3;
			else if (strcmp(algo, "zstd") == 0) compression = 4;
			else if (strcmp(algo, "none") == 0) compression = 255;
			else {
				fprintf(stderr, "difz: unknown compression algorithm '%s' (use best, lzma2, bzip2, lz4, zstd, none)\n", algo);
				return 1;
			}
			continue;
		}
		if (strcmp(argv[i], "--allow") == 0 || strcmp(argv[i], "--deny") == 0) {
			if (i + 1 >= argc) {
				fprintf(stderr, "difz: %s requires a glob argument\n", argv[i]);
				return 1;
			}
			if (rule_count == sizeof(rules) / sizeof(rules[0])) {
				fprintf(stderr, "difz: too many path rules (maximum 4096)\n");
				return 1;
			}
			rules[rule_count].action = (strcmp(argv[i], "--allow") == 0) ? 1 : 2;
			rules[rule_count].pattern = argv[++i];
			rule_count++;
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

		/* Unknown option (single-dash or double-dash, but not bare "-") */
		if (argv[i][0] == '-' && argv[i][1] != '\0') {
			fprintf(stderr, "difz: unknown option '%s'\n", argv[i]);
			return 1;
		}

		/* Positional argument */
		if (pos_count < 2) {
			positional[pos_count++] = argv[i];
		} else {
			fprintf(stderr, "difz: too many arguments\n");
			return 1;
		}
	}

	/* Validate mode flags — mutually exclusive */
	if (patch_mode && inspect_mode) {
		fprintf(stderr, "difz: --patch and --inspect are mutually exclusive\n");
		return 1;
	}

	/* Validate positional args */
	if (inspect_mode) {
		if (pos_count < 1) {
			fprintf(stderr, "difz: --inspect requires a diff file argument\n");
			fprintf(stderr, "Try 'difz --help' for usage.\n");
			return 1;
		}
		if (pos_count > 1) {
			fprintf(stderr, "difz: --inspect takes exactly one file argument\n");
			return 1;
		}
	} else {
		if (pos_count < 2) {
			fprintf(stderr, "difz: expected 2 file arguments, got %d\n", pos_count);
			fprintf(stderr, "Try 'difz --help' for usage.\n");
			return 1;
		}
	}

	/* Parse seed if provided */
	uint8_t seed_buf[32];
	uint8_t *seed_ptr = NULL;
	if (seed_hex) {
		if (parse_hex_seed(seed_hex, seed_buf) != 0) {
			fprintf(stderr, "difz: invalid seed: must be exactly 64 hex characters\n");
			return 1;
		}
		seed_ptr = seed_buf;
	}

	int exit_code = 0;

	if (!inspect_mode) {
		enum path_kind first_kind = classify_path(positional[0]);
		if (first_kind == PATH_KIND_ERROR) return 1;
		if (patch_mode && first_kind == PATH_KIND_DIRECTORY) {
			if (rule_count != 0) {
				fprintf(stderr, "difz: --allow and --deny are stored when a directory patch is created\n");
				return 1;
			}
			if (is_stdout_path(output_path) || strcmp(output_path, "@stderr") == 0) {
				fprintf(stderr, "difz: directory patch requires -o with a new directory path\n");
				return 1;
			}
			enum path_kind patch_kind = classify_path(positional[1]);
			if (patch_kind != PATH_KIND_FILE && patch_kind != PATH_KIND_STREAM) {
				fprintf(stderr, "difz: a directory source requires a regular DIFZTREE patch file\n");
				return 1;
			}
			return run_directory_patch(positional[0], positional[1], output_path);
		}
		if (!patch_mode) {
			enum path_kind second_kind = classify_path(positional[1]);
			if (second_kind == PATH_KIND_ERROR) return 1;
			if (first_kind == PATH_KIND_DIRECTORY || second_kind == PATH_KIND_DIRECTORY) {
				if (first_kind != PATH_KIND_DIRECTORY || second_kind != PATH_KIND_DIRECTORY) {
					fprintf(stderr, "difz: inputs must both be files or both be directories\n");
					return 1;
				}
				return run_directory_diff(
					positional[0], positional[1], output_path,
					rules, rule_count, seed_ptr, chunk_size, compression);
			}
			if (first_kind == PATH_KIND_SPECIAL || second_kind == PATH_KIND_SPECIAL) {
				fprintf(stderr, "difz: unsupported special input file\n");
				return 1;
			}
		} else if (first_kind == PATH_KIND_SPECIAL) {
			fprintf(stderr, "difz: unsupported special source file\n");
			return 1;
		}
		if (rule_count != 0) {
			fprintf(stderr, "difz: --allow and --deny require directory inputs\n");
			return 1;
		}
	}

	if (inspect_mode) {
		/* ── Inspect mode ───────────────────────────────── */
		size_t diff_file_len = 0;
		uint8_t *diff_data = read_file(positional[0], &diff_file_len);
		if (!diff_data) return 1;

		uint8_t *result_ptr = NULL;
		size_t result_len = 0;

		int rc = difz_inspect(diff_data, diff_file_len,
		                       truncate_bytes, hexlike,
		                       &result_ptr, &result_len);
		if (rc != 0) {
			fprintf(stderr, "difz: inspect failed (invalid diff file?)\n");
			exit_code = 1;
		} else {
			if (write_output(output_path, result_ptr, result_len) != 0) {
				exit_code = 1;
			}
			difz_free(result_ptr, result_len);
		}

		free(diff_data);
	} else {
		/* Read input files */
		size_t a_len = 0, b_len = 0;
		uint8_t *a_data = read_file(positional[0], &a_len);
		if (!a_data) return 1;

		uint8_t *b_data = read_file(positional[1], &b_len);
		if (!b_data) {
			free(a_data);
			return 1;
		}

		if (patch_mode) {
			/* ── Patch mode ──────────────────────────────────── */
			progrez_ctx *pctx = NULL;
			if (!no_progress && isatty(STDERR_FILENO)) {
				pctx = progrez_create("Applying patch");
				if (pctx) {
					progrez_set_identity(pctx, "difz", NULL);
					progrez_set_indeterminate(pctx);
				}
			}

			uint8_t *result_ptr = NULL;
			size_t result_len = 0;

			int rc = difz_patch(a_data, a_len, b_data, b_len, &result_ptr, &result_len);

			if (pctx) { progrez_finish(pctx); progrez_destroy(pctx); }
			if (rc != 0) {
				fprintf(stderr, "difz: patch failed\n");
				exit_code = 1;
			} else {
				if (write_output(output_path, result_ptr, result_len) != 0) {
					exit_code = 1;
				} else if (!no_progress && isatty(STDERR_FILENO)) {
					char size_str[64];
					format_size(result_len, size_str, sizeof(size_str));
					fprintf(stderr, "difz: Done. Reconstructed: %s\n", size_str);
				}
				difz_free(result_ptr, result_len);
			}
		} else {
			/* ── Diff mode ───────────────────────────────────── */
			progrez_ctx *pctx = NULL;
			if (!no_progress && isatty(STDERR_FILENO)) {
				pctx = progrez_create("Computing diff");
				if (pctx) {
					progrez_set_identity(pctx, "difz", NULL);
					progrez_set_indeterminate(pctx);
				}
			}

			uint8_t *diff_ptr = NULL;
			size_t diff_len = 0;

			int rc = difz_diff(a_data, a_len, b_data, b_len, seed_ptr, chunk_size,
			                    compression, &diff_ptr, &diff_len);

			if (pctx) { progrez_finish(pctx); progrez_destroy(pctx); }
			if (rc != 0) {
				fprintf(stderr, "difz: diff failed\n");
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
						fprintf(stderr, "difz: Done. Diff: %s (%.1f%% of original)\n",
							diff_size_str, pct);
					} else {
						fprintf(stderr, "difz: Done. Diff: %s\n", diff_size_str);
					}
				}
				difz_free(diff_ptr, diff_len);
			}
		}

		free(a_data);
		free(b_data);
	}

	return exit_code;
}
