// Pure preparation of copied queue records. Only opcodes and inline barrier bits are read; no pointed-to guest data, renderer state, Metal objects or events are touched.
#pragma once
#include <stdlib.h>
#include "nvn_obj.h"

enum { NVP_PASS, NVP_DISPATCH, NVP_STOP, NVP_DYNAMIC };
static inline int nvn_csh_record_kind(uint32_t op, const void *payload, size_t bytes) {
    switch (op) {
    case OP_DISPATCH: return NVP_DISPATCH;
    case OP_BARRIER: { uint32_t bits; if (bytes < sizeof bits) return NVP_STOP; memcpy(&bits, payload, sizeof bits); return bits ? NVP_STOP : NVP_PASS; }
    case OP_DRAW: case OP_DRAW_IDX:
    case OP_ALPHA_REF: case OP_BIND_IMG: case OP_BIND_PROGRAM: case OP_BIND_SAMP: case OP_BIND_SSBO: case OP_BIND_STATE: case OP_BIND_TEX: case OP_BIND_TEX1:
    case OP_BIND_UBO: case OP_BIND_UBO_SMALL: case OP_BIND_VATTR: case OP_BIND_VBUF: case OP_BIND_VBUF1: case OP_BIND_VSTREAM: case OP_BLEND_COLOR: case OP_COPY_STRIDE:
    case OP_DEPTH_CLAMP: case OP_DEPTH_RANGE: case OP_POLY_OFFSET: case OP_PRIM_RESTART: case OP_PUSH_CONST: case OP_RAST_DISCARD: case OP_SCISSOR: case OP_SET_SAMP_POOL:
    case OP_SET_TEX_POOL: case OP_STENCIL: case OP_TF_BIND: case OP_VIEWPORTS: case OP_VP_SWIZZLE: return NVP_PASS;
    case OP_CALL: case OP_JUMP: case OP_MULTI_DRAW: return NVP_DYNAMIC;   // the normal cursor expands these; this planner never follows their pointers
    default: return NVP_STOP;
    }
}
typedef struct nvn_command_plan {
    const uint8_t *bytes;
    size_t length;
    int8_t scan[];   // -1: use the normal scan; 0/1: its answer at this record's start, with no return stack
} nvn_command_plan;

static inline nvn_command_plan *nvn_command_plan_new(const void *bytes, size_t length) {
    // Large or malformed input simply uses normal replay. Offsets are 32-bit, and the temporary array has one slot per possible record.
    if (!bytes || length < 8 || (length & 7) || length > (64u << 20)) return NULL;
    nvn_command_plan *plan = malloc(sizeof *plan + length / 8);
    uint32_t *offsets = malloc(length / 8 * sizeof *offsets);
    if (!plan || !offsets) { free(plan); free(offsets); return NULL; }
    plan->bytes = bytes; plan->length = length; memset(plan->scan, -1, length / 8);
    size_t offset = 0, count = 0;
    while (offset < length) {
        op_hdr h; memcpy(&h, (const uint8_t *)bytes + offset, sizeof h);
        if (h.size < 8 || (h.size & 7) || h.size > length - offset || h.op >= OP_COUNT_ || (h.op == OP_BARRIER && h.size < 12)) {
            free(offsets); free(plan); return NULL;
        }
        offsets[count++] = (uint32_t)offset; offset += h.size;
    }
    int answer = 0; unsigned distance = 0;
    while (count) {
        offset = offsets[--count]; op_hdr h; memcpy(&h, (const uint8_t *)bytes + offset, sizeof h);
        int kind = nvn_csh_record_kind(h.op, (const uint8_t *)bytes + offset + 8, h.size - 8);
        if (kind == NVP_PASS) { if (distance < 4097) distance++; }
        else { distance = 1; answer = kind == NVP_DISPATCH ? 1 : kind == NVP_DYNAMIC ? -1 : 0; }
        // The normal prescan returns 1 when its 4096-op budget expires, rather than incorrectly ruling out a dispatch.
        plan->scan[offset / 8] = (int8_t)(answer < 0 ? -1 : distance > 4096 ? 1 : answer);
    }
    free(offsets); return plan;
}
static inline int nvn_command_plan_lookup(const nvn_command_plan *plan, const uint8_t *next, int return_depth) {
    if (!plan || return_depth) return -1;
    uintptr_t base = (uintptr_t)plan->bytes, p = (uintptr_t)next;
    if (p < base || p - base >= plan->length || ((p - base) & 7)) return -1;
    return plan->scan[(p - base) / 8];
}
