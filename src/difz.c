/* difz CLI — dogfoods the difz C FFI.
 * File patches are zstd level 9 prefix frames. Directory patches are DIFZTREE.
 *
 * Build: linked against libdifz.a via build.zig
 * Usage: difz <file_a> <file_b> [-o output]
 *        difz --patch <file_a> <diff_file> [-o output]
 *        difz --inspect <diff_file>
 */

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <signal.h>
#include <sys/stat.h>
#include <unistd.h>
#if defined(_WIN32) || defined(_WIN64)
#include <fcntl.h>
#include <io.h>
#else
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/time.h>
#endif

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

/* English catalog entries; other locales use the prepare-phase fallback. */
static const struct {
	const char *omit_help;
	const char *omit_missing;
	const char *omit_invalid;
	const char *omit_create_only;
	const char *omit_directories_only;
	const char *raw_xattrs_preserved;
	const char *symlink_metadata_preserved;
	const char *birth_time_preserved;
	const char *modification_time_preserved;
	const char *native_acl_preserved;
	const char *portable_acl_preserved;
	const char *finder_flags_preserved;
	const char *finder_info_preserved;
	const char *sparse_preserved;
} metadata_messages = {
	"  --omit-metadata <list>  Omit xattr,acl,timestamps,finder,sparse,hardlink\n",
	"difz: --omit-metadata requires a nonempty comma-separated list\n",
	"difz: --omit-metadata contains an unknown, empty, or duplicate family\n",
	"difz: --omit-metadata is stored when a directory patch is created\n",
	"difz: --omit-metadata requires directory inputs\n",
	"difz: warning: raw attributes were preserved in difz.raw-xattrs\n",
	"difz: warning: symlink metadata was preserved in difz.symlinks on the parent directory\n",
	"difz: warning: birth-time metadata was preserved in difz.btime\n",
	"difz: warning: modification-time metadata was preserved in difz.mtime\n",
	"difz: warning: native ACL metadata was preserved in difz.native-acl\n",
	"difz: warning: portable ACL metadata was preserved in difz.portable-acl\n",
	"difz: warning: BSD flags were preserved in difz.bsd-flags\n",
	"difz: warning: Finder information was preserved in difz.finder-info\n",
	"difz: warning: sparse layout was preserved in difz.sparse-holes\n"
};

