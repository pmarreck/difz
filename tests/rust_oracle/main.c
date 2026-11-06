#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>

extern size_t difz_metadata_oracle(uint32_t mode, const unsigned char *input,
    size_t input_len, unsigned char *output, size_t output_capacity,
    unsigned char *error, size_t error_capacity, size_t *error_len);

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    char *end = NULL;
    errno = 0;
    unsigned long mode = strtoul(argv[1], &end, 10);
    if (errno || !end || end == argv[1] || *end || mode > UINT32_MAX) return 2;
    const size_t capacity = 1u << 20;
    unsigned char *input = malloc(capacity), *output = malloc(capacity);
    unsigned char error[128];
    if (!input || !output) { free(input); free(output); return 3; }
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
