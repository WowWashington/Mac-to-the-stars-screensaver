Build a continuous Jovian-moon expedition: approach Jupiter, travel past Europa's fractured ice, and witness an eclipse as the moon enters Jupiter's shadow. This is a follow-up to the Saturn/Enceladus expedition under local development on 2026-09-05.

The scene should tell a coherent story within a fixed 3D system: growing distant bodies, Jupiter's reflected light on ice, a grazing surface pass with fracture relief, and a gradual eclipse. Keep scale compression explicit in code comments. Avoid a sequence of disconnected full-screen planet swaps.

Implementation scope:

- Add one procedural scene with seeded camera route variants, Director scheduling, stage-specific HUD target names, and no new runtime dependencies.
- Use original procedural geometry and textures. Optional reference imagery must be verified through images.nasa.gov, with NASA ID and source-specific credits recorded. Code remains MIT; archive imagery retains separate terms.
- Share inexpensive sphere, ring-shadow and lighting helpers where appropriate after the Saturn expansion lands; preserve the 96-byte Swift/Metal uniform layout.
- Add harness frames for distant arrival, sunlit ice, eclipse ingress, totality, and departure; test at least two seeds and the scene crossfade.
- Render and inspect the actual PNGs; benchmark all relevant phases at QHD below 12 ms/frame, comparing unchanged scenes during GPU contention. Run the Director invariant checks. Install only after visual and performance checks.

Start by reading STATE.md and AGENTS.md. Coordinate with the current expansion before editing the monolithic shader.
