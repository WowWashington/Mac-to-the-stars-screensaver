# I asked Claude to build me a Mac screensaver. It built me a universe.

I've been a Windows guy forever — with plenty of *nix in the mix — but I
recently set up a Mac Mini Pro for one reason: to build with (and frankly,
abuse) Claude and other AI tools. So before pointing it at anything serious,
I wanted a calibration test. Something with real moving parts: native macOS
APIs, GPU code, system integration, the works.

The test: **"Build me a procedurally generated screensaver where I fly
through galaxies, past planets, with warp jumps between them. Then install
it."** No Xcode project, no starter template, no assets. Go.

What Claude's Fable model built — in one session — is honestly the coolest
screensaver I've ever run:

- An opening shot of the **Milky Way growing from a single pixel** (a real
  NASA archive image) that dissolves into a volumetric, ray-marched galactic
  disk as you fly in — complete with little solar systems drifting past,
  planets visibly orbiting their stars
- **Solar-system flybys**: up to five procedural planets per system — terran,
  gas giants with rings, lava worlds, ice worlds — lit by their actual sun,
  sometimes a binary pair
- **Warp jumps** between regions, Star Wars style, each arriving somewhere
  with a new color palette and new sights
- Rare encounters: **black holes** with gravitational lensing, comet swarms,
  and my favorite — **Dyson spheres in three construction stages**, including
  a complete one you fly *into* through an opening, skim over its
  inner-surface oceans and mountain ranges, and exit the far side
- An optional **starship HUD** — velocity, heading, sector names, a mission
  clock, amber warp telemetry — toggleable right from System Settings
- Real **NASA deep-field photographs** (properly credited, logo-free, with a
  provenance table, because we're sharing this under MIT)

Everything is generated live by a single Metal shader. No video files. No
two runs are ever the same.

The part that impressed me most wasn't the output — it was *watching it
work*. It built itself a test harness that renders frames to PNG, **looked
at its own screenshots**, and iterated: "nebula's too foggy," "rings are
blown out," fix, re-render, check again. When I reported that stars were
flying the wrong direction, it found a sign error in the projection math,
explained why the bug *looked* plausible, and fixed it everywhere it
appeared. When frames got expensive, it benchmarked the GPU per-scene and
optimized until everything fit a 60fps budget. It even caught that my second
monitor was silently falling back to a built-in saver because macOS had
rewritten a config entry — and wrote a script so that can never happen again.

Is there fit and finish left? Sure. But right now it's fully running on both
screens, HUD on or off, planets sliding by, warp tunnels lighting up the
office — and the whole thing cost me about **90% of one 5-hour plan window**.
A native macOS screensaver, from empty folder to installed-and-running, with
documentation good enough that I can hand future features to a cheaper model.

For a lifelong Windows/*nix person who bought a Mac just to stress-test AI:
test passed.

The code is up on GitHub under MIT — clone it, run one command, and fly:

**https://github.com/WowWashington/Mac-to-the-stars-screensaver**

![Galaxy approach](https://raw.githubusercontent.com/WowWashington/Mac-to-the-stars-screensaver/main/docs/img/29_galaxy_photo_mid.png)

![Dyson ring](https://raw.githubusercontent.com/WowWashington/Mac-to-the-stars-screensaver/main/docs/img/23_dyson_ring.png)

*Built with Claude (Fable 5) on a Mac Mini Pro. Images courtesy NASA —
no endorsement implied.*
