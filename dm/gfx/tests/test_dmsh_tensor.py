"""Optional Apple10 MPP HMMA lowering: same network and half boundaries."""
import os
import re
import shutil
import unittest
from test_dmsh_hmma import HEAD, HELPER, KERNEL, SEQ_KERNEL, CLOBBER_KERNEL, SLOT_KERNEL, RUNNER, SEQ_RUNNER, SLOT_RUNNER, run_libs
from dmsh_rewrite import hmma_msl, hmma_tensor_msl


def tensor(src):
    result = hmma_tensor_msl(hmma_msl(HEAD + HELPER + src))
    if result is None: raise AssertionError('constant HMMA flags were refused')
    return result


def tensor_run(test, sources, runner):
    return run_libs(test, sources, runner.replace('if (!dev)', 'if (!dev || ![dev supportsFamily:MTLGPUFamilyApple10])'))


class TensorRewrite(unittest.TestCase):
    def test_slots_and_direct_a(self):
        out = tensor(SEQ_KERNEL)
        self.assertIn('simdgroup_half8x8 dm_acc[16]', out)
        self.assertIn('adirect = (f & 16) != 0', out)
        self.assertIn('__attribute__((noinline)) void dm_tensor_math', out)
        self.assertIn('threadgroup spvUnsafeArray<uint, 1536> scr;', out)
        self.assertIn('threadgroup spvUnsafeArray<uint, 1280> shm;', out)
        self.assertIn('v = fma(', out)

    def test_extra_scratch_cannot_exceed_threadgroup_limit(self):
        src = KERNEL.replace('    threadgroup spvUnsafeArray<uint, 1024> scr;', '    threadgroup uint budget[7168];\n    threadgroup spvUnsafeArray<uint, 1024> scr;')
        self.assertIsNone(hmma_tensor_msl(hmma_msl(HEAD + HELPER + src)))

    def test_expansion_preserves_a_name_containing_the_old_size(self):
        src = HEAD + HELPER.replace('_34', '_1024') + KERNEL.replace('scr', '_1024')
        out = hmma_tensor_msl(hmma_msl(src))
        self.assertIsNotNone(out)
        self.assertIn('spvUnsafeArray<uint, 1536> _1024;', out)
        self.assertIn('&_1024[uint(_11) * 3 / 2]', out)

    def test_no_hmma_has_no_variant(self):
        self.assertIsNone(hmma_tensor_msl(HEAD))


@unittest.skipUnless(shutil.which('xcrun') and os.getenv('DMSH_TEST_GPU') == '1', 'explicit Apple10 GPU test')
class TensorOnGpu(unittest.TestCase):
    def test_single_matches_reference(self):
        tensor_run(self, [tensor(KERNEL)], RUNNER)

    def test_chains_and_transpose_match_reference(self):
        tensor_run(self, [tensor(SEQ_KERNEL)], SEQ_RUNNER)

    def test_unrelated_call_does_not_clobber_slot(self):
        tensor_run(self, [tensor(CLOBBER_KERNEL)], SEQ_RUNNER)

    def test_b_slots_match_original_bits(self):
        base = hmma_msl(HEAD + HELPER + SLOT_KERNEL)
        a, b = tensor_run(self, [tensor(SLOT_KERNEL), base], SLOT_RUNNER)
        self.assertEqual(a, b)

    def test_wide_inputs_match_reference(self):
        # Cancellation, subnormals and values that overflow f16 accumulators.
        runner = RUNNER.replace('(rand() % 2001 - 1000) / 1000.0f', 'ldexpf((rand() % 2001 - 1000) / 1000.0f, rand() % 22 - 11)')
        # NaN payload/sign is hardware dependent; compare their classification.
        runner = runner.replace('bad += (r[q2] >> (16 * j) & 0xffff) != f2h(ref);', 'bad += isnan(ref) ? !isnan(h2f((r[q2] >> (16 * j)) & 0xffff)) : (r[q2] >> (16 * j) & 0xffff) != f2h(ref);')
        tensor_run(self, [tensor(KERNEL)], runner)


if __name__ == '__main__': unittest.main()
