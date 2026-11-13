// Exercise the production HDR capability hooks, including unavailable displays.
#include "../hle_vi.c"
extern int g_test_hdr_peak;
uint64_t now_ns(void) { return 0; }
uint64_t guest_ns(void) { return 0; }
int dm_sdk_ounce(void) { return 1; }
int dm_opmode(void) { return 1; }
uint64_t dm_nvn_frame_count(void) { return 0; }
void mtl_present_layer(uint32_t w, uint32_t h) { (void)w; (void)h; }
void mtl_present_progress(uint64_t *q, uint64_t *d) { *q = *d = 0; }
double mtl_presented_time(uint64_t n) { (void)n; return 0; }
static int checks, failed;
#define CHECK(name, ok) do { checks++; if (!(ok)) { failed++; fprintf(stderr, "FAIL: %s\n", name); } } while (0)
int main(void) {
    for (int i = 0; i < 3; i++) {
        g_test_hdr_peak = i == 1 ? 1000 : 0;
        uint8_t on = 255; uint32_t format = 255; uint16_t peak = 65535, white = 0;
        CHECK("status succeeds", h_vi_HdrStatus(&on, &format, &peak, NULL) == RES_OK);
        CHECK("display availability controls HDR", on == (i == 1));
        CHECK("no stale peak on SDR fallback", peak == g_test_hdr_peak);
        CHECK("SDR format stays zero", i == 1 || format == 0);
        CHECK("null output pointers", h_vi_HdrStatus(NULL, NULL, NULL, NULL) == RES_OK);
        CHECK("paper white query", h_vi_PaperWhite(&white, NULL) == RES_OK && white == 203);
    }
    uint8_t vrr = 1;
    CHECK("HDR does not advertise VRR", h_vi_VrrSupported(&vrr, NULL) == RES_OK && !vrr);
    printf("vi HDR: %d checks, %d failures\n", checks, failed);
    return failed ? 1 : 0;
}
