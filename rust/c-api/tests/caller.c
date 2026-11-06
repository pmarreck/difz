#include "difz-rust.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const uint8_t source[] = {0, 255, 'o', 'l', 'd', 0};
static const uint8_t target[] = {0, 128, 'n', 'e', 'w', 0, 255};
static void save(const char *root, const char *name, const uint8_t *bytes, size_t len) {
    char path[4096];
    int count = snprintf(path, sizeof path, "%s/%s", root, name);
    assert(count > 0 && (size_t)count < sizeof path);
    FILE *file = fopen(path, "wb"); assert(file);
    assert(fwrite(bytes, 1, len, file) == len); assert(fclose(file) == 0);
}
static void verify(const uint8_t *patch, size_t len) {
    difz_buffer *result = NULL;
    assert(difz_file_apply(source, sizeof source, patch, len, 0, &result) == DIFZ_OK);
    assert(difz_buffer_len(result) == sizeof target);
    assert(memcmp(difz_buffer_data(result), target, sizeof target) == 0);
    difz_buffer_free(result);
}
int main(int argc, char **argv) {
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
    puts("PASS Rust C boundary: binary/empty ownership, limits, wrong source and byte-length grammar");
    return 0;
}
