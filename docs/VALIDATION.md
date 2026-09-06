# Expansion validation — 2026-09-05

Final local validation at 2560 × 1440. Each benchmark uses 5 warm-up frames and
40 measured GPU frames. These are sampled scene phases, not an exhaustive worst-case
proof across every random seed or a guarantee under simultaneous GPU load.

The source builds as a universal arm64/x86_64 screensaver. All new scene phases,
NASA images, representative existing scenes, and transitions were rendered and
visually inspected in Preview/. The uniform ABI remains 96 bytes.

| Scene / phase | GPU ms/frame |
|---|---:|
| cruise | 7.02 |
| galaxy_mid | 5.90 |
| galaxy_entry | 8.58 |
| system_rings | 4.54 |
| warp | 1.31 |
| blackhole | 8.21 |
| dyson_ring | 2.77 |
| dyson_interior | 9.76 |
| dyson_swarm | 2.84 |
| comets | 5.52 |
| pulsar | 5.81 |
| asteroid | 3.40 |
| home_earth | 3.92 |
| home_saturn | 2.61 |
| horizon_close | 5.64 |
| rings_saturn | 2.97 |
| rings_plane | 3.37 |
| rings_enceladus | 6.05 |
| nursery_pillars | 3.14 |
| nursery_close | 6.50 |
| dyson_architecture | 8.98 |
| expedition_transition | 5.17 |
| transition_worstcase | 6.11 |

Every measured phase is under the 12 ms per-scene budget. The renderer now
prebuilds 28 specialized pipelines (scene / encounter subtype × direct / HDR)
and blends transitions in one RGBA16Float target before tonemapping. All rendering
in this benchmark uses the full QHD resolution, without per-scene downsampling.

## Regression checks

- Director: 8,192 seeded scenes and 106,560 sampled frames, with and without images.
  Checks coverage, timeline continuity, sleep recovery, HUD routing and one-image-slot compatibility.
- Renderer: 15 routes compared directly against an unequal HDR self-crossfade.
  Mean differences are ≤0.069 byte/channel. All but the galaxy route stay within
  3 bytes; the galaxy has sparse procedural-boundary outliers (0.17% of RGB channels
  exceed 4 bytes, maximum 24). Separate fast-math specializations can perturb
  hash-based volume jitter. Tests enforce mean ≤0.2 and ≥99.8% of channels within 4.
- Both actual crossfade endpoints match standalone rendering exactly.
- All command buffers completed without GPU errors.

Reproduce with `./build.sh preview`, then
`./build/preview Preview --bench --verify-renderer`; see README for the CPU checks.

Installation completed: installed executable hash matches the verified universal build,
21 images bundled, both Idle selections verified with NeptuneOneExtension.
