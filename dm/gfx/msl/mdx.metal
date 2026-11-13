// Indirect-count multi-draws masked on the GPU (nvn_mtl.m mdx_run)
#include <metal_stdlib>
using namespace metal;
struct mjob { device const uint *rec; device const uint *cnt; device uint *out; uint i, words, scratch_cap, pad; };   // scratch_cap: draw-private mesh capacity, 0 off
kernel void mdx_mask(device const mjob *j [[buffer(0)]], uint t [[thread_position_in_grid]]) {
  mjob m = j[t]; if (!m.out) return;
  // An indirect mesh draw: NVN's {count, first} as Metal's threadgroups {x, y, z}: {count, 1, 1} at +0 for a task shader's, and at +16 {ceil(count / limit), 1, 1} for the object
  // function of a mesh shader with no task, which launches the workgroups in blocks of the limit (dmsh_meshstage.py main0_o, nvn_geometry.inc mtk_encode)
  if (!m.words) { uint c = m.rec[0], blocks = c / m.i + (c % m.i != 0u); bool fits = m.scratch_cap && c <= m.scratch_cap;
    m.out[0] = c; m.out[1] = 1u; m.out[2] = 1u; m.out[4] = blocks; m.out[5] = 1u; m.out[6] = 1u;
    // Exactly one path draws the entire original count, with no truncation, CPU readback or allocation retries.
    m.out[8] = fits ? 0u : blocks; m.out[9] = m.out[10] = 1u;
    m.out[12] = fits ? blocks : 0u; m.out[13] = m.out[14] = 1u; return; }
  bool live = m.i < *m.cnt;
  for (uint k = 0; k < m.words; k++) m.out[k] = live ? m.rec[k] : 0u; }
