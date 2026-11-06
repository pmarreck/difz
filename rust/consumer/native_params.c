/* Test-only SDK introspection: the private header and archive share one pin. */
#define ZSTD_STATIC_LINKING_ONLY
#include "zstd_compress_internal.h"
#include <stdio.h>
#include <stdlib.h>


static void checked(size_t result) {
	if (ZSTD_isError(result)) { fprintf(stderr, "%s\n", ZSTD_getErrorName(result)); exit(1); }
}
static void row(size_t n) {
	unsigned char *source = malloc(n), *target = malloc(n);
	size_t capacity = ZSTD_compressBound(n);
	void *output = malloc(capacity);
	ZSTD_CCtx *context = ZSTD_createCCtx();
	if (!source || !target || !output || !context) exit(2);
	unsigned state = 41;
	for (size_t i=0; i<n; i++) {
		state=state*1664525u+1013904223u;
		source[i]=(unsigned char)(state>>24);
		target[i]=source[i] ^ (i%4093==0);
	}
	ZSTD_compressionParameters p = ZSTD_getCParams(9,n,n);
	unsigned raw=0;
	for (size_t size=n; size; size>>=1) ++raw;
	unsigned window=raw<10 ? 10 : raw>31 ? 31 : raw;
	unsigned cycle=p.chainLog-(p.strategy>=ZSTD_btlazy2);
	const struct { ZSTD_cParameter key; int value; } settings[] = {
		{ZSTD_c_compressionLevel,9}, {ZSTD_c_nbWorkers,0},
		{ZSTD_c_enableLongDistanceMatching,raw>cycle}, {ZSTD_c_windowLog,(int)window},
		{ZSTD_c_chainLog,(int)p.chainLog}, {ZSTD_c_hashLog,(int)p.hashLog},
		{ZSTD_c_searchLog,(int)p.searchLog}, {ZSTD_c_minMatch,(int)p.minMatch},
		{ZSTD_c_targetLength,(int)p.targetLength}, {ZSTD_c_strategy,(int)p.strategy},
	};
	for (size_t i=0; i<sizeof settings/sizeof settings[0]; i++) checked(ZSTD_CCtx_setParameter(context,settings[i].key,settings[i].value));
	checked(ZSTD_CCtx_refPrefix(context,source,n));
	checked(ZSTD_compress2(context,output,capacity,target,n));
	const ZSTD_compressionParameters *applied=&context->appliedParams.cParams;
	const ldmParams_t *ldm=&context->appliedParams.ldmParams;
	printf("%s{\"size\":%zu,\"window\":%u,\"chain\":%u,\"hash\":%u,\"search\":%u,\"min_match\":%u,\"target\":%u,\"strategy\":%u,\"ldm\":%u,\"ldm_window\":%u,\"ldm_hash\":%u,\"ldm_rate\":%u,\"ldm_bucket\":%u,\"ldm_min_match\":%u,\"context_bytes\":%zu,\"workers\":%d,\"block_bytes\":%zu}",
		n==(1<<18) ? "" : ",",n,applied->windowLog,applied->chainLog,applied->hashLog,applied->searchLog,applied->minMatch,applied->targetLength,(unsigned)applied->strategy,
		ldm->enableLdm==ZSTD_ps_enable,ldm->windowLog,ldm->hashLog,ldm->hashRateLog,ldm->bucketSizeLog,ldm->minMatchLength,ZSTD_sizeof_CCtx(context),context->appliedParams.nbWorkers,context->blockSizeMax);
	ZSTD_freeCCtx(context);
	free(output); free(target); free(source);
}
int main(void) {
	puts("[");
	for (size_t n=1<<18; n<=1<<24; n*=2) row(n);
	puts("]");
	return 0;
}
