// An optional MPP function must use the Metal 4 compiler before archive lookup.
// The fake legacy device refuses every request, so success proves the route.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
@interface ArchiveRefuses : NSObject
@property int calls;
@end
@implementation ArchiveRefuses
- (id<MTLComputePipelineState>)newComputePipelineStateWithDescriptor:(id)d error:(NSError **)e {
    (void)d; (void)e; self.calls++; return nil;
}
@end
@interface LegacyRefuses : NSObject
@property int calls;
@end
@implementation LegacyRefuses
- (id<MTLComputePipelineState>)newComputePipelineStateWithFunction:(id<MTLFunction>)f error:(NSError **)e {
    (void)f; self.calls++;
    if (e) *e = [NSError errorWithDomain:@"tensor-test" code:1 userInfo:@{NSLocalizedDescriptionKey:@"legacy compiler refuses"}];
    return nil;
}
@end
int main(void) { @autoreleasepool {
    setenv("DM_PSO_ARCHIVE", "off", 1); setenv("DM_PSO_BUNDLE", "off", 1); setenv("DM_PSO_MTL4", "1", 1);
    mtl_init(); pso4_init();
    NSError *e = nil;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nkernel void tensor_test(device uint *p [[buffer(0)]]) { p[0]=1; }\nkernel void ordinary_test(device uint *p [[buffer(0)]]) { p[0]=2; }\n" options:nil error:&e];
    if (!lib || !g_comp4) { fprintf(stderr,"compiler setup: %s\n", e.localizedDescription.UTF8String); return 1; }
    id<MTLFunction> tf = fn4_note([lib newFunctionWithName:@"tensor_test"], lib, @"tensor_test", nil);
    id<MTLFunction> normal = fn4_note([lib newFunctionWithName:@"ordinary_test"], lib, @"ordinary_test", nil);
    fn_tensor_note(tf);
    ArchiveRefuses *archive = [ArchiveRefuses new]; g_arch_bundle = (id<MTL4Archive>)archive;
    id<MTLDevice> actual = g_dev; LegacyRefuses *fake = [LegacyRefuses new]; g_dev = (id<MTLDevice>)fake;
    id<MTLComputePipelineState> ps = cps_new_b(tf, 0, &e);
    int ok = ps != nil && fake.calls == 0 && archive.calls == 0;
    e = nil; ps = cps_new_b(normal, 0, &e);
    ok &= ps == nil && fake.calls == 1 && archive.calls == 1;
    g_dev = actual;
    printf("Tensor compiler routing: %s\n", ok ? "PASS" : "FAIL");
    return !ok;
} }
