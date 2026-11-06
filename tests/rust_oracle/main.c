#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <string.h>
#ifdef _WIN32
#include <io.h>
#include <fcntl.h>
#endif

extern size_t difz_metadata_oracle(uint32_t mode, const unsigned char *input,
    size_t input_len, unsigned char *output, size_t output_capacity,
    unsigned char *error, size_t error_capacity, size_t *error_len);

/* Test-only framing: request mode/u32 + length/u32; response status/u8 +
 * length/u32 + bytes. All lengths are little-endian and bounded before reads. */
static uint32_t get_u32(const unsigned char *bytes) {
    uint32_t value = 0;
    for (unsigned i = 0; i < 4; i++) value |= (uint32_t)bytes[i] << (8 * i);
    return value;
}

static void put_u32(unsigned char *bytes, uint32_t value) {
    for (unsigned i = 0; i < 4; i++) bytes[i] = (unsigned char)(value >> (8 * i));
}

static int stream(unsigned char *input, unsigned char *output, size_t capacity) {
    unsigned char header[8], error[128];
    for (;;) {
        size_t count = fread(header, 1, sizeof header, stdin);
        if (count == 0 && feof(stdin) && !ferror(stdin)) return 0;
        if (count != sizeof header) return 2;
        size_t length = get_u32(header + 4);
        if (length > capacity || fread(input, 1, length, stdin) != length) return 2;
        size_t error_len = 0;
        size_t written = difz_metadata_oracle(get_u32(header), input, length,
            output, capacity, error, sizeof error, &error_len);
        unsigned char response[5];
        const unsigned char *bytes = output;
        response[0] = 0;
        if (written == SIZE_MAX) {
            if (error_len > sizeof error) return 2;
            bytes = error;
            written = error_len;
            response[0] = 1;
        }
        if (written > capacity) return 2;
        put_u32(response + 1, (uint32_t)written);
        if (fwrite(response, 1, sizeof response, stdout) != sizeof response ||
            fwrite(bytes, 1, written, stdout) != written || fflush(stdout) != 0) return 2;
    }
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
#ifdef _WIN32
    if (_setmode(_fileno(stdin), _O_BINARY) == -1 ||
        _setmode(_fileno(stdout), _O_BINARY) == -1) return 2;
#endif
    int streaming = strcmp(argv[1], "--stream") == 0;
    char *end = NULL;
    errno = 0;
    unsigned long mode = streaming ? 0 : strtoul(argv[1], &end, 10);
    if (!streaming && (errno || !end || end == argv[1] || *end || mode > UINT32_MAX)) return 2;
    const size_t capacity = 1u << 20;
    unsigned char *input = malloc(capacity), *output = malloc(capacity);
    unsigned char error[128];
    if (!input || !output) { free(input); free(output); return 3; }
    if (streaming) {
        int status = stream(input, output, capacity);
        free(input); free(output);
        return status;
    }
    size_t length = 0;
    while (length < capacity) {
        size_t count = fread(input + length, 1, capacity - length, stdin);
        length += count;
        if (count == 0) break;
    }
    if (ferror(stdin) || (length == capacity && fgetc(stdin) != EOF)) {
        free(input); free(output); return 2;
    }
    size_t error_len = 0;
    size_t written = difz_metadata_oracle((uint32_t)mode, input, length,
        output, capacity, error, sizeof error, &error_len);
    int status = 0;
    if (written == SIZE_MAX) {
        if (fwrite(error, 1, error_len, stderr) != error_len) status = 2;
        else status = 1;
    } else if (written > capacity || fwrite(output, 1, written, stdout) != written) status = 2;
    free(input); free(output);
    return status;
}
