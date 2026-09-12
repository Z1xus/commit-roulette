#include <stdint.h>
#include <stdlib.h>
#include <stddef.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include "gpu-hash.h"
#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#define OPEN() LoadLibraryA("OpenCL.dll")
#define SYMBOL(lib, name) GetProcAddress((HMODULE)lib, name)
#define CLOSE(lib) FreeLibrary((HMODULE)lib)
#else
#include <dlfcn.h>
#if defined(__APPLE__)
#define OPEN() dlopen("/System/Library/Frameworks/OpenCL.framework/OpenCL", RTLD_NOW | RTLD_LOCAL)
#else
#define OPEN() dlopen("libOpenCL.so.1", RTLD_NOW | RTLD_LOCAL)
#endif
#define SYMBOL(lib, name) dlsym(lib, name)
#define CLOSE(lib) dlclose(lib)
#endif

typedef void *object;
typedef uint32_t uint;
typedef uint64_t bits;
enum {
    cl_device_type_gpu = 1 << 2,
    cl_queue_profiling_enable = 1 << 1,
    cl_mem_read_write = 1 << 0,
    cl_mem_read_only = 1 << 2,
    cl_mem_copy_host_ptr = 1 << 5,
    cl_kernel_work_group_size = 0x11b0,
    cl_profiling_command_start = 0x1282,
    cl_profiling_command_end = 0x1283,
};
#define API_LIST(X) \
    X(int, GetPlatformIDs, (uint, object *, uint *)) \
    X(int, GetDeviceIDs, (object, bits, uint, object *, uint *)) \
    X(object, CreateContext, (const intptr_t *, uint, const object *, void (*)(const char *, const void *, size_t, void *), void *, int *)) \
    X(object, CreateCommandQueue, (object, object, bits, int *)) \
    X(object, CreateProgramWithSource, (object, uint, const char **, const size_t *, int *)) \
    X(int, BuildProgram, (object, uint, const object *, const char *, void (*)(object, void *), void *)) \
    X(object, CreateKernel, (object, const char *, int *)) \
    X(object, CreateBuffer, (object, bits, size_t, void *, int *)) \
    X(int, SetKernelArg, (object, uint, size_t, const void *)) \
    X(int, EnqueueWriteBuffer, (object, object, uint, size_t, size_t, const void *, uint, const object *, object *)) \
    X(int, EnqueueReadBuffer, (object, object, uint, size_t, size_t, void *, uint, const object *, object *)) \
    X(int, EnqueueFillBuffer, (object, object, const void *, size_t, size_t, size_t, uint, const object *, object *)) \
    X(int, EnqueueNDRangeKernel, (object, object, uint, const size_t *, const size_t *, const size_t *, uint, const object *, object *)) \
    X(int, GetKernelWorkGroupInfo, (object, object, uint, size_t, void *, size_t *)) \
    X(int, GetEventProfilingInfo, (object, uint, size_t, void *, size_t *)) \
    X(int, ReleaseEvent, (object)) \
    X(int, ReleaseMemObject, (object)) \
    X(int, ReleaseKernel, (object)) \
    X(int, ReleaseProgram, (object)) \
    X(int, ReleaseCommandQueue, (object)) \
    X(int, ReleaseContext, (object))

struct gpu {
    void *library;
    object context, queue, program, kernels[4], buffers[3];
    uint *words, initial[8], seed[16];
    uint nonce_at, signed_nonce, sha256, skipped, variable_at, group;
    size_t limits[4];
    double scores[12];
    uint trial, best;
#define FIELD(ret, name, args) ret (*name) args;
    API_LIST(FIELD)
#undef FIELD
};

