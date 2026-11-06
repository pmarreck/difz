#define ZSTD_STATIC_LINKING_ONLY
#include "zstd_compress_internal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <valgrind/callgrind.h>

static void checked(size_t result) {
    if (ZSTD_isError(result)) { fprintf(stderr, "%s\n", ZSTD_getErrorName(result)); exit(1); }
}
static void row(FILE *corpus, const char *axis, size_t source_size, size_t target_size) {
    unsigned char *source = malloc(source_size), *target = malloc(target_size);
    size_t capacity = ZSTD_compressBound(target_size);
    void *output = malloc(capacity);
    if (!source || !target || !output) exit(2);
    rewind(corpus);
    if (fread(source,1,source_size,corpus)!=source_size) exit(3);
    for (size_t i=0; i<target_size; i++) target[i]=source[i%source_size] ^ (i%4093==0);
    ZSTD_CCtx *context = ZSTD_createCCtx();
    if (!context) exit(2);
    ZSTD_compressionParameters p = ZSTD_getCParams(9, target_size, source_size);
    size_t span = source_size > target_size ? source_size : target_size;
    unsigned raw=0;
    for (size_t n=span; n; n>>=1) ++raw;
    unsigned window=raw<10 ? 10 : raw>31 ? 31 : raw;
    unsigned cycle=p.chainLog-(p.strategy>=ZSTD_btlazy2);
    checked(ZSTD_CCtx_setParameter(context,ZSTD_c_compressionLevel,9));
    checked(ZSTD_CCtx_setParameter(context,ZSTD_c_nbWorkers,0));
    checked(ZSTD_CCtx_setParameter(context,ZSTD_c_enableLongDistanceMatching,raw>cycle));
    checked(ZSTD_CCtx_setParameter(context,ZSTD_c_windowLog,(int)window));
    checked(ZSTD_CCtx_setParameter(context,ZSTD_c_chainLog,(int)p.chainLog));
    checked(ZSTD_CCtx_setParameter(context,ZSTD_c_hashLog,(int)p.hashLog));
    checked(ZSTD_CCtx_setParameter(context,ZSTD_c_searchLog,(int)p.searchLog));
    checked(ZSTD_CCtx_setParameter(context,ZSTD_c_minMatch,(int)p.minMatch));
    checked(ZSTD_CCtx_setParameter(context,ZSTD_c_targetLength,(int)p.targetLength));
    checked(ZSTD_CCtx_setParameter(context,ZSTD_c_strategy,(int)p.strategy));
    checked(ZSTD_CCtx_refPrefix(context,source,source_size));
    char label[80];
    snprintf(label,sizeof label,"%s-%zu-%zu",axis,source_size,target_size);
    CALLGRIND_START_INSTRUMENTATION;
    CALLGRIND_ZERO_STATS;
    size_t written=ZSTD_compress2(context,output,capacity,target,target_size);
    CALLGRIND_DUMP_STATS_AT(label);
    CALLGRIND_STOP_INSTRUMENTATION;
    checked(written);
    const ZSTD_compressionParameters *applied=&context->appliedParams.cParams;
    const ldmParams_t *ldm=&context->appliedParams.ldmParams;
    printf("{\"axis\":\"%s\",\"source_size\":%zu,\"target_size\":%zu,\"window\":%u,\"chain\":%u,\"hash\":%u,\"search\":%u,\"min_match\":%u,\"strategy\":%u,\"ldm_enabled\":%u,\"ldm_window\":%u,\"ldm_hash\":%u,\"ldm_rate\":%u,\"ldm_bucket\":%u,\"ldm_min_match\":%u,\"context_bytes\":%zu,\"frame_bytes\":%zu}\n",
        axis,source_size,target_size,applied->windowLog,applied->chainLog,applied->hashLog,applied->searchLog,applied->minMatch,(unsigned)applied->strategy,
        (unsigned)ldm->enableLdm,ldm->windowLog,ldm->hashLog,ldm->hashRateLog,ldm->bucketSizeLog,ldm->minMatchLength,ZSTD_sizeof_CCtx(context),written);
    ZSTD_freeCCtx(context);
    free(output); free(target); free(source);
}
int main(int argc, char **argv) {
    if (argc!=2) return 3;
    FILE *corpus=fopen(argv[1],"rb");
    if (!corpus) return 3;
    for (size_t n=1<<20; n<=1<<23; n*=2) row(corpus,"joint",n,n);
    fclose(corpus);
    return 0;
}
