// Exercise the production deadline controller with controlled CPU time and a
// captured Mach declaration. No test changes the runner's actual scheduling.
#import <Foundation/Foundation.h>
#include <mach/thread_policy.h>
#include <pthread.h>
#include <time.h>
static _Thread_local uint64_t test_cpu = 1000000000ull;
static _Thread_local unsigned declarations;
static _Thread_local thread_time_constraint_policy_data_t declared_policy;
static _Thread_local int reject_policy;
static uint64_t rt_test_clock(clockid_t c) { return c == CLOCK_THREAD_CPUTIME_ID ? test_cpu : clock_gettime_nsec_np(c); }
static kern_return_t rt_test_set(thread_act_t t, thread_policy_flavor_t f, thread_policy_t p, mach_msg_type_number_t n) {
    if (t != pthread_mach_thread_np(pthread_self()) || f != THREAD_TIME_CONSTRAINT_POLICY || n != THREAD_TIME_CONSTRAINT_POLICY_COUNT) abort();
    declarations++; memcpy(&declared_policy, p, sizeof declared_policy);
    return reject_policy ? KERN_FAILURE : KERN_SUCCESS;
}
#define clock_gettime_nsec_np rt_test_clock
#define thread_policy_set rt_test_set
#define g_ft g_ft_hle
#include "../nvn/hle_nvn.c"
#undef g_ft
#undef thread_policy_set
#undef clock_gettime_nsec_np
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static int checks, failed;
#define CHECK(c, s) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", s); } } while (0)
static double declared_ms(void) { mach_timebase_info_data_t tb; mach_timebase_info(&tb); return (double)declared_policy.computation * tb.numer / tb.denom / 1e6; }
static void feed(unsigned n, uint64_t ns) { for (unsigned i = 0; i < n; i++) { test_cpu += ns; rt_present_tick(16666667); } }
static void *second_presenter(void *arg) {
    unsigned *out = arg; rt_present_tick(16666667); feed(120, 1000000); *out = declarations;
    return NULL;
}
int main(void) { @autoreleasepool {
    const char *present_env = getenv("DM_RT_PRESENT"), *rt_env = getenv("DM_RT");
    int on = present_env && atoi(present_env) && !(rt_env && !strcmp(rt_env, "0"));
    uint64_t tid; pthread_threadid_np(NULL, &tid); atomic_store(&g_rt_acq_tid, tid);
    rt_present_tick(16666667);
    CHECK(!declarations, "a same-thread acquire/present keeps the acquire's declaration");
    atomic_store(&g_rt_acq_tid, UINT64_MAX);
    rt_present_tick(0); CHECK(!declarations, "a zero period cannot declare a deadline");
    rt_present_tick(16666667);
    if (!on) { feed(240, 4000000); CHECK(!declarations, "disabled presenter or global RT switch makes no declarations"); }
    else {
        int fixed = rt_comp_fixed_ms();
        CHECK(declarations == 1 && fabs(declared_ms() - (fixed > 0 ? fixed : 2)) < .001, "a separate presenter declares its own initial or fixed budget");
        CHECK(declared_policy.preemptible && declared_policy.period == declared_policy.constraint, "the declaration stays preemptible within one period");
        feed(119, 2000000); unsigned d = declarations;
        feed(1, 5000000);
        CHECK(fabs(declared_ms() - (fixed > 0 ? fixed : 5.5)) < .001, "the own-thread peak is covered, or a fixed budget is preserved");
        feed(120, 5000000); CHECK(declarations <= d + 2, "stable windows do not repeatedly redeclare an unchanged budget");
        feed(120, 30000000); CHECK(declared_ms() <= 15.001, "a spike never declares over ninety percent of the frame period");
        rt_present_tick(8333333); CHECK(declared_ms() <= 7.501, "a changed period immediately caps the old budget");
        unsigned other = 0; pthread_t th; pthread_create(&th, NULL, second_presenter, &other); pthread_join(th, NULL);
        CHECK(other > 0, "a second OS thread owns a separate sample window and declaration");
        CHECK(g_rtp.period == 8333333, "the second presenter does not overwrite this thread's state");
        g_rtp = (rt_present_state){0}; reject_policy = 1; rt_present_tick(16666667);
        CHECK(!g_rtp.declared && !g_rtp.declared_period, "a rejected Mach declaration is not recorded as successful");
    }
    printf("presenter deadline: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