static void rebase(struct gpu *g, uint group) {
    uint64_t counter = (uint64_t)group << 32;
    uint size = g->signed_nonce ? 64 : 16;
    for (uint i = 0; i < size; ++i) {
        uint at = g->nonce_at + i;
        uint *word = &g->words[(at / 64) * 80 + at % 64 / 4];
        uint byte = g->signed_nonce ? ((counter >> (63 - i)) & 1 ? 9 : 32) : (uint)("0123456789abcdef"[(counter >> ((15 - i) * 4)) & 15]);
        uint shift = (3 - at % 4) * 8;
        *word = (*word & ~(255u << shift)) | byte << shift;
    }
    for (uint block = g->nonce_at / 64; block <= (g->nonce_at + size - 1) / 64; ++block)
        expand(g->words + block * 80, g->sha256);
    memcpy(g->seed, g->initial, sizeof(g->initial));
    for (uint block = 0; block < g->skipped; ++block) {
        uint working[8];
        memcpy(working, g->seed, sizeof(working));
        rounds(working, g->words + block * 80, g->sha256 ? 64 : 80, g->sha256);
        for (uint i = 0; i < (g->sha256 ? 8u : 5u); ++i) g->seed[i] += working[i];
    }
    memcpy(g->seed + 8, g->seed, 32);
    rounds(g->seed + 8, g->words + g->skipped * 80, g->variable_at / 4, g->sha256);
    g->group = group;
}

static int append(char **at, size_t *left, const char *format, ...) {
    va_list args;
    va_start(args, format);
    int n = vsnprintf(*at, *left, format, args);
    va_end(args);
    if (n < 0 || (size_t)n >= *left) return 0;
    *at += n;
    *left -= n;
    return 1;
}

static char *specialize(uint blocks, uint nonce_at, uint signed_nonce,
                        uint sha256, const uint8_t *digits, uint length, uint position, const uint *words, int upper_at) {
    size_t left = 65536;
    char *source = malloc(left), *at = source;
    if (!source) return NULL;
#define EMIT(...) if (!append(&at, &left, __VA_ARGS__)) goto fail
    EMIT("#define BLOCKS %u\n#define NONCE_AT %u\n#define SIGNED_NONCE %u\n#define SHA256 %u\n", blocks, nonce_at, signed_nonce, sha256);
    EMIT("constant uint constants[64] = {");
    for (uint i = 0; i < 64; ++i) EMIT("%s0x%08xu", i ? "," : "", constants[i]);
    EMIT("};\n");
    EMIT("uint rr(uint x, uint n) { return rotate(x, 32u - n); }\n");
    uint fixed = (nonce_at + (signed_nonce ? 32 : 8) + 63) / 64;
    EMIT("uint input_word(global const uint *schedule, uint block, uint i) { switch (block*16+i) {");
    for (uint i = 0; i < fixed * 16; ++i) {
        if ((int)(i * 4 + 4) > upper_at && i * 4 < nonce_at) continue;
        EMIT("case %u: return 0x%08xu;", i, words[i / 16 * 80 + i % 16]);
    }
    EMIT("default: return schedule[block*80+i]; }}\n");
    if (blocks > fixed && blocks - fixed <= 16) {
        EMIT("#define FIXED_WORD(block,t) fixed_words[((block)-%u)*80+(t)]\nconstant uint fixed_words[] = {", fixed);
        for (uint i = fixed * 80; i < blocks * 80; ++i) EMIT("%s0x%08xu", i == fixed * 80 ? "" : ",", words[i]);
        EMIT("};\n");
    } else EMIT("#define FIXED_WORD(block,t) schedule[(block)*80+(t)]\n");
    EMIT("uint matches(uint s[8]) { return ");
    uint last = (sha256 ? 64 : 40) - length;
    uint first = position == 1 ? last : 0;
    uint end = position == 2 ? last : first;
    for (uint offset = first; offset <= end; ++offset) {
        uint masks[8] = {0}, values[8] = {0};
        for (uint i = 0; i < length; ++i) {
            uint n = offset + i, shift = (7 - n % 8) * 4;
            masks[n / 8] |= 15u << shift;
            values[n / 8] |= (uint)digits[i] << shift;
        }
        EMIT("%s(", offset == first ? "" : " || ");
        int used = 0;
        for (uint i = 0; i < 8; ++i) {
            if (!masks[i]) continue;
            EMIT("%s((s[%u] & 0x%08xu) == 0x%08xu)", used++ ? " && " : "", i, masks[i], values[i]);
        }
        EMIT(")");
    }
    EMIT("; }\n");
#undef EMIT
    return source;
fail:
    free(source);
    return NULL;
}

