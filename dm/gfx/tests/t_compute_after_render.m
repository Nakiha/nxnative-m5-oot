// Real fragment writes consumed by compute, plus independent work and the
// conservative host/copy/queue-switch cases of DM_NVN_COMPUTE_GAME_BAR.
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
    NSError *error = nil;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint i [[vertex_id]]) { return float4(i==1?3.0:-1.0,i==2?3.0:-1.0,0,1); }\n"
        "fragment float4 f(device atomic_uint *o [[buffer(0)]],constant uint &x [[buffer(1)]]) { atomic_store_explicit(o,x,memory_order_relaxed); return float4(.5); }\n"
        "kernel void c(device atomic_uint *i [[buffer(0)]],device uint *o [[buffer(1)]]) { *o=atomic_load_explicit(i,memory_order_relaxed); }\n" options:nil error:&error];
    CHECK(lib != nil, "the producer and consumer shaders compile"); if (!lib) return 1;
    MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new]; rd.vertexFunction = [lib newFunctionWithName:@"v"]; rd.fragmentFunction = [lib newFunctionWithName:@"f"]; rd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> rp = [g_dev newRenderPipelineStateWithDescriptor:rd error:&error];
    id<MTLFunction> cf = [lib newFunctionWithName:@"c"]; if (!cf) return 1;
    id<MTLComputePipelineState> cp = [g_dev newComputePipelineStateWithFunction:cf error:&error];
    CHECK(rp && cp, "both pipelines build"); if (!rp || !cp) return 1;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO]; td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> target = [g_dev newTextureWithDescriptor:td]; res_add(target);
    id<MTLBuffer> written = [g_dev newBufferWithLength:128 options:MTLResourceStorageModeShared], params = [g_dev newBufferWithLength:128 options:MTLResourceStorageModeShared], independent = [g_dev newBufferWithLength:128 options:MTLResourceStorageModeShared], output = [g_dev newBufferWithLength:128 options:MTLResourceStorageModeShared];
    if (!target || !written || !params || !independent || !output) return 1;
    for (id<MTLBuffer> b in @[written,params,independent,output]) res_add(b);
    memset(written.contents, 0, 128); memset(output.contents, 0, 128);
    for (unsigned i = 0; i < 8; i++) { ((uint32_t *)params.contents)[i * 4] = 100 + i; ((uint32_t *)independent.contents)[i * 4] = 900 + i; }
    NSMutableArray *tables = [NSMutableArray new];
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new]; ad.maxBufferBindCount = 2;
    mtl_sub_begin(); mtl_queue_activate(91001);
    for (unsigned i = 0; i < 8; i++) {
        id real_rt = [g_dev newArgumentTableWithDescriptor:ad error:&error], real_ct = [g_dev newArgumentTableWithDescriptor:ad error:&error];
        if (!real_rt || !real_ct) return 1;
        id rt = rec_table(real_rt), ct = rec_table(real_ct); if (!rt || !ct) return 1; [tables addObject:rt]; [tables addObject:ct];
        [rt setAddress:written.gpuAddress + i * 16 atIndex:0]; [rt setAddress:params.gpuAddress + i * 16 atIndex:1];
        [ct setAddress:(i == 0 ? independent : written).gpuAddress + i * 16 atIndex:0]; [ct setAddress:output.gpuAddress + i * 16 atIndex:1];
        MTL4RenderPassDescriptor *pd = [MTL4RenderPassDescriptor new]; pd.colorAttachments[0].texture = target; pd.colorAttachments[0].loadAction = MTLLoadActionClear; pd.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTL4RenderCommandEncoder> re = enc_r_begin_pass(pd); [re setRenderPipelineState:rp]; [re setArgumentTable:rt atStages:MTLRenderStageFragment]; [re setViewport:(MTLViewport){0,0,4,4,0,1}]; [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        enc_r_end_pass(re); g_cgb_need = 0;
        if (i == 1 || i == 5) {   // the actual replay opcode, not a synthetic flag
            uint8_t ops[24] = {0}; op_hdr bh = {.op=OP_BARRIER,.size=16}, end = {.op=OP_END,.size=8}; int32_t bits = NVN_BARRIER_ORDER_PRIMITIVES_BIT;
            memcpy(ops,&bh,8); memcpy(ops+8,&bits,4); memcpy(ops+16,&end,8); mtl_exec(ops);
            CHECK(g_cgb_need, "the replayed game barrier requires rendering before the consumer");
        }
        if (i == 3) mtl_queue_activate(91002);
        if (i == 6) { CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "the producer submission completes"); mtl_sub_begin(); }
        if (i == 7) {   // a committed segment is also a proof boundary
            g_cut_draw0 = 0; g_stat_draw += 64; sub_cut();
        }
        uint64_t light = g_cgb_light, waits = g_cgb_wait, full = g_cgb_full;
        id<MTL4ComputeCommandEncoder> ce = i == 4 ? blit_open() : dispatch_enc(i != 2);
        int relaxed = cgb_on() && barrier_game() && i != 2 && i != 3 && i != 4 && i != 6 && i != 7;
        CHECK(g_cgb_light == light + relaxed && g_cgb_full == full + !relaxed, "only eligible game dispatches use the selective consumer barrier");
        CHECK(g_cgb_wait == waits + (relaxed && (i == 1 || i == 5)), "game barriers retain rendering dependencies");
        [ce setComputePipelineState:cp]; [ce setArgumentTable:ct]; [ce dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)]; enc_b_end(g_blit); g_blit = nil;
        CHECK(!g_last_end_relaxed && !g_end_nodisp, "a compute encoder does not leak a render-end proof");
    }
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "the GPU completes all producer/consumer pairs");
    for (unsigned i = 0; i < 8; i++) CHECK(((uint32_t *)output.contents)[i * 4] == (i ? 100 + i : 900), "every dependent or independent consumer reads the expected data");
    printf("compute after render: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