static void print_usage(FILE *out) {
	fprintf(out,
		"Usage: difz [options] <file_or_dir_a> <file_or_dir_b>\n"
		"       difz --patch [options] <file_or_dir_a> <diff_file>\n"
		"       difz --inspect [options] <diff_file>\n"
		"\n"
		"Modes:\n"
		"  (default)     Compute a binary diff between file_a and file_b\n"
		"  --patch       Apply a diff to file_a to reconstruct file_b\n"
		"  --inspect     Describe sizes, hashes, and the zstd frame\n"
		"\n"
		"Options:\n"
		"  -h, --help         Show this help message\n"
		"  --about            Show version, platform, architecture\n"
		"  -o <file>          Output file (default: stdout)\n"
		"  --allow <glob>      Include matching directory paths (repeatable, ordered)\n"
		"  --deny <glob>       Exclude matching directory paths (repeatable, ordered)\n"
		"%s"
		"  --no-progress      Suppress progress/stats output\n"
		"  --no-ansi, --no-color  Suppress ANSI escape codes\n"
		"  --simple           Suppress both ANSI and emoji\n"
		"  --lang <code>      UI language (DIFZ_LANG, then LANG; --lang wins)\n"
		"  --hilfe            German --help alias; infers --lang de\n"
		"  --max-output-bytes <n>  Fail if patch or reconstruction exceeds n bytes\n"
		"  --max-output-ratio <p>  Fail if patch exceeds p percent of the target\n"
		"  --max-rss-bytes <n>     POSIX RLIMIT_AS ceiling for this process\n"
		"  --max-wall-ms <n>       Abort the process after n milliseconds\n"
		"\n"
		"Special paths:\n"
		"  -  or @stdin   Read from stdin\n"
		"  -  or @stdout  Write to stdout\n"
		"  @stderr        Write to stderr\n",
		metadata_messages.omit_help
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
	fprintf(stdout, "difz %s -- fast binary differ (zstd level 9 patch-from) -- %s %s\n",
		DIFZ_VERSION, DIFZ_PLATFORM, DIFZ_ARCH);
}

static int parse_positive_size(const char *s, size_t *out) {
	char *endptr = NULL;
	errno = 0;
	unsigned long long val = strtoull(s, &endptr, 10);
	if (errno != 0 || endptr == s || *endptr != '\0' || val == 0) return -1;
	if (val > (unsigned long long)SIZE_MAX) return -1;
	*out = (size_t)val;
	return 0;
}

static const char *const DIFZ_LOCALES[] = {
	"am","ar","az","bg","bn","bs","da","de","el","en","es","fa","fi","fil","fr",
	"ha","he","hi","hr","hu","id","ig","is","it","ja","km","ko","mk","nb","nl",
	"pa","pl","ps","pt_br","ro","ru","sl","sq","sr","sv","sw","ta","th","tr",
	"uk","ur","vi","yo","zh_hans","zh_hant"
};

static int locale_is_known(const char *code) {
	size_t i;
	for (i = 0; i < sizeof(DIFZ_LOCALES) / sizeof(DIFZ_LOCALES[0]); i++) {
		if (strcmp(DIFZ_LOCALES[i], code) == 0) return 1;
	}
	return 0;
}

static const char *resolve_locale(int argc, char **argv) {
	int i;
	const char *from_env;
	for (i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--hilfe") == 0) return "de";
		if (strcmp(argv[i], "--lang") == 0) {
			if (i + 1 < argc) return argv[i + 1];
			return "en";
		}
	}
	from_env = getenv("DIFZ_LANG");
	if (from_env && from_env[0] != '\0') return from_env;
	return "en";
}

static void warn_missing_locale(const char *code) {
	if (!code || strcmp(code, "en") == 0) return;
	(void)locale_is_known(code);
	fprintf(stderr, "WARN: i18n missing-locale %s\n", code);
}

struct loaded_buf {
	uint8_t *data;
	size_t len;
	int mapped;
};

static void release_loaded(struct loaded_buf *buf) {
	if (!buf || !buf->data) return;
#if !defined(_WIN32) && !defined(_WIN64)
	if (buf->mapped) {
		if (buf->len > 0) munmap(buf->data, buf->len);
		buf->data = NULL;
		buf->mapped = 0;
		buf->len = 0;
		return;
	}
#endif
	free(buf->data);
	buf->data = NULL;
	buf->mapped = 0;
	buf->len = 0;
}

static uint8_t *read_stream(FILE *f, const char *path, size_t *out_len) {
	size_t cap = 4096;
	size_t len = 0;
	uint8_t *buf = malloc(cap);
	if (!buf) {
		fprintf(stderr, "difz: out of memory\n");
		return NULL;
	}
	while (1) {
		if (len == cap) {
			cap *= 2;
			uint8_t *new_buf = realloc(buf, cap);
			if (!new_buf) {
				fprintf(stderr, "difz: out of memory\n");
				free(buf);
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
		return NULL;
	}
	*out_len = len;
	return buf;
}

/* Read a file: mmap regular files on POSIX, malloc for stdin/streams. */
static int load_path(const char *path, struct loaded_buf *out) {
	memset(out, 0, sizeof(*out));
	if (strcmp(path, "-") == 0 || strcmp(path, "@stdin") == 0) {
		out->data = read_stream(stdin, path, &out->len);
		return out->data ? 0 : -1;
	}

#if !defined(_WIN32) && !defined(_WIN64)
	{
		int fd = open(path, O_RDONLY);
		struct stat st;
		if (fd < 0) {
			fprintf(stderr, "difz: cannot open '%s': %s\n", path, strerror(errno));
			return -1;
		}
		if (fstat(fd, &st) != 0) {
			fprintf(stderr, "difz: cannot stat '%s': %s\n", path, strerror(errno));
			close(fd);
			return -1;
		}
		if (!S_ISREG(st.st_mode)) {
			close(fd);
			fprintf(stderr, "difz: unsupported special input file\n");
			return -1;
		}
		out->len = (size_t)st.st_size;
		if (out->len == 0) {
			out->data = malloc(1);
			if (!out->data) {
				fprintf(stderr, "difz: out of memory\n");
				close(fd);
				return -1;
			}
			close(fd);
			return 0;
		}
		void *map = mmap(NULL, out->len, PROT_READ, MAP_PRIVATE, fd, 0);
		close(fd);
		if (map != MAP_FAILED) {
			out->data = map;
			out->mapped = 1;
			return 0;
		}
		/* mmap failed; fall through to stdio. */
	}
#endif

	{
		FILE *f = fopen(path, "rb");
		if (!f) {
			fprintf(stderr, "difz: cannot open '%s': %s\n", path, strerror(errno));
			return -1;
		}
		out->data = read_stream(f, path, &out->len);
		fclose(f);
		return out->data ? 0 : -1;
	}
}

#if !defined(_WIN32) && !defined(_WIN64)
static volatile sig_atomic_t difz_timed_out = 0;
static void difz_on_alarm(int sig) {
	(void)sig;
	difz_timed_out = 1;
	_exit(124);
}

static int apply_rss_ceiling(size_t max_rss_bytes) {
	struct rlimit rl;
	if (max_rss_bytes == 0) return 0;
	rl.rlim_cur = (rlim_t)max_rss_bytes;
	rl.rlim_max = (rlim_t)max_rss_bytes;
	if (setrlimit(RLIMIT_AS, &rl) != 0) {
		fprintf(stderr, "difz: cannot apply RSS ceiling (%s)\n", strerror(errno));
		return -1;
	}
	return 0;
}

static int apply_wall_ceiling(size_t max_wall_ms) {
	struct itimerval tv;
	if (max_wall_ms == 0) return 0;
	if (signal(SIGALRM, difz_on_alarm) == SIG_ERR) {
		fprintf(stderr, "difz: cannot install wall-clock handler: %s\n", strerror(errno));
		return -1;
	}
	memset(&tv, 0, sizeof(tv));
	tv.it_value.tv_sec = (time_t)(max_wall_ms / 1000);
	tv.it_value.tv_usec = (suseconds_t)((max_wall_ms % 1000) * 1000);
	if (tv.it_value.tv_sec == 0 && tv.it_value.tv_usec == 0) {
		tv.it_value.tv_usec = 1000;
	}
	if (setitimer(ITIMER_REAL, &tv, NULL) != 0) {
		fprintf(stderr, "difz: cannot apply wall-clock ceiling: %s\n", strerror(errno));
		return -1;
	}
	return 0;
}
#else
static int apply_rss_ceiling(size_t max_rss_bytes) {
	if (max_rss_bytes == 0) return 0;
	fprintf(stderr, "difz: --max-rss-bytes requires POSIX RLIMIT_AS\n");
	return -1;
}
static int apply_wall_ceiling(size_t max_wall_ms) {
	if (max_wall_ms == 0) return 0;
	fprintf(stderr, "difz: --max-wall-ms requires POSIX interval timers\n");
	return -1;
}
#endif

static void cli_progress(const char *stage, uint64_t done, uint64_t total, void *user) {
	progrez_ctx *pctx = (progrez_ctx *)user;
	if (!pctx) return;
	if (stage && stage[0]) progrez_set_label(pctx, stage);
	if (total > 0) {
		progrez_set_determinate(pctx, total, 0);
		progrez_update(pctx, done, 0);
	}
}

static uint8_t *read_file(const char *path, size_t *out_len) {
	struct loaded_buf loaded;
	size_t n;
	if (load_path(path, &loaded) != 0) return NULL;
	n = loaded.len;
	if (loaded.mapped) {
		uint8_t *copy = malloc(n ? n : 1);
		if (!copy) {
			fprintf(stderr, "difz: out of memory\n");
			release_loaded(&loaded);
			return NULL;
		}
		if (n) memcpy(copy, loaded.data, n);
		release_loaded(&loaded);
		*out_len = n;
		return copy;
	}
	*out_len = n;
	return loaded.data;
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

	if (needs_close) {
		if (fclose(f) != 0) {
			fprintf(stderr, "difz: write error: %s\n", strerror(errno));
			return -1;
		}
	} else if (fflush(f) != 0 || ferror(f)) {
		fprintf(stderr, "difz: write error: %s\n", strerror(errno));
		return -1;
	}
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

static int is_stream_path(const char *path) {
	return is_stdout_path(path) || (path != NULL && strcmp(path, "@stderr") == 0);
}

static int run_directory_diff(
	const char *source_path,
	const char *target_path,
	const char *output_path,
	const difz_path_rule *rules,
	size_t rule_count,
	uint32_t omit_metadata
) {
	uint8_t *patch = NULL;
	size_t patch_len = 0;
	int rc = difz_directory_diff(
		source_path, target_path, rules, rule_count, omit_metadata, &patch, &patch_len);
	if (rc != 0) {
		fprintf(stderr, "difz: directory diff failed\n");
		return 1;
	}
	if (is_stream_path(output_path)) {
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
	uint32_t compromises = 0;
	int rc = difz_directory_patch(source_path, patch, patch_len, output_path, &compromises);
	free(patch);
	if (rc == -2) fprintf(stderr, "difz: directory patch source identity does not match\n");
	else if (rc == -3) fprintf(stderr, "difz: output already exists: '%s'\n", output_path);
	else if (rc != 0) fprintf(stderr, "difz: directory patch failed\n");
	if (rc == 0) {
		if (compromises & DIFZ_COMPROMISE_RAW_XATTR) fputs(metadata_messages.raw_xattrs_preserved, stderr);
		if (compromises & DIFZ_COMPROMISE_SYMLINK) fputs(metadata_messages.symlink_metadata_preserved, stderr);
		if (compromises & DIFZ_COMPROMISE_BIRTH_TIME) fputs(metadata_messages.birth_time_preserved, stderr);
		if (compromises & DIFZ_COMPROMISE_MTIME) fputs(metadata_messages.modification_time_preserved, stderr);
		if (compromises & DIFZ_COMPROMISE_NATIVE_ACL) fputs(metadata_messages.native_acl_preserved, stderr);
		if (compromises & DIFZ_COMPROMISE_PORTABLE_ACL) fputs(metadata_messages.portable_acl_preserved, stderr);
		if (compromises & DIFZ_COMPROMISE_FINDER_FLAGS) fputs(metadata_messages.finder_flags_preserved, stderr);
		if (compromises & DIFZ_COMPROMISE_FINDER_INFO) fputs(metadata_messages.finder_info_preserved, stderr);
		if (compromises & DIFZ_COMPROMISE_SPARSE) fputs(metadata_messages.sparse_preserved, stderr);
	}
	return rc == 0 ? 0 : 1;
}

/* ── Main ──────────────────────────────────────────────────────────── */

static void difz_stdio_init(void) {
#if defined(_WIN32) || defined(_WIN64)
	_setmode(_fileno(stdin), _O_BINARY);
	_setmode(_fileno(stdout), _O_BINARY);
	_setmode(_fileno(stderr), _O_BINARY);
#endif
}

int main(int argc, char *argv[]) {
	difz_stdio_init();
	int no_ansi = 0;
	int no_progress = 0;
	const char *locale = resolve_locale(argc, argv);
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--simple") == 0) {
			no_ansi = 1;
			no_progress = 1;
		} else if (strcmp(argv[i], "--no-ansi") == 0 || strcmp(argv[i], "--no-color") == 0) {
			no_ansi = 1;
		} else if (strcmp(argv[i], "--no-progress") == 0) {
			no_progress = 1;
		}
	}
	warn_missing_locale(locale);

#ifdef DIFZ_DEBUG
	if (isatty(STDERR_FILENO) && !no_ansi) {
		fprintf(stderr, "\033[33mDEBUG BUILD\033[0m\n");
	} else {
		fprintf(stderr, "DEBUG BUILD\n");
	}
#endif

	/* Defaults */
	int patch_mode = 0;
	int inspect_mode = 0;
	const char *output_path = NULL;  /* NULL = stdout */
	size_t max_output_bytes = 0;
	size_t max_output_ratio = 0;
	size_t max_rss_bytes = 0;
	size_t max_wall_ms = 0;
	difz_path_rule rules[4096];
	size_t rule_count = 0;
	uint32_t omit_metadata = 0;
	int omit_seen = 0;

	/* Positional args collector */
	const char *positional[2] = {NULL, NULL};
	int pos_count = 0;

	/* Parse arguments — later args override earlier ones */
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0 ||
			strcmp(argv[i], "--hilfe") == 0) {
			print_usage(stdout);
			return 0;
		}
		if (strcmp(argv[i], "--about") == 0) {
			print_about();
			return 0;
		}
		if (strcmp(argv[i], "--lang") == 0) {
			if (i + 1 >= argc) {
				fprintf(stderr, "difz: --lang requires a locale code argument\n");
				return 1;
			}
			i++;
			continue;
		}
		if (strcmp(argv[i], "--patch") == 0) {
			patch_mode = 1;
			continue;
		}
		if (strcmp(argv[i], "--inspect") == 0) {
			inspect_mode = 1;
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
		if (strcmp(argv[i], "--omit-metadata") == 0) {
			if (i + 1 >= argc || argv[i + 1][0] == '\0') {
				fputs(metadata_messages.omit_missing, stderr);
				return 1;
			}
			uint32_t parsed = 0;
			if (difz_parse_metadata_omit(argv[++i], &parsed) != 0 || parsed == 0 ||
				(parsed & omit_metadata) != 0) {
				fputs(metadata_messages.omit_invalid, stderr);
				return 1;
			}
			omit_metadata |= parsed;
			omit_seen = 1;
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
			no_ansi = 1;
			continue;
		}
		if (strcmp(argv[i], "--simple") == 0) {
			no_ansi = 1;
			no_progress = 1;
			continue;
		}
		if (strcmp(argv[i], "--max-output-bytes") == 0) {
			if (i + 1 >= argc || parse_positive_size(argv[++i], &max_output_bytes) != 0) {
				fprintf(stderr, "difz: --max-output-bytes requires a positive integer\n");
				return 1;
			}
			continue;
		}
		if (strcmp(argv[i], "--max-output-ratio") == 0) {
			if (i + 1 >= argc || parse_positive_size(argv[++i], &max_output_ratio) != 0 ||
				max_output_ratio > 100) {
				fprintf(stderr, "difz: --max-output-ratio requires an integer 1-100\n");
				return 1;
			}
			continue;
		}
		if (strcmp(argv[i], "--max-rss-bytes") == 0) {
			if (i + 1 >= argc || parse_positive_size(argv[++i], &max_rss_bytes) != 0) {
				fprintf(stderr, "difz: --max-rss-bytes requires a positive integer\n");
				return 1;
			}
			continue;
		}
		if (strcmp(argv[i], "--max-wall-ms") == 0) {
			if (i + 1 >= argc || parse_positive_size(argv[++i], &max_wall_ms) != 0) {
				fprintf(stderr, "difz: --max-wall-ms requires a positive integer\n");
				return 1;
			}
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
	if (omit_seen && (patch_mode || inspect_mode)) {
		fputs(metadata_messages.omit_create_only, stderr);
		return 1;
	}
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

	if (apply_rss_ceiling(max_rss_bytes) != 0) return 1;
	if (apply_wall_ceiling(max_wall_ms) != 0) return 1;

	int exit_code = 0;

	if (!inspect_mode) {
		enum path_kind first_kind = classify_path(positional[0]);
		if (first_kind == PATH_KIND_ERROR) return 1;
		if (patch_mode && first_kind == PATH_KIND_DIRECTORY) {
			if (rule_count != 0) {
				fprintf(stderr, "difz: --allow and --deny are stored when a directory patch is created\n");
				return 1;
			}
			if (is_stream_path(output_path)) {
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
					rules, rule_count, omit_metadata);
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
		if (omit_seen) {
			fputs(metadata_messages.omit_directories_only, stderr);
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

		int rc = difz_inspect(diff_data, diff_file_len, &result_ptr, &result_len);
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
		/* Read input files (mmap regular files; malloc stdin). */
		struct loaded_buf a_buf, b_buf;
		if (load_path(positional[0], &a_buf) != 0) return 1;
		if (load_path(positional[1], &b_buf) != 0) {
			release_loaded(&a_buf);
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
					difz_set_progress_callback(cli_progress, pctx);
				}
			}

			uint8_t *result_ptr = NULL;
			size_t result_len = 0;

			int rc = difz_patch_limited(
				a_buf.data, a_buf.len, b_buf.data, b_buf.len,
				max_output_bytes, &result_ptr, &result_len);

			difz_set_progress_callback(NULL, NULL);
			if (pctx) { progrez_finish(pctx); progrez_destroy(pctx); }
			if (rc == -4) {
				fprintf(stderr, "difz: resource limit exceeded\n");
				exit_code = 1;
			} else if (rc != 0) {
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
			size_t create_limit = max_output_bytes;
			if (max_output_ratio != 0 && b_buf.len > 0) {
				size_t ratio_cap = (size_t)((unsigned long long)b_buf.len * max_output_ratio / 100ull);
				if (ratio_cap == 0) ratio_cap = 1;
				if (create_limit == 0 || ratio_cap < create_limit) create_limit = ratio_cap;
			}

			progrez_ctx *pctx = NULL;
			if (!no_progress && isatty(STDERR_FILENO)) {
				pctx = progrez_create("Computing diff");
				if (pctx) {
					progrez_set_identity(pctx, "difz", NULL);
					progrez_set_indeterminate(pctx);
					difz_set_progress_callback(cli_progress, pctx);
				}
			}

			uint8_t *diff_ptr = NULL;
			size_t diff_len = 0;

			int rc = difz_diff_limited(
				a_buf.data, a_buf.len, b_buf.data, b_buf.len,
				create_limit, &diff_ptr, &diff_len);

			difz_set_progress_callback(NULL, NULL);
			if (pctx) { progrez_finish(pctx); progrez_destroy(pctx); }
			if (rc == -4) {
				fprintf(stderr, "difz: resource limit exceeded\n");
				exit_code = 1;
			} else if (rc != 0) {
				fprintf(stderr, "difz: diff failed\n");
				exit_code = 1;
			} else {
				if (write_output(output_path, diff_ptr, diff_len) != 0) {
					exit_code = 1;
				} else if (!no_progress && isatty(STDERR_FILENO)) {
					size_t original = (a_buf.len > b_buf.len) ? a_buf.len : b_buf.len;
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

		release_loaded(&a_buf);
		release_loaded(&b_buf);
	}

	return exit_code;
}
