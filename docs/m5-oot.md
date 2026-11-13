# M5 Ocarina of Time maintenance

This fork develops Ocarina of Time (`0400486024DEC000`) on Apple M5 while retaining HDR, the game's original neural upscaler and image quality. It is based on [seedds/nxnative](https://github.com/seedds/nxnative); the MIT license and third-party notices are retained. Game files, keys, saves, extracted modules, translated game shaders and ROM-inclusive apps stay outside the repository.

## Branches and status

- `m5-oot` is the fork's development branch and default branch. The initial source snapshot is based on upstream `8b55ebb364821045ad16fe432166151357bcde10` plus the local HDR and M5 work. It includes disabled experiments so that their tests and findings remain reproducible.
- `main` is the upstream line, without the M5 changes. Fetch and review upstream changes before merging them into `m5-oot`; do not rebase away a published measurement's source revision.
- The last recommended local app remains **HDR Mesh Experimental**. This source snapshot also contains later fixes and opt-in experiments; a fresh build is not a byte-for-byte reproduction of that frozen app. It must earn a recommendation through another actual-app comparison.
- There is **no established stutter-free 60 fps release**. Source-only tags identify development snapshots, not game bundles or performance guarantees.

The validated machine is an M5 MacBook Pro with 32 GB, macOS 27.3 and Xcode 27.2. M5 Pro/Max, other Macs and iOS are not validated by these measurements. The game's [note](../dm/games/0400486024DEC000/README.md) owns the full findings and measurements; generic mechanisms are linked from there.

## Build the development baseline

Follow the upstream [requirements](../README.md#requirements) and [tool setup](../README.md#build-from-the-command-line), then use your own supported dump or NUP. The [preset](../scripts/presets/oot-m5-hdr.env) records the Mesh experiment's runtime settings, with the HUD and unselected experiments off. It does not change global defaults for other games or Apple devices.

```sh
python3 scripts/build_ipa_from_nsp.py /path/to/oot-dump \
  --title-id 0400486024DEC000 \
  --platform mac \
  --work-dir /path/to/oot-dump/0400486024DEC000_m5_build \
  --env-file scripts/presets/oot-m5-hdr.env
```

This makes the Mac host and shaders, then prints the run command; its save/temp folders are in that separate build's `run/`. Do not use the player's only save for a measurement: copy the save into the test folder first. See [Mac builds](development.md#a-mac-only-build-for-development) and [benchmarking](development.md#a-benchmark-on-the-mac).

For a self-contained app, follow [Mac app packing](development.md#a-mac-app). Use a new output name and bundle ID. The low-level `dm/mac/pack_app.py --data-id 0400486024DEC000-HDR-M5` also isolates Application Support and logs; the top-level build script does not yet expose this option. A different bundle ID by itself does not isolate saves. [Data IDs and front ends](frontends.md#saved-choices) describes the launcher contract. No existing app or save is replaced by setting up this fork.

The preset keeps docked mode, render scale 1 and dynamic resolution off. The measured game renders at 1536x864, reconstructs 2048x1152 and uses a 2560x1440 window surface on this Mac. HDR source encoding is PQ/BT.2020 at the same 203-nit reference with a requested 1,000-nit output peak; these are not physical panel measurements. `DM_HMMA_TENSOR=0` and `DM_UPSCALER=game` retain the original network. The mesh scratch path keeps a whole-draw native fallback when its capacity is insufficient; it does not truncate foliage.

## Performance acceptance

Keep the initial measurement limits explicit. Eleven two-minute screens and six complete ten-minute moving/turning runs were performed. The final actual-bundle comparison on November 13, 2026 gave:

| Actual app, 600 seconds | Frames / second | Display intervals over 25 ms | Discarded presents |
|---|---:|---:|---:|
| Existing HDR Mesh | 59.9917 | 7 | 1 |
| Schedule / presenter deadline | 59.9433 | 35 | 2 |

Both runs had nominal per-minute thermal readings, audio enabled, HUD disabled, unchanged image settings and no red errors. Their shader images, tables, rewritten modules and pipeline bundles were byte-identical. The promising earlier frozen-host result did not reproduce in the actual candidate app, so the Schedule app was not selected. This does not prove packaging caused the difference. The [complete game note](../dm/games/0400486024DEC000/README.md#submission-scheduling-experiments-m5-2026-11-13-measured-not-selected) records other controls, thermal variation and timing limitations.

Render-to-compute ordering (#2515), early first segments (#2526), a presenter's own deadline (#2484), queue-class preference, copied-command preparation and the Tensor/MetalFX alternatives remain experiments. Do not enable them in the baseline because a short run or an upstream result looks faster.

For every future performance candidate:

1. Preserve the current player app and save, and test with private copies. Change one mechanism at a time.
2. Verify HDR, resolution, network selection, actual draw counts and picture correctness. Do not substitute frame generation or quality cuts for native 60 fps.
3. Measure the **actual packaged app**, including ten complete minutes of a fixed moving/turning route. Exclude menus and diagnostic readbacks, retain every measured minute and thermal sample, and report discarded presents separately from long display intervals.
4. Keep CPU, GPU sums, overlapping GPU spans and on-screen cadence separate. Join asynchronous telemetry by frame before attribution. Unknown causes stay open.
5. Retain the tested source commit, chain stamp, exact settings and normalized results. Raw game data and trace captures stay in the game's work folder.

## Validation and upstream updates

The imported source passed the full local native graphics suite, including the GPU ordering/fence fixtures, and the original-network shader regression: 42,848/42,848 translated shaders, zero new failures and zero interface differences. The chain is `a8fb9b9875f5`; its changes relative to upstream are inherited from the earlier shader work. Only Ocarina's game files are available locally, so this is not five-game or iOS validation.

The development snapshot has a known LLVM nullable-argument ratchet excess in `nvn_mtl.m` (18 findings versus the upstream baseline's 15). It is documented rather than hidden by increasing the baseline. CI and broader-game status must be stated separately from the local gameplay measurements.

Fresh-clone maintenance starts with:

```sh
git remote add upstream https://github.com/seedds/nxnative.git
git fetch upstream
git switch m5-oot
git log --oneline HEAD..upstream/main
```

Review the diff and [front-end changes](frontends.md#following-main), merge selected upstream changes on a separate integration branch, then follow the [developer loop](agents/06-dev-loop.md). In particular, regenerate the chain and rebuild this game's shaders after changing any chain input; native graphics checks and `scripts/regress.py check --games` remain required. GitHub runners without Metal 4 cannot establish game performance; do not replace a local M5 comparison with a CI badge. Existing workflows are retained; no periodic update job is configured by this fork setup.
