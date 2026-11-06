/* Independent SDK diagnostics. No compression or product implementation. */
#define ZSTD_STATIC_LINKING_ONLY
#include <zstd.h>
#include <stdio.h>

int main(void) {
	puts("[");
	for (size_t n = 1 << 18; n <= (1 << 24); n *= 2) {
		ZSTD_compressionParameters p = ZSTD_getCParams(9, n, n);
		unsigned raw = 0;
		for (size_t m = n; m; m >>= 1) ++raw;
		unsigned cycle = p.chainLog - (p.strategy >= ZSTD_btlazy2);
		printf("%s{\"size\":%zu,\"chain\":%u,\"hash\":%u,\"search\":%u,\"min_match\":%u,\"target\":%u,\"strategy\":%u,\"ldm\":%u}",
			n == (1 << 18) ? "" : ",", n, p.chainLog, p.hashLog, p.searchLog, p.minMatch, p.targetLength, p.strategy, raw > cycle);
	}
	puts("]");
	return 0;
}