void roulette_gpu_close(struct gpu *g) {
    if (!g) return;
    for (unsigned i = 0; i < 3; ++i)
        if (g->buffers[i]) g->ReleaseMemObject(g->buffers[i]);
    for (uint i = 0; i < 4; ++i)
        if (g->kernels[i]) g->ReleaseKernel(g->kernels[i]);
    if (g->program) g->ReleaseProgram(g->program);
    if (g->queue) g->ReleaseCommandQueue(g->queue);
    if (g->context) g->ReleaseContext(g->context);
    if (g->library) CLOSE(g->library);
    free(g->words);
    free(g);
}

static int prepare(struct gpu *g, object device, const char *source,
                   const uint8_t *tail, uint blocks, const uint *state,
                   const uint8_t *digits, uint nonce_at, uint signed_nonce,
                   uint sha256, uint length, uint position) {
    int err;
    g->words = schedules(tail, blocks, sha256);
    if (!g->words) return 0;
    memcpy(g->initial, state, sizeof(g->initial));
    g->nonce_at = nonce_at;
    g->signed_nonce = signed_nonce;
    g->sha256 = sha256;
    uint variable = nonce_at + (signed_nonce ? 32 : 8);
    g->skipped = variable / 64;
    g->variable_at = variable % 64;
    rebase(g, 0);
    g->context = g->CreateContext(NULL, 1, &device, NULL, NULL, &err);
    if (!g->context || err) return 0;
    g->queue = g->CreateCommandQueue(g->context, device, cl_queue_profiling_enable, &err);
    if (!g->queue || err) return 0;
    char *prefix = specialize(blocks - g->skipped, g->variable_at, signed_nonce, sha256, digits, length, position, g->words + g->skipped * 80, (int)nonce_at - (int)g->skipped * 64);
    if (!prefix) return 0;
    const char *sources[] = {
        prefix,
        "#define LANES 1\n#define KERNEL mine0\n#define ROUND_LOOP _Pragma(\"unroll 80\")\n", source,
        "\n#undef KERNEL\n#define KERNEL mine1\n#undef ROUND_LOOP\n#define ROUND_LOOP _Pragma(\"unroll 2\")\n", source,
        "\n#undef KERNEL\n#define KERNEL mine2\n#undef LANES\n#define LANES 2\n#undef ROUND_LOOP\n#define ROUND_LOOP _Pragma(\"unroll 80\")\n", source,
        "\n#undef KERNEL\n#define KERNEL mine3\n#undef ROUND_LOOP\n#define ROUND_LOOP _Pragma(\"unroll 2\")\n", source
    };
    g->program = g->CreateProgramWithSource(g->context, 9, sources, NULL, &err);
    free(prefix);
    if (!g->program || err || g->BuildProgram(g->program, 1, &device, "-cl-std=CL1.2", NULL, NULL)) return 0;
    for (uint i = 0; i < 4; ++i) {
        char name[] = "mine0";
        name[4] += (char)i;
        g->kernels[i] = g->CreateKernel(g->program, name, &err);
        if (!g->kernels[i] || err) return 0;
        if (g->GetKernelWorkGroupInfo(g->kernels[i], device, cl_kernel_work_group_size, sizeof(size_t), &g->limits[i], NULL)) return 0;
    }
    const void *data[] = { g->words + g->skipped * 80, g->seed, NULL };
    const size_t sizes[] = { (size_t)(blocks - g->skipped) * 80 * sizeof(uint), sizeof(g->seed), 4 };
    for (uint i = 0; i < 3; ++i) {
        g->buffers[i] = g->CreateBuffer(g->context, i < 2 ? cl_mem_read_only | cl_mem_copy_host_ptr : cl_mem_read_write, sizes[i], (void *)data[i], &err);
        if (!g->buffers[i] || err) return 0;
        for (uint k = 0; k < 4; ++k)
            if (g->SetKernelArg(g->kernels[k], i < 2 ? i : 4, sizeof(object), &g->buffers[i])) return 0;
    }
    return 1;
}

