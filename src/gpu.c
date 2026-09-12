#include <stdint.h>
#include <stdlib.h>
#include <stddef.h>
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
    X(int, EnqueueNDRangeKernel, (object, object, uint, const size_t *, const size_t *, const size_t *, uint, const object *, object *)) \
    X(int, ReleaseMemObject, (object)) \
    X(int, ReleaseKernel, (object)) \
    X(int, ReleaseProgram, (object)) \
    X(int, ReleaseCommandQueue, (object)) \
    X(int, ReleaseContext, (object))

struct gpu {
    void *library;
    object context, queue, program, kernel, buffers[4];
#define FIELD(ret, name, args) ret (*name) args;
    API_LIST(FIELD)
#undef FIELD
};

void roulette_gpu_close(struct gpu *g) {
    if (!g) return;
    for (unsigned i = 0; i < 4; ++i)
        if (g->buffers[i]) g->ReleaseMemObject(g->buffers[i]);
    if (g->kernel) g->ReleaseKernel(g->kernel);
    if (g->program) g->ReleaseProgram(g->program);
    if (g->queue) g->ReleaseCommandQueue(g->queue);
    if (g->context) g->ReleaseContext(g->context);
    if (g->library) CLOSE(g->library);
    free(g);
}

static int prepare(struct gpu *g, object device, const char *source,
                   const uint8_t *tail, uint blocks, const uint *state,
                   const uint8_t *digits, uint nonce_at, uint signed_nonce,
                   uint sha256, uint length, uint position) {
    int err;
    g->context = g->CreateContext(NULL, 1, &device, NULL, NULL, &err);
    if (!g->context || err) return 0;
    g->queue = g->CreateCommandQueue(g->context, device, 0, &err);
    if (!g->queue || err) return 0;
    g->program = g->CreateProgramWithSource(g->context, 1, &source, NULL, &err);
    if (!g->program || err || g->BuildProgram(g->program, 1, &device, "-cl-std=CL1.2", NULL, NULL)) return 0;
    g->kernel = g->CreateKernel(g->program, "mine", &err);
    if (!g->kernel || err) return 0;
    const void *data[] = { tail, state, digits, NULL };
    const size_t sizes[] = { (size_t)blocks * 64, 32, length, 4 };
    for (uint i = 0; i < 4; ++i) {
        g->buffers[i] = g->CreateBuffer(g->context, i < 3 ? 36 : 1, sizes[i], (void *)data[i], &err);
        if (!g->buffers[i] || err) return 0;
        if (g->SetKernelArg(g->kernel, i < 3 ? i : 10, sizeof(object), &g->buffers[i])) return 0;
    }
    const uint scalars[] = { blocks, nonce_at, signed_nonce, sha256, length, position };
    for (uint i = 0; i < 6; ++i)
        if (g->SetKernelArg(g->kernel, i + 3, sizeof(uint), &scalars[i])) return 0;
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
        if (!g->GetDeviceIDs(platforms[i], 4, 1, &device, NULL)) break;
        device = NULL;
    }
    free(platforms);
    if (!device || !prepare(g, device, source, tail, blocks, state, digits, nonce_at, signed_nonce, sha256, length, position)) goto fail;
    return g;
fail:
    roulette_gpu_close(g);
    return NULL;
}

int roulette_gpu_batch(struct gpu *g, uint64_t start, uint count, uint *winner) {
    *winner = UINT32_MAX;
    if (g->SetKernelArg(g->kernel, 9, sizeof(start), &start)) return 0;
    if (g->EnqueueWriteBuffer(g->queue, g->buffers[3], 1, 0, 4, winner, 0, NULL, NULL)) return 0;
    size_t size = count;
    if (g->EnqueueNDRangeKernel(g->queue, g->kernel, 1, NULL, &size, NULL, 0, NULL, NULL)) return 0;
    return g->EnqueueReadBuffer(g->queue, g->buffers[3], 1, 0, 4, winner, 0, NULL, NULL) == 0;
}
