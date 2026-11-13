// Feed cut boundaries while actual GPU copies span the committed segments.
// Draw counts are synthetic; all bytes and the final completion fence are real.
#import <Foundation/Foundation.h>
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c,s) do { checks++; if (!(c)) { failed++; fprintf(stderr,"FAIL: %s\n",s); } } while (0)
int main(void) { @autoreleasepool {
    mtl_init(); g_warm_items = nil; atomic_store(&g_warm_ready, 0);
    CHECK(!cut_first_eligible(0, 0, 1), "CUT=0 keeps draw-count cuts disabled");
    CHECK(!cut_first_eligible(32, 1, 1), "later segments retain the normal threshold");
    CHECK(!cut_first_eligible(32, 0, 0), "the opt-out keeps the normal first threshold");
    CHECK(cut_first_eligible(32, 0, 1), "only an enabled first segment uses the early threshold");
    id<MTLBuffer> src = [g_dev newBufferWithLength:320 options:MTLResourceStorageModeShared], dst = [g_dev newBufferWithLength:320 options:MTLResourceStorageModeShared];
    if (!src || !dst) return 1;
    res_add(src); res_add(dst); for (unsigned i = 0; i < 320; i++) ((uint8_t *)src.contents)[i] = (uint8_t)(i * 13 + 7);
    memset(dst.contents, 0, 320); mtl_sub_begin();
    int normal = cut_draws(), early = cut_first(); uint64_t before = g_cuts;
    for (unsigned i = 0; i < 20; i++) {
        id<MTL4ComputeCommandEncoder> e = blit(); enc_b_copy_buffer(e, src, i * 16, dst, i * 16, 16);
        enc_b_end(g_blit); g_blit = nil; g_stat_draw += 4; sub_cut();
        unsigned draws = (i + 1) * 4, threshold = normal > 0 ? (unsigned)MIN(normal, cut_first_n()) : 0;
        unsigned expected = normal > 0 ? (early ? (draws >= threshold ? 1 + (draws - threshold) / normal : 0) : draws / normal) : 0;
        CHECK(g_cuts - before == expected, "first and subsequent cuts occur at their own boundaries");
    }
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "the last fence covers every earlier segment");
    CHECK(!memcmp(src.contents, dst.contents, 320), "all copies survive early publication and later segment reuse");
    printf("first segment: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
