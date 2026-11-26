#include "difz-rust.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef __linux__
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#elif defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

static const uint8_t source[] = {0, 255, 'o', 'l', 'd', 0};
static const uint8_t target[] = {0, 128, 'n', 'e', 'w', 0, 255};
_Static_assert(offsetof(difz_file_info, source_len) == 64, "source length ABI offset");
_Static_assert(offsetof(difz_file_info, target_len) == 72, "target length ABI offset");
_Static_assert(offsetof(difz_file_info, frame_len) == 80, "frame length ABI offset");
static uint64_t read_u64(const uint8_t *bytes) {
    uint64_t result = 0;
    for (unsigned i = 0; i < 8; ++i) result |= (uint64_t)bytes[i] << (8 * i);
    return result;
}
static void inspect(const uint8_t *patch, size_t len) {
    assert(len >= 85);
    difz_file_info info;
    assert(difz_file_inspect(patch, len, &info) == DIFZ_OK);
    assert(memcmp(info.source_hash, patch + 5, 32) == 0);
    assert(memcmp(info.target_hash, patch + 37, 32) == 0);
    assert(info.source_len == read_u64(patch + 69));
    assert(info.target_len == read_u64(patch + 77));
    assert(info.frame_len == len - 85);
    difz_file_info sentinel;
    memset(&sentinel, 0xA5, sizeof sentinel);
    for (size_t n = 0; n < 85; ++n) {
        info = sentinel;
        assert(difz_file_inspect(patch, n, &info) == DIFZ_INVALID_DATA);
        assert(memcmp(&info, &sentinel, sizeof info) == 0);
    }
    assert(difz_file_inspect(patch, len, NULL) == DIFZ_ARGUMENT);
    info = sentinel;
    assert(difz_file_inspect(NULL, 1, &info) == DIFZ_ARGUMENT);
    assert(memcmp(&info, &sentinel, sizeof info) == 0);
    uint8_t bad[85] = {0};
    assert(difz_file_inspect(bad, sizeof bad, &info) == DIFZ_INVALID_DATA);
    assert(memcmp(&info, &sentinel, sizeof info) == 0);
}
static void save(const char *root, const char *name, const uint8_t *bytes, size_t len) {
    char path[4096];
    int count = snprintf(path, sizeof path, "%s/%s", root, name);
    assert(count > 0 && (size_t)count < sizeof path);
    FILE *file = fopen(path, "wb"); assert(file);
    assert(fwrite(bytes, 1, len, file) == len); assert(fclose(file) == 0);
}
static void verify(const uint8_t *patch, size_t len) {
    inspect(patch, len);
    difz_buffer *result = NULL;
    assert(difz_file_apply(source, sizeof source, patch, len, 0, &result) == DIFZ_OK);
    assert(difz_buffer_len(result) == sizeof target);
    assert(memcmp(difz_buffer_data(result), target, sizeof target) == 0);
    difz_buffer_free(result);
}
#if defined(__linux__) || defined(_WIN32)
static void joined(char *path, size_t capacity, const char *root, const char *name) {
    int count = snprintf(path, capacity, "%s/%s", root, name);
    assert(count > 0 && (size_t)count < capacity);
}
#endif
#ifdef __linux__
static void verify_tree(const char *root, const char *name, int selected) {
    char tree[4096], path[4096]; joined(tree, sizeof tree, root, name);
    joined(path, sizeof path, tree, "data");
    FILE *file = fopen(path, "rb"); assert(file);
    uint8_t bytes[32]; size_t count = fread(bytes, 1, sizeof bytes, file);
    assert(count == sizeof target && memcmp(bytes, target, sizeof target) == 0);
    assert(feof(file) && !ferror(file) && fclose(file) == 0);
    joined(path, sizeof path, tree, "new");
    if (selected) { assert(access(path, F_OK) == -1 && errno == ENOENT); }
    else { file = fopen(path, "rb"); assert(file); assert(fgetc(file) == 42 && fgetc(file) == EOF); assert(fclose(file) == 0); }
}
static void apply_tree(const char *root, const uint8_t *patch, size_t length, const char *name) {
    char source_path[4096]; joined(source_path, sizeof source_path, root, "tree-source");
    uint32_t report = UINT32_MAX;
    assert(difz_directory_apply((const uint8_t *)source_path, strlen(source_path), patch, length,
        (const uint8_t *)root, strlen(root), (const uint8_t *)name, strlen(name), 0, 0, &report) == DIFZ_OK);
    assert(report == 0);
}
static void directory_cases(const char *root) {
	assert(difz_new_file_publish((const uint8_t *)root, strlen(root), (const uint8_t *)"new-file", 8, target, sizeof target) == DIFZ_OK);
	assert(difz_new_file_publish((const uint8_t *)root, strlen(root), (const uint8_t *)"new-file", 8, source, sizeof source) == DIFZ_IO);
	char new_path[4096]; joined(new_path, sizeof new_path, root, "new-file");
	FILE *new_file = fopen(new_path, "rb"); assert(new_file);
	uint8_t retained[32]; size_t retained_len = fread(retained, 1, sizeof retained, new_file);
	assert(retained_len == sizeof target && memcmp(retained, target, sizeof target) == 0);
	assert(feof(new_file) && !ferror(new_file) && fclose(new_file) == 0);
	assert(difz_new_file_publish((const uint8_t *)root, strlen(root), (const uint8_t *)"../escape", 9, target, sizeof target) == DIFZ_ARGUMENT);
	assert(difz_new_file_publish((const uint8_t *)root, strlen(root), (const uint8_t *)"invalid-file", 12, NULL, 1) == DIFZ_ARGUMENT);
    char from[4096], to[4096];
    joined(from, sizeof from, root, "tree-source"); joined(to, sizeof to, root, "tree-target");
    assert(mkdir(from, 0700) == 0 && mkdir(to, 0700) == 0);
    save(from, "data", source, sizeof source); save(to, "data", target, sizeof target);
    const uint8_t extra = 42; save(to, "new", &extra, 1);
    difz_buffer *patch = NULL;
    assert(difz_directory_encode((const uint8_t *)from, strlen(from), (const uint8_t *)to, strlen(to), NULL, 0, 63, 0, 0, &patch) == DIFZ_OK);
    const uint8_t *bytes = difz_buffer_data(patch); size_t length = difz_buffer_len(patch);
    assert(length >= 120 && memcmp(bytes, "DIFZTREE\2\0", 10) == 0);
    save(root, "tree.patch", bytes, length);
    apply_tree(root, bytes, length, "tree-output"); verify_tree(root, "tree-output", 0);
    uint32_t report = UINT32_MAX;
    assert(difz_directory_apply((const uint8_t *)from, strlen(from), bytes, length,
        (const uint8_t *)root, strlen(root), (const uint8_t *)"tree-output", 11, 0, 0, &report) == DIFZ_IO && report == UINT32_MAX);
    assert(difz_directory_apply((const uint8_t *)from, strlen(from), bytes, length,
        (const uint8_t *)root, strlen(root), (const uint8_t *)"too-large", 9, 0, 1, &report) == DIFZ_LIMIT && report == UINT32_MAX);
    assert(difz_directory_apply((const uint8_t *)from, strlen(from), bytes, length,
        (const uint8_t *)from, strlen(from), (const uint8_t *)"inside", 6, 0, 0, &report) == DIFZ_INVALID_DATA && report == UINT32_MAX);
    difz_buffer *sentinel = (difz_buffer *)(uintptr_t)1, *failed = sentinel;
    assert(difz_directory_encode((const uint8_t *)from, strlen(from) + 1, (const uint8_t *)to, strlen(to), NULL, 0, 63, 0, 0, &failed) == DIFZ_ARGUMENT && failed == sentinel);
    assert(difz_directory_encode((const uint8_t *)from, strlen(from), (const uint8_t *)to, strlen(to), NULL, 1, 63, 0, 0, &failed) == DIFZ_ARGUMENT && failed == sentinel);
    assert(difz_directory_encode((const uint8_t *)from, strlen(from), (const uint8_t *)to, strlen(to), NULL, 0, 64, 0, 0, &failed) == DIFZ_ARGUMENT && failed == sentinel);
    assert(difz_directory_encode((const uint8_t *)from, strlen(from), (const uint8_t *)to, strlen(to), NULL, 0, 63, 1, 0, &failed) == DIFZ_LIMIT && failed == sentinel);
    assert(difz_directory_encode((const uint8_t *)from, strlen(from), (const uint8_t *)to, strlen(to), NULL, 0, 63, 0, 1, &failed) == DIFZ_LIMIT && failed == sentinel);
    difz_path_rule rule = {1, (const uint8_t *)"data", 4};
    const uint8_t nul_pattern[] = {'d', 'a', 't', 'a', 0}, invalid_utf8[] = {255};
    difz_path_rule invalid_rules[] = {{3, (const uint8_t *)"data", 4}, {1, nul_pattern, sizeof nul_pattern}, {1, invalid_utf8, sizeof invalid_utf8}, {1, NULL, 0}};
    for (size_t index = 0; index < sizeof invalid_rules / sizeof invalid_rules[0]; ++index) {
        assert(difz_directory_encode((const uint8_t *)from, strlen(from), (const uint8_t *)to, strlen(to), &invalid_rules[index], 1, 63, 0, 0, &failed) == DIFZ_ARGUMENT && failed == sentinel);
    }
    assert(difz_directory_encode((const uint8_t *)from, strlen(from), (const uint8_t *)to, strlen(to), NULL, 4097, 63, 0, 0, &failed) == DIFZ_LIMIT && failed == sentinel);
    assert(difz_directory_encode(NULL, 1, NULL, 0, NULL, 0, 0, 0, 0, NULL) == DIFZ_ARGUMENT);
    assert(difz_directory_apply(NULL, 1, NULL, 0, NULL, 0, NULL, 0, 0, 0, NULL) == DIFZ_ARGUMENT);
    assert(difz_directory_apply((const uint8_t *)from, strlen(from), NULL, 1, (const uint8_t *)root, strlen(root), (const uint8_t *)"invalid", 7, 0, 0, &report) == DIFZ_ARGUMENT && report == UINT32_MAX);
    difz_buffer *selected = NULL;
    assert(difz_directory_encode((const uint8_t *)from, strlen(from), (const uint8_t *)to, strlen(to), &rule, 1, 63, 0, 0, &selected) == DIFZ_OK);
    apply_tree(root, difz_buffer_data(selected), difz_buffer_len(selected), "selected-tree"); verify_tree(root, "selected-tree", 1);
    difz_buffer_free(selected);
    save(from, "data", target, sizeof target);
    assert(difz_directory_apply((const uint8_t *)from, strlen(from), bytes, length,
        (const uint8_t *)root, strlen(root), (const uint8_t *)"wrong-source", 12, 0, 0, &report) == DIFZ_WRONG_SOURCE && report == UINT32_MAX);
    save(from, "data", source, sizeof source);
    difz_buffer_free(patch);
    puts("PASS packaged Rust filesystem ABI: binary trees, selection, limits, wrong source, source containment and occupied output");
}
#elif defined(_WIN32)
static void directory_cases(const char *root) {
    char from[4096], to[4096];
    joined(from, sizeof from, root, "tree-source");
    joined(to, sizeof to, root, "tree-target");
    WCHAR from_wide[4096], to_wide[4096];
    assert(MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, from, -1, from_wide, 4096) > 0);
    assert(MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, to, -1, to_wide, 4096) > 0);
    assert(CreateDirectoryW(from_wide, NULL) && CreateDirectoryW(to_wide, NULL));
    save(from, "data", source, sizeof source);
    save(to, "data", target, sizeof target);
    difz_buffer *patch = NULL;
    assert(difz_directory_encode((const uint8_t *)from, strlen(from), (const uint8_t *)to, strlen(to), NULL, 0, 63, 0, 0, &patch) == DIFZ_OK);
    assert(difz_buffer_len(patch) > 120);
    assert(memcmp(difz_buffer_data(patch), "DIFZTREE\2\0", 10) == 0);
    save(root, "tree.patch", difz_buffer_data(patch), difz_buffer_len(patch));
    difz_buffer_free(patch);
    difz_buffer *sentinel = (difz_buffer *)(uintptr_t)1, *out = sentinel;
    assert(difz_directory_encode(NULL, 0, NULL, 0, NULL, 0, 0, 0, 0, &out) == DIFZ_ARGUMENT && out == sentinel);
    const uint8_t invalid_path[] = {255};
    assert(difz_directory_encode(invalid_path, sizeof invalid_path, (const uint8_t *)to, strlen(to), NULL, 0, 63, 0, 0, &out) == DIFZ_ARGUMENT && out == sentinel);
    assert(difz_directory_encode((const uint8_t *)from, strlen(from) + 1, (const uint8_t *)to, strlen(to), NULL, 0, 63, 0, 0, &out) == DIFZ_ARGUMENT && out == sentinel);
    assert(difz_directory_encode((const uint8_t *)from, strlen(from), (const uint8_t *)to, strlen(to), NULL, 1, 63, 0, 0, &out) == DIFZ_ARGUMENT && out == sentinel);
    assert(difz_directory_encode((const uint8_t *)from, strlen(from), (const uint8_t *)to, strlen(to), NULL, 0, 64, 0, 0, &out) == DIFZ_ARGUMENT && out == sentinel);
    assert(difz_directory_encode((const uint8_t *)from, strlen(from), (const uint8_t *)to, strlen(to), NULL, 0, 63, 1, 0, &out) == DIFZ_LIMIT && out == sentinel);
    assert(difz_directory_encode((const uint8_t *)from, strlen(from), (const uint8_t *)to, strlen(to), NULL, 0, 63, 0, 1, &out) == DIFZ_LIMIT && out == sentinel);
    assert(difz_directory_encode((const uint8_t *)from, strlen(from), (const uint8_t *)to, strlen(to), NULL, 0, 59, 0, 0, &out) == DIFZ_UNSUPPORTED && out == sentinel);
    assert(difz_directory_encode(NULL, 1, NULL, 0, NULL, 0, 63, 0, 0, NULL) == DIFZ_ARGUMENT);
    assert(difz_directory_encode((const uint8_t *)from, strlen(from), (const uint8_t *)to, strlen(to), NULL, 4097, 63, 0, 0, &out) == DIFZ_LIMIT && out == sentinel);
    uint32_t report = UINT32_MAX;
    assert(difz_new_file_publish(NULL, 0, NULL, 0, NULL, 0) == DIFZ_UNSUPPORTED);
    assert(difz_directory_apply(NULL, 0, NULL, 0, NULL, 0, NULL, 0, 0, 0, &report) == DIFZ_UNSUPPORTED && report == UINT32_MAX);
    puts("PASS packaged Windows metadata-free directory encoder: binary files, ownership, limits, invalid regions and explicit metadata scope");
}
#else
static void directory_cases(const char *root) {
    (void)root;
	assert(difz_new_file_publish(NULL, 0, NULL, 0, NULL, 0) == DIFZ_UNSUPPORTED);
    difz_buffer *sentinel = (difz_buffer *)(uintptr_t)1, *out = sentinel;
    uint32_t report = UINT32_MAX;
    assert(difz_directory_encode(NULL, 0, NULL, 0, NULL, 0, 0, 0, 0, &out) == DIFZ_UNSUPPORTED && out == sentinel);
    assert(difz_directory_apply(NULL, 0, NULL, 0, NULL, 0, NULL, 0, 0, 0, &report) == DIFZ_UNSUPPORTED && report == UINT32_MAX);
}
#endif
int main(int argc, char **argv) {
#ifdef __linux__
    if (argc == 4 && strcmp(argv[1], "--apply-native-tree") == 0) {
        FILE *file = fopen(argv[2], "rb"); assert(file);
        uint8_t patch[8192]; size_t len = fread(patch, 1, sizeof patch, file);
        assert(!ferror(file) && feof(file) && fclose(file) == 0);
        apply_tree(argv[3], patch, len, "rust-applied-native-tree"); verify_tree(argv[3], "rust-applied-native-tree", 0);
        return 0;
    }
#endif
    if (argc == 3 && strcmp(argv[1], "--apply-native") == 0) {
        FILE *file = fopen(argv[2], "rb"); assert(file);
        uint8_t patch[4096]; size_t len = fread(patch, 1, sizeof patch, file);
        assert(!ferror(file) && feof(file)); assert(fclose(file) == 0);
        verify(patch, len); return 0;
    }
    assert(argc == 2);
    difz_buffer *patch = NULL;
    assert(difz_file_encode(source, sizeof source, target, sizeof target, 0, &patch) == DIFZ_OK);
    verify(difz_buffer_data(patch), difz_buffer_len(patch));
    save(argv[1], "source", source, sizeof source);
    save(argv[1], "target", target, sizeof target);
    save(argv[1], "rust.patch", difz_buffer_data(patch), difz_buffer_len(patch));
    difz_buffer *sentinel = (difz_buffer *)(uintptr_t)1;
    difz_buffer *output = sentinel;
    assert(difz_file_apply(source, sizeof source, difz_buffer_data(patch), difz_buffer_len(patch), 1, &output) == DIFZ_LIMIT && output == sentinel);
    assert(difz_file_apply(target, sizeof target, difz_buffer_data(patch), difz_buffer_len(patch), 0, &output) == DIFZ_WRONG_SOURCE && output == sentinel);
    assert(difz_file_encode(NULL, 1, NULL, 0, 0, &output) == DIFZ_ARGUMENT && output == sentinel);
    assert(difz_file_encode(NULL, 0, NULL, 0, 0, NULL) == DIFZ_ARGUMENT);
    assert(difz_file_encode(source, sizeof source, target, sizeof target, 1, &output) == DIFZ_LIMIT && output == sentinel);
    difz_buffer_free(patch);
    patch = NULL; output = NULL;
    assert(difz_file_encode(NULL, 0, NULL, 0, 0, &patch) == DIFZ_OK);
    assert(difz_file_apply(NULL, 0, difz_buffer_data(patch), difz_buffer_len(patch), 0, &output) == DIFZ_OK);
    assert(difz_buffer_len(output) == 0 && difz_buffer_data(output) == NULL);
    difz_buffer_free(output); difz_buffer_free(patch); difz_buffer_free(NULL);
    assert(difz_buffer_len(NULL) == 0 && difz_buffer_data(NULL) == NULL);
    uint32_t omit = 99;
    assert(difz_metadata_omit_parse((const uint8_t *)"acl,sparse", 10, &omit) == DIFZ_OK && omit == 18);
    const uint8_t invalid[] = {'a', 'c', 'l', 0};
    assert(difz_metadata_omit_parse(invalid, sizeof invalid, &omit) == DIFZ_INVALID_DATA && omit == 18);
    assert(difz_metadata_omit_parse(NULL, 0, &omit) == DIFZ_OK && omit == 0);
    directory_cases(argv[1]);
    puts("PASS Rust C boundary: binary/empty ownership, limits, wrong source and byte-length grammar");
    return 0;
}
