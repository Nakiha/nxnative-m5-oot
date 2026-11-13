// Hold the encode worker at a submission boundary: publish-only must return before release, while the ordinary drain must wait.
// Then reuse allocator slots and release per-submission source buffers before encoding catches up; GPU copies and fences must remain ordered.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
int main(void) { @autoreleasepool {
    int async = atoi(getenv("DM_NVN_ENC_ASYNC") ?: "0") > 0;
    mtl_init(); g_warm_items = nil; atomic_store(&g_warm_ready, 0);
    dispatch_semaphore_t entered = dispatch_semaphore_create(0), returned = dispatch_semaphore_create(0), release = dispatch_semaphore_create(0);
    dispatch_group_t helper = dispatch_group_create();
    __block int early = -1;
    dispatch_group_async(helper, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        dispatch_semaphore_wait(entered, DISPATCH_TIME_FOREVER);
        early = dispatch_semaphore_wait(returned, dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC)) == 0;
        dispatch_semaphore_signal(release);
    });
    mtl_sub_begin();
    rec_queue_block(^{ dispatch_semaphore_signal(entered); dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER); });
    uint64_t first = mtl_sub_commit();
    if (async) CHECK(mtl_completed_fence() < first, "publication does not complete a held GPU fence");
    dispatch_semaphore_signal(returned);
    dispatch_group_wait(helper, DISPATCH_TIME_FOREVER);
    CHECK(early == async, "only publish-only mode returns while the encode worker is held");
    enum { N = 96, BYTES = 256 };
    id<MTLBuffer> out = [g_dev newBufferWithLength:N * BYTES options:MTLResourceStorageModeShared]; res_add(out);
    uint64_t last = first;
    for (int i = 0; i < N; i++) { @autoreleasepool {
        mtl_sub_begin();
        id<MTLBuffer> src = [g_dev newBufferWithLength:BYTES options:MTLResourceStorageModeShared]; res_add(src);
        [blit() fillBuffer:src range:NSMakeRange(0, BYTES) value:(uint8_t)(i + 1)];
        [blit() copyFromBuffer:src sourceOffset:0 toBuffer:out destinationOffset:i * BYTES size:BYTES];
        defer_obj_release(src);
        last = mtl_sub_commit();
    } }
    CHECK(mtl_wait(last, 5000000000ull) && !mtl_last_commit_error(), "all queued submissions complete without a GPU error");
    const uint8_t *bytes = out.contents;
    for (int i = 0; i < N; i++) { int good = 1; for (int j = 0; j < BYTES; j++) if (bytes[i * BYTES + j] != i + 1) good = 0; CHECK(good, "owned buffers survive deferred encoding in FIFO order"); }
    CHECK(mtl_completed_fence() >= last && last > first, "the last GPU fence covers every prior submission");
    printf("t_rec_sub_end: async=%d %d checks, %d failed\n", async, checks, failed);
    return failed != 0;
} }
