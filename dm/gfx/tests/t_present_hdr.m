// Real GPU checks of the production present: HDR PQ pass-through, sRGB -> PQ,
// ten-bit precision, an SDR preview, and unchanged SDR when HDR is off.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(name, ok) do { checks++; if (!(ok)) { failed++; printf("FAIL: %s\n", name); } } while (0)
static double pq(double nits) {
    double y = pow(fmax(0, fmin(nits / 10000, 1)), 2610.0 / 16384);
    return pow((3424.0 / 4096 + (2413.0 / 128) * y) / (1 + (2392.0 / 128) * y), 2523.0 / 32);
}
static double srgb_linear(double x) { return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4); }
static id<MTLTexture> texture(MTLPixelFormat f, MTLTextureUsage usage) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:8 height:8 mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = usage;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:d]; CHECK("texture created", t != nil); return t;
}
static void render(id<MTLTexture> src, id<MTLTexture> out, int modern) {
    if (modern) {
        res_add(src); res_commit();
        CHECK("Metal 4 present completes", present_offscreen_wait(src, NULL, out) == PRESENT_STANDARD);
        res_remove(src);
    } else {
        id<MTLCommandBuffer> cb = [g_q commandBuffer];
        CHECK("classic present encodes", present_encode(cb, src, out, NULL));
        [cb commit]; [cb waitUntilCompleted];
        CHECK("classic present completes", cb.status == MTLCommandBufferStatusCompleted);
    }
}
static void sdr_case(int modern, int srgb) {
    id<MTLTexture> src = texture(srgb ? MTLPixelFormatRGBA8Unorm_sRGB : MTLPixelFormatRGBA8Unorm, MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView);
    uint8_t pixels[256];
    for (int i = 0; i < 64; i++) { uint8_t *p = pixels + 4 * i; p[0] = i % 8 == 0 ? 0 : i % 8 == 1 ? 255 : 128; p[1] = p[2] = p[0]; p[3] = 255; }
    [src replaceRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 withBytes:pixels bytesPerRow:32];
    id<MTLTexture> out = texture(MTLPixelFormatBGR10A2Unorm, MTLTextureUsageRenderTarget);
    CHECK("SDR input is converted, not interpreted as PQ", present_color_mode(src, out.pixelFormat) == 1);
    render(src, out, modern); uint32_t actual[64];
    [out getBytes:actual bytesPerRow:32 fromRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0];
    for (int i = 0; i < 64; i++) {
        int expected = (int)lrint(pq(srgb_linear(pixels[4 * i] / 255.0) * 203) * 1023);
        uint32_t v = actual[i];
        CHECK("203-nit SDR white / midgrey / black reference", abs((int)(v & 1023) - expected) <= 2 && abs((int)((v >> 10) & 1023) - expected) <= 2 && abs((int)((v >> 20) & 1023) - expected) <= 2);
    }
    // Non-grey primaries check the BT.709 -> BT.2020 matrix, not just gamma.
    for (int i = 0; i < 64; i++) { pixels[4 * i] = 255; pixels[4 * i + 1] = pixels[4 * i + 2] = 0; }
    [src replaceRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 withBytes:pixels bytesPerRow:32];
    render(src, out, modern); [out getBytes:actual bytesPerRow:32 fromRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0];
    int want[3] = {(int)lrint(pq(203 * 0.0163916) * 1023), (int)lrint(pq(203 * 0.069097) * 1023), (int)lrint(pq(203 * 0.627404) * 1023)};
    for (int c = 0; c < 3; c++) CHECK("red primary transformed to BT.2020", abs((int)((actual[0] >> (10 * c)) & 1023) - want[c]) <= 2);
}
static void pq_case(int modern) {
    id<MTLTexture> src = texture(MTLPixelFormatRGB10A2Unorm, MTLTextureUsageShaderRead);
    uint32_t pixels[64];
    for (int i = 0; i < 64; i++) { uint32_t v = (uint32_t)lrint(pq(i % 8 < 4 ? 203 : 1000) * 1023); pixels[i] = v | v << 10 | v << 20 | 3u << 30; }
    [src replaceRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 withBytes:pixels bytesPerRow:32];
    id<MTLTexture> out = texture(MTLPixelFormatBGR10A2Unorm, MTLTextureUsageRenderTarget);
    CHECK("native HDR is not passed through an SDR transfer function", present_color_mode(src, out.pixelFormat) == 0);
    render(src, out, modern); uint32_t actual[64];
    [out getBytes:actual bytesPerRow:32 fromRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0];
    for (int i = 0; i < 64; i++) CHECK("203/1000-nit PQ codes preserved at ten bits", actual[i] == pixels[i]);
    id<MTLTexture> preview = texture(MTLPixelFormatRGBA8Unorm, MTLTextureUsageRenderTarget);
    CHECK("SDR captures get a tone-mapped preview", present_color_mode(src, preview.pixelFormat) == 2);
    render(src, preview, modern); uint8_t bytes[256];
    [preview getBytes:bytes bytesPerRow:32 fromRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0];
    CHECK("SDR preview retains a brighter highlight", bytes[4 * 7] > bytes[0] && bytes[4 * 7] < 255);
}
static void float_case(int modern) {
    id<MTLTexture> src = texture(MTLPixelFormatRGBA16Float, MTLTextureUsageShaderRead);
    _Float16 px[256];
    for (int i = 0; i < 64; i++) { px[4 * i] = (_Float16)pq(1000); px[4 * i + 1] = (_Float16)pq(203); px[4 * i + 2] = (_Float16)pq(100); px[4 * i + 3] = 1; }
    [src replaceRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 withBytes:px bytesPerRow:64];
    id<MTLTexture> out = texture(MTLPixelFormatBGR10A2Unorm, MTLTextureUsageRenderTarget);
    CHECK("float PQ source kept in HDR", present_color_mode(src, out.pixelFormat) == 0);
    render(src, out, modern); uint32_t actual[64];
    [out getBytes:actual bytesPerRow:32 fromRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0];
    for (int c = 0; c < 3; c++) CHECK("float PQ primaries and luminance quantized only to ten bits", abs((int)((actual[0] >> (10 * c)) & 1023) - (int)lrint((double)px[2 - c] * 1023)) <= 1);
}
int main(void) { @autoreleasepool {
    setenv("DM_HDR", "1", 1); setenv("DM_HDR_INPUT", "pq2020", 1);
    mtl_init(); mtl_present_layer(1, 1); g_fx_mode = 1;   // experiment must bypass perceptual SDR MetalFX
    id<MTLRenderPipelineState> pq_pso = present_pipeline(MTLPixelFormatBGR10A2Unorm, 0);
    id<MTLRenderPipelineState> sdr_pso = present_pipeline(MTLPixelFormatBGR10A2Unorm, 1);
    CHECK("HDR and converted-SDR pipelines stay distinct", pq_pso != sdr_pso);
    CHECK("switching back reuses the retained HDR pipeline", present_pipeline(MTLPixelFormatBGR10A2Unorm, 0) == pq_pso);
    CHECK("an SDR capture does not replace the HDR pipeline", present_pipeline(MTLPixelFormatRGBA8Unorm, 2) != pq_pso && present_pipeline(MTLPixelFormatBGR10A2Unorm, 0) == pq_pso);
    for (int modern = 0; modern < 2; modern++) { sdr_case(modern, 0); sdr_case(modern, 1); pq_case(modern); float_case(modern); }
    id<MTLTexture> src = texture(MTLPixelFormatRGBA8Unorm, MTLTextureUsageShaderRead);
    unsetenv("DM_HDR");
    CHECK("HDR is opt-in; SDR behavior unchanged", present_color_mode(src, MTLPixelFormatBGR10A2Unorm) == 0);
    setenv("DM_HDR", "1", 1); unsetenv("DM_HDR_INPUT");
    CHECK("unknown input encoding is not enabled", !present_hdr_requested());
    printf("HDR present: %d checks, %d failures (synthetic GPU samples; not game color validation)\n", checks, failed);
    return failed ? 1 : 0;
} }