struct gpu *roulette_gpu_open(const char *source, const uint8_t *tail, uint blocks,
                             const uint *state, const uint8_t *digits, uint nonce_at,
                             uint signed_nonce, uint sha256, uint length, uint position) {
    struct gpu *g = calloc(1, sizeof(*g));
    if (!g) return NULL;
    g->library = OPEN();
    if (!g->library) goto fail;
#define LOAD(ret, name, args) g->name = (ret (*) args)SYMBOL(g->library, "cl" #name); if (!g->name) goto fail;
    API_LIST(LOAD)
#undef LOAD
    uint count = 0;
    if (g->GetPlatformIDs(0, NULL, &count) || !count) goto fail;
    object *platforms = calloc(count, sizeof(object));
    if (!platforms) goto fail;
    if (g->GetPlatformIDs(count, platforms, NULL)) { free(platforms); goto fail; }
    object device = NULL;
    for (uint i = 0; i < count; ++i) {
        if (!g->GetDeviceIDs(platforms[i], cl_device_type_gpu, 1, &device, NULL)) break;
        device = NULL;
    }
    free(platforms);
    if (!device || !prepare(g, device, source, tail, blocks, state, digits, nonce_at, signed_nonce, sha256, length, position)) goto fail;
    return g;
fail:
    roulette_gpu_close(g);
    return NULL;
}

static int batch(struct gpu *g, uint64_t start, uint count, uint *winner) {
    uint group = (uint)(start >> 32);
    if (group != g->group) {
        rebase(g, group);
        size_t changed = ((g->variable_at + (g->signed_nonce ? 32 : 8) + 63) / 64) * 80 * sizeof(uint);
        if (g->EnqueueWriteBuffer(g->queue, g->buffers[0], 1, 0, changed, g->words + g->skipped * 80, 0, NULL, NULL)) return 0;
        if (g->EnqueueWriteBuffer(g->queue, g->buffers[1], 1, 0, sizeof(g->seed), g->seed, 0, NULL, NULL)) return 0;
    }
    int tuning = count >= 131072 && g->trial < 24;
    uint choice = tuning ? g->trial / 2 : g->best;
    uint variant = choice / 3;
    size_t local = (size_t)64 << (choice % 3);
    if (local > g->limits[variant]) local = 0;
    object kernel = g->kernels[variant];
    *winner = UINT32_MAX;
    if (g->SetKernelArg(kernel, 2, sizeof(start), &start)) return 0;
    if (g->SetKernelArg(kernel, 3, sizeof(count), &count)) return 0;
    if (g->EnqueueFillBuffer(g->queue, g->buffers[2], winner, sizeof(*winner), 0, sizeof(*winner), 0, NULL, NULL)) return 0;
    uint lanes = variant >= 2 ? 2 : 1;
    size_t size = ((size_t)count + lanes - 1) / lanes;
    if (local) size = (size + local - 1) / local * local;
    object event = NULL;
    if (g->EnqueueNDRangeKernel(g->queue, kernel, 1, NULL, &size, local ? &local : NULL, 0, NULL, tuning ? &event : NULL)) return 0;
    int ok = g->EnqueueReadBuffer(g->queue, g->buffers[2], 1, 0, 4, winner, 0, NULL, NULL) == 0;
    if (event) {
        bits begin = 0, end = 0;
        if (ok && !g->GetEventProfilingInfo(event, cl_profiling_command_start, sizeof(begin), &begin, NULL) &&
            !g->GetEventProfilingInfo(event, cl_profiling_command_end, sizeof(end), &end, NULL) && end > begin) {
            double score = (double)(end - begin) / count;
            if (!g->scores[choice] || score < g->scores[choice]) g->scores[choice] = score;
            if (!g->scores[g->best] || g->scores[choice] < g->scores[g->best]) g->best = choice;
        }
        g->ReleaseEvent(event);
    }
    if (tuning) ++g->trial;
    return ok;
}

int roulette_gpu_batch(struct gpu *g, uint64_t start, uint count, uint *winner) {
    if (!count || count - 1 > UINT64_MAX - start) return 0;
    uint64_t remaining = UINT64_C(0x100000000) - (uint)start;
    uint first = remaining < count ? (uint)remaining : count;
    if (!batch(g, start, first, winner)) return 0;
    if (first == count) return 1;
    uint second;
    if (!batch(g, start + first, count - first, &second)) return 0;
    if (*winner == UINT32_MAX && second != UINT32_MAX) *winner = second + first;
    return 1;
}

uint roulette_gpu_batch_limit(struct gpu *g) {
    return g->trial < 24 ? 1048576 : 67108864;
}
