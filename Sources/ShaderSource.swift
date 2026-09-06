// Metal shader source, compiled at runtime via MTLDevice.makeLibrary(source:).
// Keeping it as a string avoids needing the Xcode metal toolchain to build.

let spaceShaderSource = #"""
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4 scnA;        // current scene:  x=seed y=subtype z=flags w=duration
    float4 scnB;        // previous scene
    float4 palA;        // current palette: x=baseHue y=accentHue z=nebulaAmt w=starTint
    float4 palB;        // previous palette
    float2 resolution;
    float  time;        // global animation time
    float  sceneTime;   // time within current scene
    float  prevSceneTime;
    float  transition;  // 0..1 crossfade, 1 = fully current scene
    int    sceneType;   // 0 cruise, 1 galaxy, 2 planet, 3 warp
    int    prevSceneType;
};

struct VOut {
    float4 pos [[position]];
    float2 uv;
};

vertex VOut vmain(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = p;
    return o;
}

// ---------- hashing & noise ----------

float hash11(float p) {
    p = fract(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return fract(p);
}

float hash21(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float2 hash22(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

float hash31(float3 p3) {
    p3 = fract(p3 * 0.1031);
    p3 += dot(p3, p3.zyx + 31.32);
    return fract((p3.x + p3.y) * p3.z);
}

float noise3(float3 x) {
    float3 i = floor(x);
    float3 f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    float n000 = hash31(i + float3(0,0,0));
    float n100 = hash31(i + float3(1,0,0));
    float n010 = hash31(i + float3(0,1,0));
    float n110 = hash31(i + float3(1,1,0));
    float n001 = hash31(i + float3(0,0,1));
    float n101 = hash31(i + float3(1,0,1));
    float n011 = hash31(i + float3(0,1,1));
    float n111 = hash31(i + float3(1,1,1));
    return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
               mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}

float fbm(float3 p, int oct) {
    float v = 0.0;
    float a = 0.5;
    float tot = 0.0;
    for (int i = 0; i < oct; i++) {
        v += a * noise3(p);
        tot += a;
        p = p * 2.07 + float3(13.7, 7.3, 5.1);
        a *= 0.5;
    }
    return v / max(tot, 1e-4);
}

float ridged(float3 p, int oct) {
    float v = 0.0;
    float a = 0.5;
    float tot = 0.0;
    for (int i = 0; i < oct; i++) {
        float n = 1.0 - abs(2.0 * noise3(p) - 1.0);
        v += a * n * n;
        tot += a;
        p = p * 2.13 + float3(3.1, 9.7, 1.3);
        a *= 0.5;
    }
    return v / max(tot, 1e-4);
}

float2x2 rot2(float a) {
    float c = cos(a), s = sin(a);
    return float2x2(float2(c, s), float2(-s, c));
}

// ---------- palette ----------

float3 hue3(float h) {
    return 0.5 + 0.5 * cos(6.28318 * (h + float3(0.0, 0.33, 0.67)));
}

float3 tint(float h, float s) {
    float3 c = hue3(h);
    float l = dot(c, float3(0.299, 0.587, 0.114));
    return mix(float3(l), c, s);
}

// star color by "temperature" hash: blue-white .. white .. orange
float3 starTemp(float h) {
    if (h < 0.33) return mix(float3(0.65, 0.75, 1.0), float3(1.0), h * 3.0);
    if (h < 0.75) return float3(1.0);
    return mix(float3(1.0), float3(1.0, 0.72, 0.45), (h - 0.75) * 4.0);
}

// ---------- building blocks ----------

float3 nebula(float2 uv, float seed, float4 pal, float t) {
    float3 p = float3(uv * 1.6, seed * 7.31);
    float n1 = fbm(p * 2.0 + float3(t * 0.004, 0.0, 0.0), 3);
    float n2 = fbm(p * 4.3 - float3(0.0, t * 0.003, t * 0.002), 3);
    float3 c1 = tint(pal.x, 0.75);
    float3 c2 = tint(pal.y, 0.8);
    float3 col = c1 * pow(n1, 3.2) * 0.34 + c2 * pow(n2, 4.0) * 0.26;
    // sparse dark dust silhouettes
    float dust = smoothstep(0.55, 0.85, fbm(p * 3.1 + 11.0, 3));
    col *= (1.0 - 0.5 * dust);
    return col * pal.z;
}

float3 starLayer(float2 uv, float density, float seed, float t) {
    float2 id = floor(uv);
    float2 f = uv - id;
    float3 col = float3(0.0);
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float2 o = float2(i, j);
            float2 cid = id + o;
            float2 rnd = hash22(cid * 1.13 + seed * 19.19);
            if (rnd.x > density) continue;
            float2 d2 = o + rnd.yx * 0.9 + 0.05 - f;
            float d = length(d2);
            float h = hash21(cid + seed * 0.731);
            float sz = mix(26.0, 9.0, h * h);          // most stars tiny
            float bright = 0.35 + 1.3 * h * h * h;
            float tw = 0.8 + 0.2 * sin(t * (1.0 + 3.0 * h) + h * 41.0);
            float core = exp(-d * d * sz * sz * 14.0);
            float glow = exp(-d * 5.0) * 0.045 * bright;
            col += starTemp(fract(h * 7.77)) * (core * bright * tw + glow);
        }
    }
    return col;
}

// single-cell starfield: ~9x cheaper than starLayer; stars are kept small and
// centered so nothing visibly clips at cell borders. For dense fly-through layers.
float3 starLayerFast(float2 uv, float density, float seed, float t) {
    float2 id = floor(uv);
    float2 f = uv - id;
    float2 rnd = hash22(id * 1.13 + seed * 19.19);
    if (rnd.x > density) return float3(0.0);
    float2 d2 = rnd.yx * 0.5 + 0.25 - f;
    float d = length(d2);
    float h = hash21(id + seed * 0.731);
    float sz = mix(26.0, 11.0, h * h);
    float bright = 0.35 + 1.2 * h * h * h;
    float tw = 0.8 + 0.2 * sin(t * (1.0 + 3.0 * h) + h * 41.0);
    float core = exp(-d * d * sz * sz * 14.0);
    float border = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y));
    float glow = exp(-d * 9.0) * 0.05 * bright * smoothstep(0.0, 0.16, border);
    return starTemp(fract(h * 7.77)) * (core * bright * tw + glow);
}

// a tiny resolved solar system: star + faint disc + orbiting planet specks.
// p in local coords, star at origin, visible radius ~0.3
float3 miniSystem(float2 p, float h, float gt) {
    float3 sc = starTemp(fract(h * 9.1));
    float d = length(p);
    float3 col = sc * (exp(-d * d * 900.0) * 2.2 + exp(-d * 14.0) * 0.25);
    // inclined system plane
    float squash = mix(0.25, 0.6, fract(h * 5.3));
    float2 e = rot2(h * 6.28318) * p;
    e.y /= squash;
    float er = length(e);
    // faint protoplanetary disc
    float ring = exp(-pow((er - 0.16) * 60.0, 2.0));
    col += sc * ring * 0.08;
    // planets crawling along their orbits
    for (int k = 0; k < 2; k++) {
        float fk = float(k);
        if (k == 1 && fract(h * 11.7) < 0.45) break;   // some systems have one
        float orad = 0.10 + 0.10 * fk + 0.05 * fract(h * 7.7 + fk * 3.1);
        float ang = gt * (0.22 - 0.07 * fk) * (h > 0.5 ? 1.0 : -1.0) + h * 40.0 + fk * 2.4;
        float2 pp = float2(cos(ang), sin(ang)) * orad;
        float dd = length(e - pp);
        col += mix(float3(0.7, 0.8, 1.0), float3(1.0, 0.85, 0.6), fract(h * 13.3))
             * exp(-dd * dd * 5000.0) * 0.85;
    }
    return col;
}

// sparse field of mini systems (for flying through a galactic disk).
// single-cell: sprites are sized to fit one cell, so no neighbor scan needed.
float3 systemLayer(float2 uv, float seed, float gt, float density) {
    float2 id = floor(uv);
    float2 f = uv - id;
    float2 rnd = hash22(id * 2.17 + seed * 31.0);
    if (rnd.x > density) return float3(0.0);
    float2 p = f - (0.3 + rnd.yx * 0.4);
    float h = hash21(id * 1.71 + seed);
    float s = mix(1.3, 2.2, fract(h * 3.3));   // size variety
    float border = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y));
    return miniSystem(p * s, h, gt) * smoothstep(0.0, 0.12, border) / (0.9 + s * 0.35);
}

// procedural spiral galaxy, q in galaxy-plane coords (radius ~1)
float3 galaxyColor(float2 q, float seed, float4 pal, float t) {
    float r = length(q);
    float ang = atan2(q.y, q.x);
    float arms = 2.0 + floor(hash11(seed * 2.3) * 3.0);
    float wind = mix(2.6, 5.2, hash11(seed * 4.9));
    float dir = hash11(seed * 8.8) > 0.5 ? 1.0 : -1.0;
    float ph = ang * arms - dir * wind * log(r + 0.05) + t * 0.012 * dir;
    float arm = pow(0.5 + 0.5 * cos(ph), mix(1.6, 3.4, hash11(seed * 6.1)));
    float disk = exp(-r * 2.1);
    float dust = fbm(float3(q * 5.2, seed * 9.7), 5);
    float lanes = ridged(float3(q * 4.6 + 0.13, seed * 3.3), 4);
    float density = disk * (0.20 + arm * (0.35 + 0.9 * dust));
    density *= 1.0 - 0.7 * smoothstep(0.40, 0.75, lanes) * smoothstep(0.95, 0.15, r) * arm;

    float3 armCol = tint(pal.y, 0.55) * float3(0.85, 0.92, 1.12);
    float3 coreCol = float3(1.0, 0.85, 0.62);
    float3 col = density * mix(coreCol, armCol, smoothstep(0.05, 0.45, r)) * 1.25;
    col += coreCol * exp(-r * r * 34.0) * 1.3;
    col += coreCol * exp(-r * 5.0) * 0.22;
    // pink HII star-forming regions along arms
    float h2 = pow(fbm(float3(q * 6.3, seed * 13.0), 3), 6.0) * arm * disk;
    col += float3(1.0, 0.42, 0.58) * h2 * 4.0;
    // resolved star speckle
    col += starLayer(q * 24.0 + seed * 7.0, 0.12, seed * 17.0, t) * density * 2.4;
    col *= smoothstep(2.3, 1.1, r);
    return col;
}

// ---------- volumetric galaxy (true 3D depth for close approach) ----------

// density of the galactic disk at point p (galaxy frame: disk in xz, radius ~1.4)
float galaxyDensity3D(float3 p, float seed, float arms, float wind, float dir, float armK) {
    float r = length(p.xz);
    if (r > 2.3) return 0.0;
    float disk = exp(-r * 2.1);
    // disk thickness exaggerated for visual body, fat central bulge
    float h = 0.11 + 0.32 * exp(-r * r * 7.0);
    float vert = exp(-abs(p.y) / max(h, 1e-3) * 1.7);
    float base = disk * vert;
    if (base < 0.010) return 0.0;          // empty space: skip the noise
    float ang = atan2(p.z, p.x);
    float ph = ang * arms - dir * wind * log(r + 0.05);
    float arm = pow(0.5 + 0.5 * cos(ph), armK);
    // the log-spiral term oscillates wildly near the core: fade arms into a
    // smooth bulge there or the center renders as concentric stripes
    arm = mix(0.55, arm, smoothstep(0.12, 0.45, r));
    float dust = fbm(p * float3(3.4, 9.0, 3.4) + seed * 9.7, 2);
    return base * (0.10 + arm * (0.25 + 1.1 * dust));
}

// march through the disk: emission + absorption = parallax, depth, dust silhouettes
float3 galaxyVolume(float3 gro, float3 grd, float seed, float4 pal, float gt) {
    float arms = 2.0 + floor(hash11(seed * 2.3) * 3.0);
    float wind = mix(2.6, 5.2, hash11(seed * 4.9));
    float dir = hash11(seed * 8.8) > 0.5 ? 1.0 : -1.0;
    float armK = mix(1.6, 3.4, hash11(seed * 6.1));

    // clip the march to the disk slab |y| <= 0.6
    float t0 = 0.0, t1 = 4.0;
    if (abs(grd.y) > 1e-4) {
        float ta = (-0.6 - gro.y) / grd.y;
        float tb = ( 0.6 - gro.y) / grd.y;
        t0 = max(min(ta, tb), 0.0);
        t1 = min(max(ta, tb), t0 + 4.0);
    }
    if (t1 <= t0) return float3(0.0);

    float3 armCol = tint(pal.y, 0.55) * float3(0.85, 0.92, 1.12);
    float3 coreCol = float3(1.0, 0.85, 0.62);
    float ds = (t1 - t0) / 12.0;
    float3 acc = float3(0.0);
    float T = 1.0;
    float jit = hash21(grd.xy * 731.7 + seed) * ds;   // dither against banding
    for (int i = 0; i < 12; i++) {
        float tt = t0 + (float(i) + 0.5) * ds + jit;
        float3 p = gro + grd * tt;
        float dens = galaxyDensity3D(p, seed, arms, wind, dir, armK);
        if (dens < 0.004) continue;
        float r = length(p.xz);
        float3 c = mix(coreCol, armCol, smoothstep(0.05, 0.5, r));
        c += coreCol * exp(-r * r * 14.0) * 1.1;          // glowing bulge
        c += float3(1.0, 0.42, 0.58) * smoothstep(0.55, 0.8, dens) * 0.7;  // HII knots
        acc += T * c * dens * ds * 6.5;
        T *= exp(-dens * ds * 9.5);
        if (T < 0.02) break;
    }
    return acc;
}

float3 spaceBG(float2 uv, float seed, float4 pal, float t, float nebAmt) {
    float3 col = float3(0.004, 0.005, 0.010);
    col += nebula(uv + hash11(seed * 3.3) * 4.0, seed, pal, t) * nebAmt;
    col += starLayerFast(uv * 13.0 + seed * 37.0, 0.10, seed + 3.0, t) * 0.85;
    col += starLayerFast(uv * 29.0 + seed * 53.0, 0.16, seed + 9.0, t) * 0.45;
    return col;
}

// ---------- scene 0: starfield cruise ----------

float3 cruiseScene(float2 uv, float t, float4 scn, float4 pal, float gt) {
    float seed = scn.x;
    float speed = scn.y;                       // ~0.7..1.4
    // gentle drift + roll so the camera feels alive
    uv = rot2(0.05 * sin(gt * 0.031) + gt * 0.004) * uv;
    uv += 0.05 * float2(sin(gt * 0.071), cos(gt * 0.053));

    float3 col = spaceBG(uv * 0.7, seed, pal, gt, 0.5);

    // fly-through star layers expanding outward
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        float ph = fract(fi / 6.0 - t * 0.045 * speed + hash11(seed + fi) * 0.9);
        float depth = 0.05 + 0.95 * ph;        // 1 = far, ->0 = passing camera
        // q = uv * depth: as depth shrinks the pattern magnifies, so stars
        // stream OUTWARD past the camera (toward us), never inward
        float2 q = uv * depth * 6.0;
        q += (hash22(float2(fi * 3.1, seed * 11.0)) - 0.5) * 9.0;
        float fade = smoothstep(1.0, 0.8, ph) * smoothstep(0.0, 0.10, ph);
        float bright = mix(1.6, 0.35, ph);
        col += starLayerFast(q, 0.10, seed * 5.0 + fi * 13.0, gt) * fade * bright * 0.55;
    }

    // hero star: a bright sun drifting past every ~14s
    float ep = floor(t / 14.0);
    float2 he = hash22(float2(ep * 3.7, seed * 23.0));
    float frt = fract(t / 14.0);
    if (he.x > 0.30) {
        float2 hp = (he - 0.5) * 1.3;
        hp *= 1.0 + frt * 0.85;                // drifts outward as we pass
        float env = sin(3.14159 * frt);
        float2 dv = uv - hp;
        float d = length(dv);
        float3 sc = starTemp(fract(he.y * 5.3));
        float spikes = pow(max(0.0, 1.0 - abs(dv.x) * 40.0), 3.0) + pow(max(0.0, 1.0 - abs(dv.y) * 40.0), 3.0);
        col += sc * env * (exp(-d * d * 2200.0) * 2.6 + exp(-d * 26.0) * 0.35 + spikes * exp(-d * 9.0) * 0.30);
    }

    // occasional distant galaxy drifting by
    float ge = floor(t / 23.0);
    float2 gh = hash22(float2(ge * 7.1, seed * 31.0));
    if (gh.x > 0.45) {
        float gfr = fract(t / 23.0);
        float genv = sin(3.14159 * gfr);
        float2 gp = (gh - 0.5) * 1.1 * (1.0 + gfr * 0.5);
        float2 gq = rot2(gh.y * 6.28) * (uv - gp);
        gq.y *= 2.2;                            // inclined
        col += galaxyColor(gq * 9.0, seed * 3.0 + ge, pal, gt) * 0.16 * genv;
    }
    return col;
}

// ---------- scene 1: galaxy approach & entry ----------

float3 galaxyScene(float2 uv, float t, float4 scn, float4 pal, float gt,
                   texture2d<float> img) {
    constexpr sampler gsmp(filter::linear, address::clamp_to_edge);
    float seed = scn.x;
    bool hasImg = scn.y > 0.5;          // scn.y = image index + 1, scn.z = aspect
    float dur = max(scn.w, 1.0);
    float prog = clamp(t / dur, 0.0, 1.0);
    float ease = smoothstep(0.0, 1.0, prog);

    uv = rot2(gt * 0.006 + 0.04 * sin(gt * 0.027)) * uv;
    float3 col = spaceBG(uv * 0.8 + 3.0, seed + 0.5, pal, gt, hasImg ? 0.22 : 0.32);

    // approach: galaxy grows; we aim toward an arm, not the core
    float zoom = mix(0.10, 4.2, pow(ease, 2.2));   // grows from a distant dot
    float2 center = mix(float2(0.0), float2(0.95, 0.30), ease);
    float enter = smoothstep(0.55, 0.95, prog);
    // flat sprite/photo carries the FAR view (flat is correct at distance);
    // the volumetric march takes over behind a brief dust-veil handoff
    float vw = smoothstep(0.42, 0.50, prog);
    if (enter < 0.92 && vw < 0.93) {
        float2 q = rot2(seed * 6.28 + gt * 0.005) * uv;
        float incl = mix(0.42, 0.95, hash11(seed * 5.1));
        q.y /= incl;
        q = q / zoom * 2.0 + center;
        float fadeIn = 1.0 - 0.9 * smoothstep(0.55, 0.92, enter);
        float procW = 1.0;
        if (hasImg) {
            // real archive photograph carries the approach, then hands off
            // to the procedural disk as we close in
            float a = max(scn.z, 0.1);
            float2 iuv = float2(q.x / a, -q.y) / 3.4 + 0.5;
            // shadow floor before gamma expansion: JPEG dark noise otherwise
            // crushes into black speckles across the disk
            float3 ic = pow(max(img.sample(gsmp, iuv).rgb, float3(0.02)), float3(2.2)) - 0.0004;
            float mask = smoothstep(1.70, 1.30, length(q));
            float photoW = 1.0 - smoothstep(0.30, 0.58, prog);
            col += ic * mask * photoW * 1.7 * (1.0 - vw);
            procW = smoothstep(0.24, 0.55, prog);
        }
        col += galaxyColor(q, seed, pal, gt) * procW * fadeIn * (1.0 - vw);
    }
    // true 3D: ray-march the disk while descending into it — arms slide past
    // each other, the bulge rises over the plane, dust silhouettes in depth
    // dust veil: we punch through the galaxy's outer halo right as the
    // representation switches — covers the sprite->volume handoff
    float veil = smoothstep(0.38, 0.46, prog) * smoothstep(0.58, 0.50, prog);
    if (veil > 0.003) {
        float vfbm = fbm(float3(uv * 2.6, seed * 6.0 + gt * 0.06), 3);
        col += tint(pal.y, 0.55) * veil * (0.25 + 0.85 * vfbm);
    }
    if (vw > 0.003) {
        float vp = smoothstep(0.42, 1.0, prog);
        // start far enough that the volume's apparent size matches the sprite
        float3 cam = mix(float3(3.9, 2.4, -2.0), float3(0.85, 0.05, 0.25),
                         smoothstep(0.0, 1.0, vp));
        float3 tgt = mix(float3(0.0), float3(0.2, 0.0, 0.9), vp);
        float3 fwd = normalize(tgt - cam);
        float3 rightv = normalize(cross(fwd, float3(0.0, 1.0, 0.0)));
        float3 upv = cross(rightv, fwd);
        // keep the volume on the sprite's screen position during the handoff
        float2 uv0 = -center * zoom * 0.5 * (1.0 - vp);
        float2 uvv = uv - uv0;
        float3 grd = normalize(rightv * uvv.x + upv * uvv.y + fwd * 1.45);
        col += galaxyVolume(cam, grd, seed, pal, gt) * vw;
    }
    // foreground stars counter-drifting against the galaxy: parallax depth cue
    float2 par = uv * 7.0 - center * 2.4 + seed * 11.0;
    col += starLayerFast(par, 0.10, seed * 4.7, gt) * 0.7 * (1.0 - enter);

    // entering the disk: dust fog + local stars thicken, and the dust resolves
    // into a populated stellar neighborhood
    if (enter > 0.003) {
        float fog = fbm(float3(uv * 2.4, seed * 4.4 + gt * 0.01), 3);
        float wisp = fbm(float3(uv * 6.5 + 7.0, seed * 8.8 + gt * 0.015), 2);
        float lane = ridged(float3(uv * 3.4, seed * 6.2), 2);
        float3 fogCol = tint(pal.y, 0.6) * pow(fog, 2.0) * pow(wisp, 1.6) * 0.8;
        fogCol *= 1.0 - 0.75 * smoothstep(0.45, 0.8, lane);
        col += fogCol * enter;
        for (int i = 0; i < 4; i++) {
            float fi = float(i);
            float ph = fract(fi / 4.0 - t * 0.05 + hash11(seed * 2.0 + fi));
            float depth = 0.06 + 0.94 * ph;
            float2 sq = uv * depth * 5.0 + (hash22(float2(fi, seed * 7.0)) - 0.5) * 8.0;
            float fade = smoothstep(1.0, 0.8, ph) * smoothstep(0.0, 0.12, ph);
            col += starLayerFast(sq * 1.8, 0.20, seed * 9.0 + fi * 5.0, gt) * fade * enter;
        }
        // resolved solar systems: born sub-pixel at max depth, growing
        // continuously until they sweep past the camera — never popping in
        for (int i = 0; i < 3; i++) {
            float fi = float(i);
            float ph = fract(fi / 3.0 - t * 0.035 + hash11(seed * 5.0 + fi) * 0.9);
            float depth = 0.10 + 0.90 * ph;
            float2 q = uv * depth * 5.5 + (hash22(float2(fi * 9.1, seed * 13.0)) - 0.5) * 7.0;
            float fade = smoothstep(1.0, 0.85, ph) * smoothstep(0.0, 0.05, ph);
            col += systemLayer(q, seed + fi * 7.0, gt, 0.30) * fade * enter * mix(1.8, 0.55, ph);
        }
    }
    return col;
}

// ---------- scene 2: planet flyby ----------

float3 shadePlanet(float3 ns, float lat, float lon, int ptype, float seed, float4 pal, float gt,
                   thread float3 &emissive, thread float &oceanMask) {
    float3 col;
    emissive = float3(0.0);
    oceanMask = 0.0;
    if (ptype == 0) {
        // terran
        float h = fbm(ns * mix(2.4, 4.2, hash11(seed * 3.1)) + seed * 11.0, 6);
        float sea = mix(0.42, 0.55, hash11(seed * 7.7));
        float land = smoothstep(sea - 0.02, sea + 0.02, h);
        float3 ocean = mix(float3(0.02, 0.07, 0.22), float3(0.05, 0.22, 0.38),
                           smoothstep(sea - 0.18, sea, h));
        float3 low = mix(float3(0.10, 0.30, 0.10), float3(0.45, 0.38, 0.22), smoothstep(sea, sea + 0.22, h));
        float3 ground = mix(low, float3(0.55, 0.52, 0.48), smoothstep(sea + 0.22, sea + 0.34, h));
        col = mix(ocean, ground, land);
        oceanMask = 1.0 - land;
        // polar caps
        float cap = smoothstep(0.72, 0.85, abs(lat) + 0.12 * fbm(ns * 5.0 + 31.0, 3));
        col = mix(col, float3(0.92, 0.95, 1.0), cap);
        // clouds
        float cl = smoothstep(0.52, 0.74, fbm(ns * 3.6 + float3(gt * 0.012, 0.0, gt * 0.004) + seed * 5.0, 4));
        col = mix(col, float3(1.0), cl * 0.85);
        oceanMask *= (1.0 - cl);
    } else if (ptype == 1) {
        // gas giant: turbulent latitude bands
        float turb = fbm(ns * 3.0 + float3(gt * 0.008, 0.0, 0.0) + seed * 9.0, 5);
        float band = sin(lat * mix(9.0, 16.0, hash11(seed * 2.9)) + turb * 3.5 + seed * 6.0);
        float band2 = sin(lat * 5.0 - turb * 2.0 + seed * 13.0);
        float3 c1 = tint(pal.x + 0.06, 0.45) * 0.9;
        float3 c2 = tint(pal.x - 0.04, 0.35) * 1.1;
        float3 c3 = tint(pal.y, 0.5);
        col = mix(c1, c2, 0.5 + 0.5 * band);
        col = mix(col, c3, (0.5 + 0.5 * band2) * 0.35);
        col *= 0.85 + 0.3 * turb;
        // great storm spot
        float slat = (hash11(seed * 4.4) - 0.5) * 1.2;
        float slon = hash11(seed * 6.6) * 6.28;
        float2 sd = float2((lat - slat) * 2.6, sin(lon - slon - gt * 0.01) * cos(lat) * 1.4);
        float spot = exp(-dot(sd, sd) * 14.0);
        col = mix(col, tint(pal.y + 0.5, 0.6) * 1.15, spot * 0.8);
    } else if (ptype == 2) {
        // lava world
        float rock = fbm(ns * 4.0 + seed * 7.0, 4);
        float cracks = ridged(ns * mix(3.0, 5.0, hash11(seed * 8.1)) + seed * 3.0, 5);
        col = mix(float3(0.05, 0.04, 0.04), float3(0.16, 0.12, 0.10), rock);
        float glow = pow(cracks, 4.0);
        float pulse = 0.85 + 0.15 * sin(gt * 0.7 + cracks * 9.0);
        emissive = float3(1.0, 0.32, 0.05) * glow * 2.4 * pulse;
    } else {
        // ice world
        float n = fbm(ns * 3.4 + seed * 5.0, 4);
        float cr = ridged(ns * 6.0 + seed * 9.0, 3);
        col = mix(float3(0.55, 0.68, 0.80), float3(0.72, 0.80, 0.90), n);
        col *= 1.0 - 0.4 * smoothstep(0.55, 0.85, cr);   // dark crack lines
        float cap = smoothstep(0.5, 0.8, abs(lat));
        col = mix(col, float3(0.95, 0.97, 1.0), cap * 0.5);
    }
    return col;
}

float3 atmoColorFor(int ptype, float4 pal) {
    return (ptype == 1) ? tint(pal.x, 0.5) :
           (ptype == 2) ? float3(1.0, 0.45, 0.2) :
           (ptype == 3) ? float3(0.6, 0.8, 1.0) : float3(0.45, 0.65, 1.0);
}

// planet i of the system: position along the flight path, size, type.
// i == 2 is the "hero" — close flyby, type/rings taken from scene params.
// sunPhi: heading of the sun, so the hero sits sunward and shows a lit face.
void sysPlanet(int i, float seed, float L, float heroType, float heroRings, float sunPhi,
               thread float3 &C, thread float &R, thread int &ptype, thread bool &rings) {
    float fi = float(i);
    float h1 = hash11(seed * 3.7 + fi * 17.1);
    float h2 = hash11(seed * 5.3 + fi * 9.7);
    float h3 = hash11(seed * 7.9 + fi * 5.3);
    float z = L * (0.28 + 0.13 * fi + (h1 - 0.5) * 0.05);
    R = mix(0.55, 1.5, h2);
    float lat;
    float phi;
    if (i == 2) {
        lat = R * 1.4 + mix(0.8, 1.3, h1);
        phi = sunPhi + (h3 - 0.5) * 1.3;      // sunward side of the path
        ptype = int(heroType + 0.5);
        rings = heroRings > 0.5;
    } else {
        lat = mix(5.0, 11.0, h1);
        phi = fi * 2.39996 + (h3 - 0.5) * 0.9; // golden-angle spread, no clumping
        ptype = int(floor(hash11(seed * 9.1 + fi * 3.3) * 3.999));
        rings = false;
    }
    C = float3(cos(phi) * lat, sin(phi) * lat * 0.45, z);
}

float3 sunGlow(float3 ro, float3 rd, float3 sp, float Rs, float3 scol,
               float occT, float gt, float seed) {
    float3 w = sp - ro;
    float sd = length(w);
    float3 sdir = w / sd;
    float ca = dot(rd, sdir);
    if (ca < 0.0) return float3(0.0);
    float dca = length(cross(rd, w));
    if (occT < sd - Rs) return float3(0.0);   // a planet surface blocks it
    float3 c = float3(0.0);
    float feather = sd * 0.002 + 0.01;
    float disc = smoothstep(Rs + feather, Rs - feather, dca);
    float limb = smoothstep(Rs, 0.0, dca);     // limb darkening
    c += scol * disc * (1.5 + 1.2 * limb);
    float3 perp = rd - ca * sdir;
    float angc = atan2(perp.y, perp.x);
    float fl = fbm(float3(cos(angc), sin(angc), gt * 0.10 + seed), 3);
    c += scol * exp(-max(dca - Rs, 0.0) * (2.2 / Rs)) * (0.35 + 0.5 * fl) * 0.7 * step(Rs, dca);
    c += scol * exp(-max(dca - Rs, 0.0) * (0.8 / Rs)) * 0.05;
    return c;
}

// Scene 2: fly INTO a solar system — suns and planets are fixed bodies along
// the flight path; everything grows from a dot, lighting is truly positional.
float3 planetScene(float2 uv, float t, float4 scn, float4 pal, float gt) {
    float seed = scn.x;
    float dur = max(scn.w, 1.0);

    // camera: steady cruise with a gentle weave between the bodies
    float v = 1.05;
    float3 ro = float3(0.30 * sin(t * 0.10 + seed),
                       0.16 * sin(t * 0.073 + seed * 2.0),
                       t * v);
    float3 rd = normalize(float3(uv, 1.45));
    float2 rxy = rot2(0.05 * sin(gt * 0.043) + gt * 0.003) * rd.xy;
    rd.x = rxy.x; rd.y = rxy.y;

    float L = dur * v;

    // sun, or occasionally a binary pair in a slow mutual orbit
    bool binary = hash11(seed * 15.4) < 0.28;
    float sunSide = hash11(seed * 8.1) > 0.5 ? 1.0 : -1.0;
    float3 sunC = float3(sunSide * mix(7.0, 13.0, hash11(seed * 8.1)),
                         (hash11(seed * 9.7) - 0.5) * 4.5,
                         L * mix(1.15, 1.45, hash11(seed * 4.2)));   // beyond the flight path: grows all scene, never blows out
    float Rs = mix(1.5, 2.4, hash11(seed * 6.6));
    float3 sunCol = starTemp(hash11(seed * 33.0) * 0.85);
    float3 sun2C = sunC;
    float Rs2 = 0.0;
    float3 sun2Col = sunCol;
    if (binary) {
        float oa = gt * 0.06 + seed * 3.0;
        float3 off = float3(cos(oa), 0.25 * sin(oa * 0.9), sin(oa)) * Rs * 2.8;
        sun2C = sunC + off * 0.6;
        sunC -= off * 0.4;
        Rs2 = Rs * mix(0.45, 0.75, hash11(seed * 7.3));
        sun2Col = starTemp(fract(hash11(seed * 33.0) * 0.85 + 0.5));
    }

    float sunPhi = atan2(sunC.y, sunC.x);
    float3 col = spaceBG(uv + seed, seed + 2.0, pal, gt, 0.4);

    // nearest planet hit
    float bestT = 1e9;
    int bestI = -1;
    for (int i = 0; i < 5; i++) {
        float3 C; float R; int pt; bool rg;
        sysPlanet(i, seed, L, scn.y, scn.z, sunPhi, C, R, pt, rg);
        float3 oc = ro - C;
        float b = dot(oc, rd);
        float h2 = b * b - (dot(oc, oc) - R * R);
        if (h2 > 0.0) {
            float tH = -b - sqrt(h2);
            if (tH > 0.0 && tH < bestT) { bestT = tH; bestI = i; }
        }
    }

    // distant planets: phase-lit dots / atmosphere halos
    for (int i = 0; i < 5; i++) {
        if (i == bestI) continue;
        float3 C; float R; int pt; bool rg;
        sysPlanet(i, seed, L, scn.y, scn.z, sunPhi, C, R, pt, rg);
        float3 w = C - ro;
        if (dot(w, rd) < 0.5) continue;
        float dca = length(cross(rd, w));
        if (dca < R) continue;
        float phase = 0.35 + 0.65 * max(dot(normalize(ro - C), normalize(sunC - C)), 0.0);
        col += atmoColorFor(pt, pal) * exp(-(dca - R) * 7.0 / R) * 0.4 * phase;
    }

    // hero planet surface
    if (bestI >= 0) {
        float3 C; float R; int ptype; bool rg;
        sysPlanet(bestI, seed, L, scn.y, scn.z, sunPhi, C, R, ptype, rg);
        float pseed = seed + float(bestI) * 31.7;
        float3 pos = ro + rd * bestT;
        float3 n = normalize(pos - C);

        float tilt = (hash11(pseed * 18.0) - 0.5) * 0.9;
        float spin = gt * mix(0.02, 0.07, hash11(pseed * 25.0));
        float3 ns = n;
        float2 nyz = rot2(tilt) * float2(ns.y, ns.z);
        ns.y = nyz.x; ns.z = nyz.y;
        float2 nxz = rot2(spin) * float2(ns.x, ns.z);
        ns.x = nxz.x; ns.z = nxz.y;
        float lat = clamp(ns.y, -1.0, 1.0);
        float lon = atan2(ns.z, ns.x);

        float3 emissive; float oceanMask;
        float3 surf = shadePlanet(normalize(ns), lat, lon, ptype, pseed, pal, gt, emissive, oceanMask);

        // fractal bump detail on rocky/icy/lava worlds
        if (ptype != 1) {
            float3 t1 = normalize(cross(n, float3(0.0, 1.0, 0.001)));
            float3 t2 = cross(n, t1);
            float e = 0.015;
            float h0 = fbm(ns * 7.0 + pseed * 13.0, 4);
            float hx = fbm((ns + t1 * e) * 7.0 + pseed * 13.0, 4);
            float hy = fbm((ns + t2 * e) * 7.0 + pseed * 13.0, 4);
            n = normalize(n + (t1 * (h0 - hx) + t2 * (h0 - hy)) * 2.0);
        }

        // positional lighting from the sun(s)
        float3 l1 = sunC - pos;
        float3 L1 = normalize(l1);
        float dif1 = max(dot(n, L1), 0.0);
        float3 light = sunCol * pow(dif1, 0.9);
        if (binary) {
            float3 L2 = normalize(sun2C - pos);
            light += sun2Col * pow(max(dot(n, L2), 0.0), 0.9) * 0.7;
        }
        float3 pcol = surf * (0.045 + light);
        pcol += emissive * (0.35 + 0.65 * (1.0 - dif1));
        float spec = pow(max(dot(reflect(-L1, n), -rd), 0.0), 80.0);
        pcol += sunCol * spec * oceanMask * dif1 * 0.8;
        // sunset band along the terminator
        float mu = dot(n, L1);
        float sunset = exp(-pow((mu - 0.03) * 9.0, 2.0));
        float3 atmoCol = atmoColorFor(ptype, pal);
        if (ptype == 0 || ptype == 3) {
            pcol += float3(0.95, 0.45, 0.18) * sunset * 0.22;
        }
        // atmosphere rim — only where sunlight actually scatters
        float fres = pow(1.0 - max(dot(n, -rd), 0.0), 2.6);
        pcol += atmoCol * fres * (0.38 * pow(dif1, 0.9));   // rim gated to lit sky

        // anti-aliased limb
        float dcaB = length(cross(rd, C - ro));
        float alpha = smoothstep(R, R - (bestT * 0.002 + 0.001), dcaB);
        col = mix(col, pcol, alpha);
    }

    // hero rings (planet 2), depth-tested against whatever surface we hit
    {
        float3 Ch; float Rh; int pth; bool ringsH;
        sysPlanet(2, seed, L, scn.y, scn.z, sunPhi, Ch, Rh, pth, ringsH);
        if (ringsH) {
            float3 rn = normalize(float3(0.22 * sin(seed * 4.0), 1.0, 0.30 * cos(seed * 9.0)));
            float denom = dot(rd, rn);
            if (abs(denom) > 1e-4) {
                float tp = dot(Ch - ro, rn) / denom;
                if (tp > 0.0 && tp < bestT) {
                    float3 hp = ro + rd * tp - Ch;
                    float rr = length(hp) / Rh;
                    if (rr > 1.4 && rr < 2.25) {
                        float bandN = noise3(float3(rr * 41.0, seed * 5.0, 1.3));
                        float bandW = noise3(float3(rr * 9.0, seed * 8.0, 4.7));
                        float band = smoothstep(0.42, 0.68, bandN) * smoothstep(0.25, 0.55, bandW);
                        float edge = smoothstep(1.4, 1.5, rr) * smoothstep(2.25, 2.05, rr);
                        float graze = smoothstep(0.03, 0.16, abs(denom));
                        float3 Lr = normalize(sunC - Ch);
                        float rl = 0.3 + 0.7 * max(dot(rn, Lr), max(dot(-rn, Lr), 0.0));
                        float3 ringCol = float3(0.50, 0.45, 0.37) * rl * (0.45 + 0.55 * bandN);
                        col = mix(col, ringCol, band * edge * graze * 0.38);
                    }
                }
            }
        }
    }

    // suns last: corona bleeds over planet limbs, occlusion handled inside
    col += sunGlow(ro, rd, sunC, Rs, sunCol, bestT, gt, seed);
    if (binary) col += sunGlow(ro, rd, sun2C, Rs2, sun2Col, bestT, gt, seed + 9.0);
    return col;
}

// ---------- scene 3: warp jump ----------

float3 warpScene(float2 uv, float t, float4 scn, float4 pal, float gt) {
    float seed = scn.x;
    float dur = max(scn.w, 1.0);
    float prog = clamp(t / dur, 0.0, 1.0);
    float ramp = smoothstep(0.0, 0.30, prog);

    uv = rot2(gt * 0.01 + 0.5 * ramp * sin(gt * 0.11) * 0.05) * uv;
    float r = length(uv);
    float a = atan2(uv.y, uv.x);

    float3 cA = tint(pal.x, 0.6) * float3(0.75, 0.88, 1.25);
    float3 cB = tint(pal.y, 0.7);
    float3 col = float3(0.002, 0.003, 0.006);

    // radial star streaks
    float speed = 1.2 + 5.5 * ramp;
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float cnt = 70.0 + 55.0 * fi;
        float aa = a + fi * 1.91;
        float ci = floor(aa / 6.28318 * cnt);
        float fa = fract(aa / 6.28318 * cnt) - 0.5;
        float h = hash11(ci * 0.733 + seed * 31.0 + fi * 7.0);
        float h2 = hash11(ci * 1.221 + seed * 17.0 + fi * 3.0);
        // +t so streak heads race OUTWARD from the center (toward the viewer)
        float z = fract(0.30 / max(r, 0.03) * (0.4 + 0.5 * h2) + t * speed * (0.55 + 0.55 * h) + h * 7.0);
        float ang = exp(-fa * fa * mix(160.0, 70.0, ramp));
        float tail = pow(max(1.0 - z, 0.0), mix(9.0, 2.4, ramp));
        float vis = smoothstep(0.015, 0.22, r);
        float3 sc = mix(float3(1.0), mix(cA, cB, h2), 0.55);
        col += sc * ang * tail * vis * (0.35 + 1.1 * ramp);
    }

    // swirling energy tunnel walls
    float v = 0.30 / max(r, 0.05);
    float sw = v * 0.55;
    float3 q = float3(cos(a + sw), sin(a + sw), v * 0.35 - t * (1.6 + 3.6 * ramp)) * 1.6 + seed * 5.0;
    float tun = fbm(q, 4);
    col += mix(cA, cB, tun) * pow(tun, 2.4) * exp(-r * 1.5) * 1.6 * ramp;

    // core glow, breathing
    col += cA * exp(-r * 4.0) * (0.35 + 1.1 * ramp) * (0.9 + 0.1 * sin(gt * 5.0));

    // exit flash into the new region
    float flash = smoothstep(0.80, 1.0, prog);
    col += float3(1.0, 0.97, 0.92) * flash * flash * 3.5;
    return col;
}

// ---------- scene 4: rare encounters ----------

// shared panel texture for megastructures; openWeight 0..1 raises gap count
float3 panelTex(float2 p2, float seed, float gt, thread bool &open, float openWeight) {
    float3 warm = float3(1.0, 0.82, 0.5);
    float row = floor(p2.y);
    p2.x += step(0.5, fract(row * 0.5)) * 0.5;   // brick offset
    float2 id = float2(floor(p2.x), row);
    float2 f = float2(fract(p2.x), fract(p2.y));
    float h = hash21(id + seed * 7.0);
    float big = hash21(floor(id / 3.0) + seed * 13.0);
    float flick = 0.92 + 0.08 * sin(gt * 3.0 + h * 40.0);
    open = (h < 0.08 + 0.1 * openWeight) || (big > 0.94 - 0.05 * openWeight);
    if (open) {
        float edgeSoft = smoothstep(0.0, 0.10, min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y)));
        return warm * (5.5 * edgeSoft + 0.9) * flick;
    }
    float albedo = mix(0.012, 0.045, hash21(id + seed * 3.0));
    float3 metal = float3(albedo) * float3(0.85, 0.92, 1.05);
    float bmin = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y));
    float seam = smoothstep(0.045, 0.0, bmin);
    float win = step(0.993, hash21(floor(f * 9.0) + id * 5.0 + seed));
    return metal + float3(1.0, 0.45, 0.12) * seam * 0.55 * flick + warm * win * 0.28;
}

// exterior of a (possibly partial) dyson shell. coverage 1 = complete.
float3 dysonExterior(float2 uv, float ap, float seed, float4 pal, float gt, float coverage) {
    float3 rd = normalize(float3(uv, 1.45));
    float2 rxy = rot2(0.04 * sin(gt * 0.037) + gt * 0.002) * rd.xy;
    rd.x = rxy.x; rd.y = rxy.y;

    float sp = smoothstep(0.0, 1.0, ap);
    float side = hash11(seed * 9.3) > 0.5 ? 1.0 : -1.0;
    float R = 2.6;
    float3 C;
    C.z = mix(34.0, 1.2, sp);                      // journeys end AT the shell
    C.x = side * 0.25 * (1.0 - sp);
    C.y = 0.12 * sin(ap * 2.7 + seed) * (1.0 - sp);

    float3 col = spaceBG(uv + seed * 2.0, seed + 4.0, pal, gt, 0.35);
    float3 warm = float3(1.0, 0.82, 0.5);

    float3 oc = -C;
    float b = dot(oc, rd);
    float h2 = b * b - (dot(oc, oc) - R * R);
    bool solidHit = false;
    if (h2 > 0.0) {
        float tS = -b - sqrt(h2);
        if (tS > 0.0) {
            float3 pos = rd * tS;
            float3 n = normalize(pos - C);
            float3 ns = n;
            float2 nxz = rot2(gt * 0.012) * float2(ns.x, ns.z);
            ns.x = nxz.x; ns.z = nxz.y;
            // construction coverage: unbuilt region exposes the star
            float built = fbm(ns * 1.3 + seed * 3.0, 3);
            bool inBuilt = built < coverage;
            if (inBuilt) {
                float lat = asin(clamp(ns.y, -1.0, 1.0));
                float lon = atan2(ns.z, ns.x);
                bool open;
                col = panelTex(float2(lon * 7.0, lat * 8.0), seed, gt, open, 0.0);
                solidHit = !open;
                // glowing construction scaffold near the ragged edge
                float edge = smoothstep(0.10, 0.0, abs(built - coverage));
                col += float3(1.0, 0.5, 0.15) * edge * (0.8 + 0.2 * sin(gt * 4.0 + built * 60.0));
                float fres = pow(1.0 - max(dot(n, -rd), 0.0), 3.0);
                col += warm * fres * 0.7;
            }
        }
    }
    if (!solidHit) {
        // star inside, visible through gaps / unbuilt regions
        float3 sv = C;
        float sd = length(sv);
        float dca = length(cross(rd, sv));
        if (dot(rd, normalize(sv)) > 0.0) {
            float Rs = 0.62;
            float disc = smoothstep(Rs + 0.02 * sd, Rs - 0.02 * sd, dca);
            col = mix(col, warm * 3.2, disc);
            col += warm * exp(-max(dca - Rs, 0.0) * 2.2) * 0.5;
        }
        float3 cv = rd * max(-b, 0.0) - C;
        float halo = exp(-max(length(cv) - R, 0.0) * 4.0 / R);
        float shaft = 0.5 + 0.5 * fbm(float3(normalize(cv + 1e-4).xy * 3.0, seed * 5.0 + gt * 0.05), 3);
        col += warm * halo * 0.4 * shaft;
    }
    return col;
}

// thick rim of an opening rushing past as we cross the shell wall
float3 dysonRim(float2 uv, float t, float seed, float gt, float dirSign) {
    float r = length(uv) + 0.12;
    float a = atan2(uv.y, uv.x);
    float z = 0.8 / r + dirSign * t * 5.0;
    float2 pc = float2(a * 8.0, z * 1.2);
    float2 id = floor(pc);
    float2 f = fract(pc);
    float h = hash21(id + seed);
    float3 metal = float3(0.030, 0.034, 0.045) * (0.4 + 0.8 * h);
    float bmin = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y));
    float strip = smoothstep(0.06, 0.0, bmin);
    float3 col = metal * exp(-r * 0.5);
    col += float3(1.0, 0.42, 0.10) * strip * exp(-r * 0.7) * (0.7 + 0.3 * sin(gt * 6.0 + h * 20.0));
    // light spilling through the bore
    col += float3(1.0, 0.85, 0.55) * exp(-r * 3.5) * 0.45;
    return col;
}

float interiorH(float2 xz, float seed) {
    // The same world coordinates are used for coastlines, geometry and districts.
    return fbm(float3(xz * 0.037, seed * 7.0), 3);
}

float dysonBox(float3 p, float3 b) {
    float3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

// Slab interval in each arcology's radial coordinate frame. The reciprocal
// direction is shared by the outer bound and exact architectural box hits.
float2 dysonSlab(float3 origin, float3 invDirection, float3 lo, float3 hi) {
    float3 a = (lo - origin) * invDirection;
    float3 b = (hi - origin) * invDirection;
    float3 near = min(a, b), far = max(a, b);
    return float2(max(near.x, max(near.y, near.z)), min(far.x, min(far.y, far.z)));
}

float dysonBoxRay(float3 origin, float3 invDirection, float3 center, float3 halfSize) {
    float2 interval = dysonSlab(origin - center, invDirection, -halfSize, halfSize);
    return interval.y >= max(interval.x, 0.0) ? max(interval.x, 0.0) : 1e6;
}

// Original procedural architecture: each district chooses one structural family.
// Positive distances are empty space; the four families have actual silhouettes.
float dysonArcology(float3 p, int kind, float h) {
    float d = dysonBox(p - float3(0, 0.18, 0), float3(2.45, 1.0, 2.45));
    if (kind == 0) {
        // Terraced garden ziggurat crowned by a narrow observatory.
        for (int level = 0; level < 4; ++level) {
            float l = float(level);
            float width = 2.12 - l * 0.43;
            d = min(d, dysonBox(p - float3(0, h * (0.10 + 0.18 * l), 0),
                                float3(width, h * 0.105, width)));
        }
        d = min(d, dysonBox(p - float3(0, h * 0.82, 0), float3(0.23, h * 0.18, 0.23)));
    } else if (kind == 1) {
        // A tapered fluted needle with suspended observation rings.
        float cone = max((length(p.xz) - max(0.055, 1.40 * (1.0 - p.y / h))) * 0.94,
                         max(-p.y, p.y - h));
        d = min(d, cone);
        float ring = length(float2(length(p.xz) - 1.55, p.y - h * 0.46)) - 0.17;
        d = min(d, ring);
        d = min(d, length(float2(length(p.xz) - 0.93, p.y - h * 0.73)) - 0.12);
    } else if (kind == 2) {
        // Twin monoliths support an inhabited skybridge; the void is traversable.
        float3 twin = float3(abs(p.x) - 1.25, p.y - h * 0.44, p.z);
        d = min(d, dysonBox(twin, float3(0.44, h * 0.44, 0.73)));
        d = min(d, dysonBox(p - float3(0, h * 0.67, 0), float3(1.68, 0.25, 0.70)));
        d = min(d, dysonBox(p - float3(0, h * 0.88, 0), float3(1.72, 0.12, 0.81)));
    } else {
        // Glazed biosphere on a circular podium, with a service mast.
        float3 q = (p - float3(0, 0.52, 0)) / float3(2.28, h * 0.72, 2.28);
        float dome = max((length(q) - 1.0) * min(2.28, h * 0.72), 0.38 - p.y);
        d = min(d, dome);
        d = min(d, max(length(p.xz) - 2.3, abs(p.y - 0.35) - 0.35));
        d = min(d, max(length(p.xz - float2(1.90, 0.8)) - 0.12,
                       abs(p.y - h * 0.53) - h * 0.53));
    }
    return d;
}

// A concave spherical world: no horizon plane or screen-space skyline. The
// camera follows its inner curvature and the sun stays at the shell's centre.
float3 dysonInterior(float2 uv, float t, float seed, float4 pal, float gt) {
    const float R = 96.0;
    const float3 C = float3(0, R, 0);
    float route = (t - 25.0) * 1.18;
    float3 ro = float3(0.65 * sin(t * 0.12 + seed), 0, route);
    ro.y = R - sqrt(max(R * R - dot(ro.xz, ro.xz), 1.0)) + 6.1;
    float3 up = normalize(C - ro);
    float3 forward = normalize(cross(float3(1, 0, 0), up));
    float3 right = normalize(cross(up, forward));
    // Low overflight first; a late look up reveals the captive sun and far lands.
    float pitch = mix(0.09, 1.24, smoothstep(35.0, 42.0, t));
    float3 look = forward * cos(pitch) + up * sin(pitch);
    float3 screenUp = up * cos(pitch) - forward * sin(pitch);
    float2 screen = rot2(0.028 * sin(t * 0.17)) * uv;
    float3 rd = normalize(right * screen.x + screenUp * screen.y + look * 0.80);

    float3 oc = ro - C;
    float b = dot(oc, rd);
    float farT = -b + sqrt(max(b * b - dot(oc, oc) + R * R, 0.0));
    float terrainT = farT;
    // A few local intersection refinements lift continents off the sea sphere.
    // This produces geometric relief and coastline occlusion at grazing angles.
    for (int j = 0; j < 2; ++j) {
        float3 q = ro + rd * terrainT;
        float elev = max(interiorH(q.xz, seed) - 0.46, 0.0) * 5.0;
        float3 outward = normalize(q - C);
        terrainT += (R - elev - length(q - C)) / max(dot(rd, outward), 0.12);
    }
    terrainT = max(terrainT, 0.1);
    float3 ground = ro + rd * terrainT;
    float3 nShell = normalize(C - ground);
    float hh = interiorH(ground.xz, seed);
    float water = 1.0 - smoothstep(0.447, 0.465, hh);
    float coast = exp(-abs(hh - 0.456) * 95.0);
    float3 land = mix(float3(0.024, 0.095, 0.044), float3(0.21, 0.17, 0.082),
                      smoothstep(0.49, 0.69, hh));
    land = mix(land, float3(0.62, 0.69, 0.72), smoothstep(0.71, 0.82, hh));
    float3 ocean = mix(float3(0.006, 0.025, 0.056), float3(0.018, 0.12, 0.16), coast);
    float3 col = mix(land, ocean, water);
    float detail = fbm(float3(ground * 0.75 + seed), 2);
    col *= 0.36 + 1.04 * detail;
    float e = 0.16;
    float hx = interiorH(ground.xz + float2(e, 0), seed);
    float hz = interiorH(ground.xz + float2(0, e), seed);
    float3 terrainN = normalize(nShell + (1.0 - water) * float3((hh - hx) * 8.0, 0, (hh - hz) * 8.0));
    col *= 0.33 + 0.98 * max(dot(terrainN, normalize(C - ground)), 0.0);
    float spec = pow(max(dot(reflect(-normalize(C - ground), terrainN), -rd), 0.0), 110.0);
    col += float3(0.60, 0.77, 0.82) * spec * water * 0.70;

    // The far hemisphere's continents remain legible through restrained haze.
    // Great-circle structural seams make the enormous concave shell unmistakable.
    float3 outward = -nShell;
    float longitude = atan2(outward.x, outward.z);
    float latitude = asin(clamp(outward.y, -1.0, 1.0));
    float meridian = abs(sin(longitude * 9.0));
    float parallels = abs(sin(latitude * 13.0));
    float seamAA = max(fwidth(min(meridian, parallels)) * 1.3, 0.006);
    float seam = 1.0 - smoothstep(0.009, 0.009 + seamAA, min(meridian, parallels));
    col *= 1.0 - 0.48 * seam;
    col += float3(0.25, 0.47, 0.52) * seam * 0.022;
    float2 cityGrid = ground.xz * 2.8;
    float2 cityCell = fract(cityGrid) - 0.5;
    float farCity = step(0.973, hash21(floor(cityGrid) + seed)) * exp(-dot(cityCell, cityCell) * 110.0);
    col *= mix(0.86, 0.42, smoothstep(25.0, 150.0, terrainT));
    col += float3(0.95, 0.57, 0.19) * farCity * (1.0 - water) * 0.09;
    float haze = min(0.32, 1.0 - exp(-terrainT * 0.0025));
    col = mix(col, float3(0.018, 0.029, 0.042), haze);

    float nearest = terrainT;
    float3 hitLocal = float3(0);
    float3 hitUp = float3(0, 1, 0), hitRight = float3(1, 0, 0), hitForward = float3(0, 0, 1);
    float hitH = 0.0, hitSeed = 0.0;
    int hitKind = -1;
    // Fixed world districts: buildings grow and pass naturally with camera motion.
    // An analytic bound rejects almost every arcology before any distance marching.
    for (int row = 0; row < 4; ++row) {
        for (int lane = 0; lane < 4; ++lane) {
            float2 id = float2(lane, row);
            float2 rnd = hash22(id + seed * 2.71);
            float x = (float(lane) - 1.5) * 10.0 + (rnd.x - 0.5) * 2.0;
            float z = float(row) * 12.0 + 5.0 + (rnd.y - 0.5) * 3.0;
            float h = mix(4.2, 10.8, hash21(id + seed * 8.3));
            int kind = int(floor(hash21(id + seed * 3.19) * 4.0));
            float y = R - sqrt(max(R * R - x * x - z * z, 1.0));
            float3 center = float3(x, y, z);
            float3 buildingUp = normalize(C - center);
            float3 buildingRight = normalize(cross(buildingUp, float3(0, 0, 1)));
            float3 buildingForward = cross(buildingRight, buildingUp);
            // Deep foundations intersect the terrain; no expensive noise per building.
            center += buildingUp * 0.52;
            // Broad contact shadows ground the bases, including offshore platforms.
            float2 shadowDelta = ground.xz - center.xz;
            float shadow = exp(-dot(shadowDelta, shadowDelta) * 0.13);
            col *= 1.0 - 0.34 * shadow * step(ground.y, y + 0.5);
            float3 relOrigin = ro - center;
            float3 localOrigin = float3(dot(relOrigin, buildingRight), dot(relOrigin, buildingUp), dot(relOrigin, buildingForward));
            float3 localRay = float3(dot(rd, buildingRight), dot(rd, buildingUp), dot(rd, buildingForward));
            float3 invRay = select(float3(-1.0), float3(1.0), localRay >= 0.0) / max(abs(localRay), 1e-6);
            float top = kind == 3 ? h * 1.06 : h;
            float2 interval = dysonSlab(localOrigin, invRay, float3(-2.45, -0.82, -2.45), float3(2.45, top, 2.45));
            float a = max(interval.x, 0.0), end = min(nearest, interval.y);
            if (a >= end) continue;
            float candidate = 1e6;
            if (kind == 0 || kind == 2) {
                // These families consist entirely of boxes, so intersect them
                // exactly instead of spending a distance march on their empty gaps.
                candidate = dysonBoxRay(localOrigin, invRay, float3(0, 0.18, 0), float3(2.45, 1.0, 2.45));
                if (kind == 0) {
                    for (int level = 0; level < 4; ++level) {
                        float l = float(level), width = 2.12 - l * 0.43;
                        candidate = min(candidate, dysonBoxRay(localOrigin, invRay,
                            float3(0, h * (0.10 + 0.18 * l), 0), float3(width, h * 0.105, width)));
                    }
                    candidate = min(candidate, dysonBoxRay(localOrigin, invRay, float3(0, h * 0.82, 0), float3(0.23, h * 0.18, 0.23)));
                } else {
                    candidate = min(candidate, dysonBoxRay(localOrigin, invRay, float3(-1.25, h * 0.44, 0), float3(0.44, h * 0.44, 0.73)));
                    candidate = min(candidate, dysonBoxRay(localOrigin, invRay, float3(1.25, h * 0.44, 0), float3(0.44, h * 0.44, 0.73)));
                    candidate = min(candidate, dysonBoxRay(localOrigin, invRay, float3(0, h * 0.67, 0), float3(1.68, 0.25, 0.70)));
                    candidate = min(candidate, dysonBoxRay(localOrigin, invRay, float3(0, h * 0.88, 0), float3(1.72, 0.12, 0.81)));
                }
            } else {
                for (int j = 0; j < 20; ++j) {
                    float3 local = localOrigin + localRay * a;
                    float d = dysonArcology(local, kind, h);
                    float eps = max(0.006, a * 0.00045);
                    if (d < eps) { candidate = a; break; }
                    a += max(d * 0.89, 0.012);
                    if (a >= end) break;
                }
            }
            if (candidate < nearest) {
                nearest = candidate; hitLocal = localOrigin + localRay * candidate;
                hitH = h; hitKind = kind; hitSeed = rnd.y;
                hitUp = buildingUp; hitRight = buildingRight; hitForward = buildingForward;
            }
        }
    }
    if (hitKind >= 0) {
        float eps = max(0.009, nearest * 0.0005);
        float3 p = hitLocal;
        // Tetrahedral normal: four field samples rather than six.
        float3 k0 = float3(1, -1, -1), k1 = float3(-1, -1, 1);
        float3 k2 = float3(-1, 1, -1), k3 = float3(1, 1, 1);
        float3 n = normalize(k0 * dysonArcology(p + k0 * eps, hitKind, hitH)
                           + k1 * dysonArcology(p + k1 * eps, hitKind, hitH)
                           + k2 * dysonArcology(p + k2 * eps, hitKind, hitH)
                           + k3 * dysonArcology(p + k3 * eps, hitKind, hitH));
        float3 worldN = normalize(hitRight * n.x + hitUp * n.y + hitForward * n.z);
        float3 light = normalize(C - (ro + rd * nearest));
        float dif = max(dot(worldN, light), 0.0);
        float3 metal = mix(float3(0.12, 0.18, 0.22), float3(0.29, 0.21, 0.11), hitSeed);
        float facing = 1.0 - abs(n.y);
        float2 facade = float2(abs(n.x) > abs(n.z) ? p.z : p.x, p.y);
        float floorLine = 1.0 - smoothstep(0.06, 0.15, abs(fract(p.y * 2.8) - 0.5));
        float occupied = step(0.29, hash21(floor(facade * float2(4.5, 2.8)) + hitSeed * 313.0));
        float window = step(0.63, fract(facade.x * 4.5)) * floorLine * facing * occupied;
        float3 cityLight = mix(float3(0.16, 0.69, 1.0), float3(1.0, 0.65, 0.24), hitSeed);
        float panelVariation = 0.70 + 0.30 * hash21(floor(facade * float2(1.6, 0.75)) + hitSeed * 219.0);
        col = metal * (0.16 + dif * 1.05) * panelVariation;
        col += cityLight * window * 0.12;
        col += float3(0.8, 0.85, 0.9) * pow(max(dot(reflect(-light, worldN), -rd), 0.0), 38.0) * 0.48;
        // Dark glazed biospheres carry a fine structural lattice and green gardens.
        if (hitKind == 3 && p.y > 0.7) {
            float longitudeD = atan2(p.z, p.x);
            float latitudeD = atan2(p.y - 0.52, length(p.xz));
            float lattice = max(1.0 - smoothstep(0.055, 0.13, abs(sin(longitudeD * 14.0))),
                                1.0 - smoothstep(0.055, 0.13, abs(sin(latitudeD * 12.0))));
            float fresnel = pow(1.0 - max(dot(worldN, -rd), 0.0), 3.0);
            col = mix(float3(0.016, 0.085, 0.073), float3(0.14, 0.30, 0.34), fresnel) * (0.8 + 0.55 * dif);
            col += float3(0.35, 0.46, 0.44) * lattice * 0.42;
            col += float3(0.80, 0.95, 1.0) * pow(max(dot(reflect(-light, worldN), -rd), 0.0), 90.0) * 1.8;
        }
        if (hitKind == 0 && n.y > 0.8 && p.y < hitH * 0.73) {
            col = mix(col, float3(0.025, 0.12, 0.055), 0.40); // terrace gardens
        }
        col = mix(col, float3(0.018, 0.029, 0.042), min(0.32, 1.0 - exp(-nearest * 0.0025)));
    }
    // A physical star at C, correctly hidden by any nearer structure.
    float starAlong = dot(C - ro, rd);
    float starDistance = length(cross(rd, C - ro));
    if (starAlong > 0.0 && starAlong < nearest) {
        float disc = 1.0 - smoothstep(3.7, 3.82, starDistance);
        float3 sunlight = float3(1.0, 0.87, 0.58);
        col = mix(col, sunlight * 5.0, disc);
        col += sunlight * (exp(-max(starDistance - 3.7, 0.0) * 0.43) * 0.55
                          + exp(-starDistance * 0.075) * 0.10);
    }
    return col;
}

// Niven-ring stage: a colossal rotating band around the star
float3 dysonRing(float2 uv, float t, float seed, float4 pal, float gt, float dur) {
    float prog = clamp(t / dur, 0.0, 1.0);
    float sp = smoothstep(0.0, 1.0, prog);
    float3 ro = float3(0.0);
    float3 rd = normalize(float3(uv, 1.45));
    float2 rxy = rot2(0.04 * sin(gt * 0.041) + gt * 0.0025) * rd.xy;
    rd.x = rxy.x; rd.y = rxy.y;

    float side = hash11(seed * 9.3) > 0.5 ? 1.0 : -1.0;
    float3 S = float3(side * (0.3 + 1.6 * sp * sp), 0.1 * sin(prog * 3.0 + seed), mix(30.0, -3.0, sp));
    float3 axis = normalize(float3(0.30 * sin(seed * 2.0), 1.0, 0.22 * cos(seed * 5.0)));
    float Rb = 3.1;
    float halfW = 0.55;

    float3 col = spaceBG(uv + seed * 3.0, seed + 4.0, pal, gt, 0.35);
    float3 warm = float3(1.0, 0.82, 0.5);

    // infinite-cylinder intersection, then clamp to band width
    float3 oc = ro - S;
    float3 ocp = oc - dot(oc, axis) * axis;
    float3 rdp = rd - dot(rd, axis) * axis;
    float A = dot(rdp, rdp);
    float tHit = -1.0;
    bool inner = false;
    if (A > 1e-5) {
        float B = 2.0 * dot(ocp, rdp);
        float Cq = dot(ocp, ocp) - Rb * Rb;
        float disc = B * B - 4.0 * A * Cq;
        if (disc > 0.0) {
            float sq = sqrt(disc);
            float t0 = (-B - sq) / (2.0 * A);
            float t1 = (-B + sq) / (2.0 * A);
            float ax0 = dot(oc + rd * t0, axis);
            float ax1 = dot(oc + rd * t1, axis);
            if (t0 > 0.0 && abs(ax0) < halfW) { tHit = t0; inner = false; }
            else if (t1 > 0.0 && abs(ax1) < halfW) { tHit = t1; inner = true; }
        }
    }
    bool solid = false;
    if (tHit > 0.0) {
        float3 pos = ro + rd * tHit;
        float3 rel = pos - S;
        float axy = dot(rel, axis);
        float3 radial = normalize(rel - axy * axis);
        // band-surface coordinates: angle along ring x axial width
        float3 u0 = normalize(cross(axis, float3(0.0, 0.0, 1.0)) + 1e-4);
        float3 v0 = cross(axis, u0);
        float theta = atan2(dot(radial, v0), dot(radial, u0)) + gt * 0.02;  // ring spins
        if (!inner) {
            bool open;
            col = panelTex(float2(theta * Rb * 3.2, (axy / halfW) * 2.2), seed, gt, open, 0.0);
            solid = !open;
            float3 nrm = radial;
            float fres = pow(1.0 - max(dot(nrm, -rd), 0.0), 3.0);
            col += warm * fres * 0.6;
        } else {
            // sunlit habitable inner surface: a glowing strip of land and sea
            float hh = fbm(float3(theta * 9.0, axy * 5.0, seed * 11.0), 5);
            float sea = 0.45;
            float3 land = mix(float3(0.10, 0.30, 0.12), float3(0.45, 0.38, 0.22),
                              smoothstep(sea, sea + 0.3, hh));
            float3 oceanc = float3(0.05, 0.20, 0.32);
            col = mix(oceanc, land, smoothstep(sea - 0.02, sea + 0.02, hh)) * 1.5;
            float cl = smoothstep(0.55, 0.75, fbm(float3(theta * 14.0 + gt * 0.01, axy * 7.0, seed * 23.0), 4));
            col = mix(col, float3(1.0), cl * 0.7);
            col *= 0.9 + 0.4 * (1.0 - abs(axy) / halfW);   // brighter mid-strip
            solid = true;
        }
        // bright structural edge rails
        float rail = smoothstep(0.92, 1.0, abs(axy) / halfW);
        col += warm * rail * 0.9;
    }
    // the star, occluded by the band where solid
    float sd = length(S);
    float dca = length(cross(rd, S));
    if (dot(rd, normalize(S)) > 0.0 && (!solid || tHit > sd)) {
        float Rs = 0.62;
        float disc2 = smoothstep(Rs + 0.02 * sd, Rs - 0.02 * sd, dca);
        col = mix(col, warm * 3.2, disc2);
        col += warm * exp(-max(dca - Rs, 0.0) * 1.8) * 0.45;
    }
    return col;
}

// full sphere with fly-through: approach -> bore through an opening ->
// overflight of the inner surface -> bore out -> recede
float3 dysonJourney(float2 uv, float t, float seed, float4 pal, float gt, float dur) {
    float prog = clamp(t / dur, 0.0, 1.0);
    float pA = smoothstep(0.30, 0.38, prog);   // exterior -> entry bore
    float pB = smoothstep(0.40, 0.47, prog);   // bore -> interior
    float pC = smoothstep(0.76, 0.83, prog);   // interior -> exit bore
    float pD = smoothstep(0.86, 0.93, prog);   // bore -> open space

    float3 col;
    float r = length(uv);
    if (pA < 1.0) {
        float3 ext = dysonExterior(uv, min(prog / 0.33, 1.0), seed, pal, gt, 1.0);
        if (pA <= 0.0) { col = ext; } else { col = mix(ext, dysonRim(uv, t, seed, gt, 1.0), pA); }
    } else if (pB < 1.0) {
        // interior reveals through the bore mouth first, then floods outward
        float w = clamp(pB * 1.6 - r * 0.8 + pB * pB * 0.7, 0.0, 1.0);
        col = mix(dysonRim(uv, t, seed, gt, 1.0), dysonInterior(uv, t, seed, pal, gt), w);
    } else if (pC <= 0.0) {
        col = dysonInterior(uv, t, seed, pal, gt);
    } else if (pD < 1.0) {
        // exit: rim walls close in from the screen edges as we climb into the bore
        float w = clamp(pC * 1.6 - max(1.1 - r, 0.0) * 0.9 + pC * pC * 0.8, 0.0, 1.0);
        col = mix(dysonInterior(uv, t, seed, pal, gt), dysonRim(uv, t, seed + 5.0, gt, -1.0), w);
        if (pD > 0.0) {
            float3 away = spaceBG(uv * 0.8 + seed, seed + 6.0, pal, gt, 0.45)
                        + float3(1.0, 0.82, 0.5) * exp(-length(uv) * 1.6) * 0.5;
            col = mix(col, away, pD);
        }
    } else {
        // receding: glow of the sphere behind us fades into open space
        col = spaceBG(uv * 0.8 + seed, seed + 6.0, pal, gt, 0.45);
        col += float3(1.0, 0.82, 0.5) * exp(-length(uv) * 1.6) * 0.5 * (1.0 - smoothstep(0.93, 1.0, prog));
    }
    return col;
}

float3 dysonScene(float2 uv, float t, float seed, float4 pal, float gt, float dur, int stage) {
    if (stage == 0) return dysonRing(uv, t, seed, pal, gt, dur);
    if (stage == 1) {
        float prog = clamp(t / dur, 0.0, 1.0);
        return dysonExterior(uv, prog, seed, pal, gt, 0.55);   // half-built shell
    }
    return dysonJourney(uv, t, seed, pal, gt, dur);
}

// Dyson swarm: shells of collector satellites glinting around the star
float3 dysonSwarmScene(float2 uv, float t, float seed, float4 pal, float gt, float dur) {
    float prog = clamp(t / dur, 0.0, 1.0);
    float sp = smoothstep(0.0, 1.0, prog);
    uv = rot2(gt * 0.004) * uv;
    float3 col = spaceBG(uv + seed, seed + 7.0, pal, gt, 0.4);

    // star drifts gently as we cruise past
    float side = hash11(seed * 5.5) > 0.5 ? 1.0 : -1.0;
    float2 ssun = float2(side * mix(0.25, -0.18, sp), 0.06 * sin(prog * 2.4 + seed));
    float zoom = mix(0.12, 1.45, pow(sp, 1.4));    // from a speck, accelerating on approach
    float2 q = (uv - ssun) / zoom;

    float3 sunCol = starTemp(hash11(seed * 31.0) * 0.8);
    // orbital shells of glinting collectors
    for (int k = 0; k < 7; k++) {
        float fk = float(k);
        float h1 = hash11(seed * 3.1 + fk * 7.7);
        float h2 = hash11(seed * 6.3 + fk * 3.9);
        float2 qe = rot2(h1 * 6.28 + gt * 0.01 * (h2 - 0.5)) * q;
        qe.y /= mix(0.22, 0.85, h2);               // orbit inclination
        float rr = length(qe);
        float Rk = 0.16 + fk * 0.085 + h1 * 0.03;
        float band = exp(-pow((rr - Rk) * 150.0, 2.0));
        if (band < 0.003) continue;
        float ang = atan2(qe.y, qe.x);
        float n = 26.0 + fk * 9.0;
        float ph = ang / 6.28318 * n + gt * (0.18 + 0.10 * h2) * (h1 > 0.5 ? 1.0 : -1.0);
        float ci = floor(ph);
        float cf = fract(ph) - 0.5;
        float hh = hash11(ci * 0.61 + fk * 13.0 + seed);
        if (hh < 0.35) continue;                   // sparse population
        float dot2 = exp(-cf * cf * 260.0);
        // glint when the panel catches the star
        float glint = 0.5 + 0.5 * sin(gt * (1.5 + hh * 3.0) + hh * 40.0);
        col += sunCol * band * dot2 * (0.10 + 0.85 * glint * glint) * 0.8;
    }
    // a couple of near collectors sliding past in the foreground
    for (int m = 0; m < 2; m++) {
        float fm = float(m);
        float ep = floor(t / 11.0 + fm * 0.5);
        float fr = fract(t / 11.0 + fm * 0.5);
        float2 he = hash22(float2(ep * 5.1 + fm * 17.0, seed * 13.0));
        if (he.x < 0.35) continue;
        float2 path0 = (he - 0.5) * 1.6;
        float2 pp = path0 + float2(0.55, -0.25) * (fr - 0.5) * 2.0;
        float2 d = rot2(he.y * 6.28 + fr * 0.4) * (uv - pp);
        float panel = smoothstep(0.055, 0.05, abs(d.x)) * smoothstep(0.035, 0.03, abs(d.y));
        float env = sin(3.14159 * fr);
        float glint = pow(max(0.0, sin(fr * 6.0 + he.y * 9.0)), 8.0);
        float across = 0.30 + 0.70 * smoothstep(-0.055, 0.055, d.x * sign(he.y - 0.5));
        float cells = 0.80 + 0.20 * step(0.05, abs(fract(d.x * 22.0) - 0.5))
                                  * step(0.08, abs(fract(d.y * 30.0) - 0.5));
        float3 pc = (float3(0.04, 0.045, 0.06) + sunCol * glint * 1.1 * across) * cells;
        col = mix(col, pc, panel * env * 0.95);
        // blinking nav light
        col += float3(1.0, 0.2, 0.15) * exp(-dot(d - float2(0.05, 0.0), d - float2(0.05, 0.0)) * 4000.0)
             * step(0.6, fract(gt * 1.3 + he.y * 5.0)) * env;
    }
    // the star itself
    float dca = length(q);
    float Rs = 0.085;
    col = mix(col, sunCol * 3.0, smoothstep(Rs + 0.01, Rs - 0.01, dca));
    col += sunCol * exp(-max(dca - Rs, 0.0) * 14.0) * 0.55;
    col += sunCol * exp(-max(dca - Rs, 0.0) * 3.5) * 0.07;
    return col;
}

// Accretion disk emission at a geodesic/disk-plane crossing. hit is in BH
// frame (disk in y=0, horizon r=1), rd the photon's travel direction there.
float3 bhDisk(float3 hit, float3 rd, float seed, float gt, float spinDir,
              thread float &alpha) {
    float hr = length(hit.xz);
    float edge = smoothstep(2.55, 2.95, hr) * smoothstep(7.6, 5.6, hr);
    if (edge < 0.003) { alpha = 0.0; return float3(0.0); }

    // differentially rotating turbulence: each radius co-rotates at its own
    // Keplerian rate, so spiral streaks shear out on their own (no seam)
    float om = spinDir * 1.9 / (hr * sqrt(hr));
    float2 q = rot2(om * gt) * hit.xz;
    float turbulence = fbm(float3(q * 1.65, seed * 9.0), 3);
    float angle = atan2(q.y, q.x);
    // Integer angular frequencies keep the spiral seam invisible. The nested
    // filaments shear with the gas instead of reading as a stack of solid rings.
    float spiral = 0.5 + 0.5 * sin(angle * 3.0 + hr * 4.4 + turbulence * 4.0);
    float filament = pow(0.5 + 0.5 * sin(hr * 18.0 - angle * 2.0
                                       + turbulence * 9.0), 3.0);
    float dens = (0.24 + 0.80 * turbulence) * (0.64 + 0.36 * spiral)
               + 0.26 * filament;

    // temperature falls with radius: white-hot ISCO -> orange -> deep red
    float3 tc = mix(float3(1.05, 0.98, 0.92), float3(1.0, 0.60, 0.22),
                    smoothstep(2.7, 4.6, hr));
    tc = mix(tc, float3(0.55, 0.20, 0.07), smoothstep(4.6, 7.4, hr));
    float heat = pow(2.8 / hr, 2.2);

    // relativistic beaming: approaching side blasts brighter and bluer
    float beta = 0.55 / sqrt(hr);
    float3 vdir = spinDir * normalize(float3(hit.z, 0.0, -hit.x));
    float dop = clamp(1.0 / pow(max(1.0 + beta * dot(vdir, rd), 0.25), 3.0), 0.08, 3.6);
    float3 shift = mix(float3(1.12, 0.85, 0.62), float3(0.84, 0.93, 1.22),
                       clamp((dop - 0.6) * 0.9, 0.0, 1.0));
    float gz = sqrt(max(1.0 - 1.0 / hr, 0.0));   // gravitational redshift dims inner rim

    // A compact orbiting flare leaves a stretched arc in the rotating gas.
    // This is illustrative emission, not a reconstruction of a measured flare.
    float sr = 3.3;
    float sa = seed * 6.28 - spinDir * 1.9 / (sr * sqrt(sr)) * gt;
    float2 spotDir = float2(cos(sa), sin(sa));
    float2 radial = hit.xz / max(hr, 0.001);
    float angularGap = 1.0 - dot(radial, spotDir);
    float trailing = smoothstep(-0.04, 0.20,
                                spinDir * (radial.x * spotDir.y - radial.y * spotDir.x));
    float spot = exp(-pow((hr - sr) * 4.8, 2.0) - angularGap * 100.0);
    float trail = exp(-pow((hr - sr) * 4.2, 2.0) - angularGap * 11.0) * trailing;
    float flare = 0.78 + 0.22 * sin(gt * 0.37 + seed);

    alpha = clamp(edge * (0.30 + dens) * 0.85, 0.0, 0.95);
    return (tc * dens * 1.65 + float3(1.0, 0.96, 0.88) * spot * 5.6 * flare
            + float3(1.0, 0.53, 0.18) * trail * 1.8)
           * heat * edge * dop * shift * gz;
}

// Cinematic Schwarzschild-inspired lensing, with horizon radius = 1.
// A bounded numerical ray integration bends the disk and background together;
// the camera path and emissive gas are designed for visual exploration.
float3 blackHoleScene(float2 uv, float t, float seed, float4 pal, float gt, float dur) {
    float prog = clamp(t / max(dur, 1.0), 0.0, 1.0);
    float spinDir = hash11(seed * 6.1) > 0.5 ? 1.0 : -1.0;

    // An uninterrupted approach, survey orbit, close bank and departure.
    // Interpolating reciprocal distance makes the distant arrival grow gently.
    // At closest approach the camera stays > 7 horizon radii away; it never
    // crosses the event horizon or the bright accretion plane.
    float approach = smoothstep(0.02, 0.46, prog);
    float survey = smoothstep(0.34, 0.82, prog);
    float bank = smoothstep(0.62, 0.84, prog);
    float depart = smoothstep(0.85, 1.0, prog);
    float dist = 1.0 / mix(1.0 / 210.0, 1.0 / 14.0, approach);
    dist -= 6.7 * bank;
    dist += 4.5 * depart;
    float az = seed * 6.28 + spinDir * (0.30 * approach + 1.65 * survey + 0.36 * depart);
    float inc = mix(0.14, 0.28, hash11(seed * 2.3))
              + 0.30 * smoothstep(0.36, 0.66, prog) - 0.17 * bank;

    float roll = spinDir * (0.035 * sin(prog * 6.28318) + 0.20 * bank - 0.10 * depart);
    uv = rot2(roll) * uv;
    uv += float2(spinDir * 0.18, 0.025) * bank * (1.0 - 0.6 * depart);
    float3 ro = dist * float3(cos(inc) * cos(az), sin(inc), cos(inc) * sin(az));
    float3 fwd = -normalize(ro);
    float3 rgt = normalize(cross(float3(0.0, 1.0, 0.0), fwd));
    float3 upv = cross(fwd, rgt);
    float3 rd = normalize(fwd * 1.5 + rgt * uv.x + upv * uv.y);

    // skip the flat region analytically: march only inside r = R0
    const float R0 = 9.5;
    float3 p = ro;
    float b2 = dot(ro, ro) - dot(ro, rd) * dot(ro, rd);
    bool misses = dot(ro, ro) > R0 * R0 && b2 > R0 * R0;
    if (!misses && dot(ro, ro) > R0 * R0) {
        float tc0 = -dot(ro, rd) - sqrt(max(R0 * R0 - b2, 0.0));
        p = ro + rd * max(tc0, 0.0);
    }

    float3 v = rd;
    float3 hv = cross(p, v);
    float h2 = dot(hv, hv);
    float3 col = float3(0.0);
    float T = 1.0;                       // transmittance front-to-back
    bool captured = false;
    int emCount = 0;

    if (!misses) {
        for (int i = 0; i < 110; i++) {
            float r2 = dot(p, p);
            float r = sqrt(r2);
            if (r < 0.98) { captured = true; break; }
            if (r2 > R0 * R0 + 1.0 && dot(p, v) > 0.0) break;   // escaped
            float dt = clamp(r * 0.09, 0.02, 0.35);
            v = normalize(v - 1.5 * h2 * p / (r2 * r2 * r) * dt);
            float3 np = p + v * dt;
            // relativistic jet: optically-thin bipolar beam along the disk axis,
            // sampled during the march so its base lenses around the shadow
            float3 jp = (p + np) * 0.5;
            float ay = abs(jp.y);
            float jw = 0.14 + 0.09 * ay;
            float jr = length(jp.xz);
            if (jr < jw * 2.8 && ay > 0.9 && ay < 7.2) {
                float knots = 0.55 + 0.45 * noise3(jp * 1.9 - float3(0.0, gt * 1.7 * sign(jp.y), 0.0));
                float shape = (exp(-(jr * jr) / (jw * jw) * 3.1)
                             + 0.16 * exp(-(jr * jr) / (jw * jw) * 0.7));
                float jd = shape * smoothstep(7.2, 3.0, ay)
                         * smoothstep(0.9, 1.65, ay) * knots;
                float beam = jp.y > 0.0 ? 1.25 : 0.36;
                col += T * mix(float3(0.27, 0.48, 1.0), float3(0.76, 0.88, 1.0),
                               exp(-jr * jr / (jw * jw) * 5.0)) * jd * beam * dt;
            }
            if (p.y * np.y < 0.0 && emCount < 4) {              // disk-plane crossing
                float3 hit = mix(p, np, p.y / (p.y - np.y));
                float a;
                float3 e = bhDisk(hit, v, seed, gt, spinDir, a);
                if (a > 0.0) {
                    col += T * e;
                    T *= (1.0 - a);
                    emCount++;
                    if (T < 0.02) break;
                }
            }
            p = np;
        }
    }

    // escaped rays sample the background along their FINAL bent direction —
    // this is what smears stars into Einstein arcs around the shadow
    if (!captured && T > 0.02) {
        float3 vc = float3(dot(v, rgt), dot(v, upv), dot(v, fwd));
        float2 bg = vc.xy * 1.4 / (1.0 + max(vc.z, -0.85));
        // This background is evaluated along the escaped ray, so the small
        // stars still stretch into lensing arcs. Single-cell stars and one
        // restrained cloud field keep sky pixels cheaper than the ray march.
        float2 skyUV = bg + seed * 5.0;
        float3 sky = float3(0.003, 0.004, 0.008);
        sky += starLayerFast(skyUV * 13.0 + seed * 37.0, 0.10, seed + 9.0, gt) * 0.85;
        sky += starLayerFast(skyUV * 29.0 + seed * 53.0, 0.16, seed + 15.0, gt) * 0.45;
        float cloud = fbm(float3(skyUV * 3.2, seed * 7.31) + float3(gt * 0.004, 0.0, 0.0), 3);
        sky += mix(tint(pal.x, 0.65), tint(pal.y, 0.65), cloud)
             * cloud * cloud * cloud * pal.z * 0.018;
        col += T * sky;
    }
    return col;
}

float3 cometScene(float2 uv, float t, float seed, float4 pal, float gt, float dur) {
    float prog = clamp(t / dur, 0.0, 1.0);
    float3 col = spaceBG(uv * 0.8 + seed, seed + 8.0, pal, gt, 0.45);
    float2 tdir = normalize(float2(cos(seed * 4.7), sin(seed * 2.9)));   // tails point away from an unseen sun
    float2 pdir = float2(-tdir.y, tdir.x);

    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        float ph = fract(fi / 5.0 - t * 0.022 + hash11(seed * 3.0 + fi) * 0.8);
        float depth = 0.10 + 0.90 * ph;
        float2 q = uv * depth * 4.0 + (hash22(float2(fi * 7.7, seed * 17.0)) - 0.5) * 11.0;
        q -= tdir * t * 0.06;                // swarm streams along its orbit
        float fade = smoothstep(1.0, 0.85, ph) * smoothstep(0.0, 0.1, ph);
        float amp = mix(1.5, 0.4, ph) * fade;
        if (amp < 0.01) continue;

        float2 id = floor(q);
        float2 f = fract(q);
        for (int j = -1; j <= 1; j++) {
            for (int k = -1; k <= 1; k++) {
                float2 o = float2(k, j);
                float2 cid = id + o;
                float2 rnd = hash22(cid * 1.71 + seed * 23.0);
                if (rnd.x > 0.045) continue;
                float2 v = f - (o + rnd.yx * 0.8 + 0.1);
                float d = length(v);
                float along = dot(v, tdir);
                float perp = dot(v, pdir);
                float head = exp(-d * d * 900.0) * 1.3;
                float tailMask = smoothstep(-0.02, 0.05, along) * exp(-along * mix(2.5, 4.5, rnd.y));
                float wd = 0.015 + along * 0.10;
                float curve = perp - along * along * 0.25;
                float dust = tailMask * exp(-curve * curve / max(wd * wd, 1e-5));
                float wi = 0.008 + along * 0.04;
                float ion = smoothstep(-0.01, 0.04, along) * exp(-along * 1.9)
                            * exp(-perp * perp / max(wi * wi, 1e-5));
                float wisp = 0.65 + 0.55 * noise3(float3(along * 14.0, perp * 30.0, gt * 0.4 + rnd.y * 9.0));
                float support = 1.0 - smoothstep(0.55, 0.95, d);
                col += amp * support * (head * float3(0.9, 0.95, 1.0)
                              + dust * float3(1.0, 0.9, 0.75) * 0.32 * wisp
                              + ion * float3(0.5, 0.7, 1.0) * 0.38);
            }
        }
    }

    // hero comet crossing the frame once per visit
    float hside = hash11(seed * 31.0) > 0.5 ? 1.0 : -1.0;
    float2 hp = mix(float2(-1.15 * hside, -0.40), float2(1.15 * hside, 0.32), smoothstep(0.0, 1.0, prog));
    float henv = sin(3.14159 * prog);             // enter/leave past the frame edge, softly
    float2 v = uv - hp;
    float d = length(v);
    float along = dot(v, tdir);
    float perp = dot(v, pdir);
    float head = exp(-d * d * 2600.0) * 2.6 + exp(-d * 22.0) * 0.25;
    float tailMask = smoothstep(-0.03, 0.06, along) * exp(-along * 2.0);
    float wd = 0.02 + along * 0.13;
    float curve = perp - along * along * 0.30;
    float dust = tailMask * exp(-curve * curve / max(wd * wd, 1e-5));
    float wi = 0.010 + along * 0.05;
    float ion = smoothstep(-0.01, 0.05, along) * exp(-along * 1.5) * exp(-perp * perp / max(wi * wi, 1e-5));
    float wisp = 0.6 + 0.6 * noise3(float3(along * 10.0, perp * 24.0, gt * 0.5));
    col += (head * float3(0.92, 0.96, 1.0)
         + dust * float3(1.0, 0.9, 0.72) * 0.6 * wisp
         + ion * float3(0.5, 0.72, 1.0) * 0.6) * henv;
    return col;
}

// ---------- encounter subtype 4: pulsar ----------
// A rapidly spinning neutron star: a brilliant blue-white point, two lighthouse
// beams from the magnetic poles (tilted off the spin axis, so the pair rakes a
// cone and the scene PULSES when a beam sweeps the camera), a wispy pulsar-wind
// nebula with rotation-synced ripple shells, and a faint equatorial wind torus.

// closest distance between the camera ray (origin, dir rd) and a beam ray
// (origin bo, dir bd, length L). Fills s (param along beam) and u (along ray).
// When a beam points at the camera the line collapses onto the star -> a bright
// foreshortened blob = the pulse; broadside it reads as a long luminous cone.
float rayBeamDist(float3 rd, float3 bo, float3 bd, float L, thread float &s, thread float &u) {
    float e = dot(rd, bd);
    float3 w0 = -bo;
    float d1 = dot(rd, w0);
    float d2 = dot(bd, w0);
    float denom = max(1.0 - e * e, 1e-4);
    u = max((e * d2 - d1) / denom, 0.0);       // along camera ray
    s = clamp((d2 - e * d1) / denom, 0.0, L);  // along beam
    return length(rd * u - (bo + bd * s));
}

float3 pulsarScene(float2 uv, float t, float seed, float4 pal, float gt, float dur) {
    float prog = clamp(t / dur, 0.0, 1.0);
    float sp = smoothstep(0.0, 1.0, prog);
    float3 rd = normalize(float3(uv, 1.5));

    // approach: the star flies in from a distant dot to a close side-pass
    float dist = mix(30.0, 3.2, pow(sp, 1.25));
    float side = hash11(seed * 5.5) > 0.5 ? 1.0 : -1.0;
    float2 off = float2(side * (0.15 + 0.45 * sp), 0.10 * sin(prog * 3.1 + seed));
    float3 P = float3(off * dist * 0.28, dist);        // star position (grows as dist shrinks)
    float2 c = P.xy / P.z * 1.5;                       // screen projection of the star
    float3 toCam = normalize(-P);

    // spin axis tilted in view; magnetic axis offset by obliquity, precessing
    float3 S = normalize(float3(0.28 * sin(seed * 2.0), 0.85, 0.32 * cos(seed * 3.7)));
    float3 e1 = normalize(cross(S, float3(0.0, 0.0, 1.0)) + 1e-4);
    float3 e2 = cross(S, e1);
    float period = mix(0.8, 2.5, hash11(seed * 7.3));  // rotation period, seconds
    float phi = gt * 6.28318 / period;
    float obl = mix(0.4, 0.95, hash11(seed * 11.1));   // magnetic obliquity
    float3 M = normalize(cos(obl) * S + sin(obl) * (cos(phi) * e1 + sin(phi) * e2));

    float3 neb1 = tint(pal.x, 0.7);
    float3 neb2 = tint(pal.y, 0.8);
    float3 hot = float3(0.72, 0.85, 1.0);              // synchrotron blue-white
    float3 col = spaceBG(uv * 0.9 + seed, seed + 9.0, pal, gt, 0.35);

    // pulse: a beam pointed near the camera flashes the scene (not a white-out)
    float al = max(dot(M, toCam), dot(-M, toCam));
    float pulse = smoothstep(0.80, 0.995, al);

    // pulsar-wind nebula: wispy filaments + rotation-synced expanding shells
    float2 npos = uv - c;
    float nd = length(npos);
    float neb = fbm(float3(npos * 3.2 + seed, gt * 0.03), 4);
    float fil = pow(neb, 2.4) * exp(-nd * mix(6.5, 2.2, sp));   // compact when far
    col += mix(neb1, neb2, neb) * fil * 0.55 * (0.85 + 0.25 * pulse);
    // fbm-displaced phase breaks the shells into filamentary arcs, not contour rings
    float shell = pow(0.5 + 0.5 * sin((nd * 4.0 + (neb - 0.5) * 0.9 - gt / period) * 6.28318), 6.0);
    col += neb2 * shell * exp(-nd * mix(6.5, 2.6, sp)) * 0.22 * min(1.5 / P.z * 3.0, 1.0);

    // faint equatorial wind torus (perpendicular to the spin axis)
    if (hash11(seed * 2.7) > 0.35) {
        float Rt = 0.6;
        float tg = 0.0;
        for (int k = 0; k < 24; k++) {
            float th = float(k) / 24.0 * 6.28318;
            float3 Q = P + Rt * (cos(th) * e1 + sin(th) * e2);
            float2 qs = Q.xy / Q.z * 1.5;
            float dd = length(uv - qs);
            tg += exp(-dd * dd * 320.0);
        }
        col += mix(neb1, hot, 0.45) * tg * 0.055 * (0.6 + 0.4 * sin(gt * 0.5 + seed));
    }

    // the two lighthouse beams (luminous cones opening from the poles)
    for (int b = 0; b < 2; b++) {
        float3 bd = (b == 0) ? M : -M;
        float s, u;
        float dl = rayBeamDist(rd, P, bd, mix(4.0, 18.0, sp), s, u);   // short when far, grows in
        float width = 0.02 + 0.06 * s;                 // cone opens with distance
        float prof = exp(-(dl * dl) / (width * width));
        float falloff = exp(-s * 0.15);                // brightest near the star
        float wisp = 0.6 + 0.4 * fbm(float3(s * 1.4, phi * 0.5 + float(b) * 3.0, seed * 4.0 + gt * 0.2), 3);
        float aim = dot(bd, toCam);                    // +1 = pointed at us
        float beamBoost = 0.4 + 1.6 * smoothstep(-0.2, 1.0, aim);
        col += hot * prof * falloff * wisp * beamBoost * 1.35;
    }

    // the neutron star: an intense point (never a disc) with a tight bloom
    float ds = length(uv - c);
    float starBr = 2.2 + 6.5 * pulse;
    float coreR = mix(0.004, 0.02, sp);
    col += hot * smoothstep(coreR, coreR * 0.35, ds) * starBr * 2.0;
    // blooms tighten with distance so the opening reads as a tiny point
    col += hot * exp(-ds * ds * mix(9000.0, 1200.0, sp)) * starBr;
    col += hot * exp(-ds * mix(130.0, 14.0, sp)) * starBr * 0.4;

    // pulse bloom concentrated around the star — flashes without fogging the frame
    col += hot * pulse * 0.22 * exp(-ds * 2.2);
    return col;
}

// ---------- encounter subtype 5: asteroid belt fly-through ----------
// A lumpy tumbling rock. fbm roughens a disc rim into an irregular silhouette,
// ridged noise pocks it with craters, a fake spherical normal lights it from one
// off-screen sun: bright sunward limb, dark far side, a terminator between.
// v = offset from centre (same units as R), rot = tumble angle, sun = sunward dir.
float3 rockBody(float2 v, float R, float rot, float seed, float2 sun, float4 pal,
                int oct, thread float &cov) {
    float r = length(v);
    if (r > R * 1.8) { cov = 0.0; return float3(0.0); }    // cheap bounding reject
    float2 dir = v / max(r, 1e-5);
    float2 rdir = rot2(rot) * dir;
    // irregular rim: low-freq fbm displaces the radius (seam-free around the circle)
    float lump = fbm(float3(rdir * 1.7 + 4.0, seed * 3.0), oct);
    float Reff = R * (0.62 + 0.48 * lump);                 // kept < cell so it never clips
    float aa = fwidth(r) + R * 0.008;
    cov = smoothstep(Reff + aa, Reff - aa, r);
    if (cov < 0.002) { cov = 0.0; return float3(0.0); }
    // fake spherical relief so the disc reads as a solid 3D body
    float rn = r / Reff;
    float nz = sqrt(max(1.0 - rn * rn, 0.0));
    float3 n = normalize(float3(dir * rn * 0.92, nz + 0.14));
    float3 sun3 = normalize(float3(sun, 0.34));            // grazing -> clear terminator
    float diff = max(dot(n, sun3), 0.0);
    // craters + mottling tumble with the body (sampled in its rotated frame)
    float2 rc = rot2(rot) * v;
    float crat = ridged(float3(rc * (5.5 / R), seed * 7.0 + 2.0), oct + 1);
    float pock = smoothstep(0.40, 0.78, crat);
    float mott = 0.70 + 0.42 * fbm(float3(rc * (3.0 / R), seed), oct);
    float3 rock = mix(float3(0.14, 0.12, 0.11), float3(0.34, 0.29, 0.24), lump);
    rock = mix(rock, tint(pal.x, 0.35), 0.15) * mott;
    rock *= (1.0 - 0.7 * pock);                            // craters darken the body
    float3 lit = rock * (0.035 + 1.0 * diff);              // faint ambient + lambert
    // grazing sunward-limb highlight that catches the terminator edge
    float limb = smoothstep(0.70, 1.0, rn);
    float rim = limb * pow(max(dot(dir, sun), 0.0), 1.7) * smoothstep(-0.1, 0.35, diff);
    lit += float3(1.0, 0.86, 0.64) * rim * 0.5;
    return lit * cov;
}

float3 asteroidScene(float2 uv, float t, float seed, float4 pal, float gt, float dur) {
    float prog = clamp(t / dur, 0.0, 1.0);
    float3 col = spaceBG(uv * 0.85 + seed, seed + 5.0, pal, gt, 0.26);

    // one off-screen sun lights every rock the same way
    float2 sun = normalize(float2(cos(seed * 2.3) * 0.9, 0.35 + 0.45 * sin(seed * 1.7)));
    // belts orbit: bodies drift slowly sideways while streaming toward the viewer
    float2 orbit = normalize(float2(-sun.y, sun.x));

    // optional distant system sun with a soft glow (the light source, made visible)
    if (hash11(seed * 6.1) > 0.35) {
        float2 sp = sun * 1.05;                            // just past the frame edge
        float sd = length(uv - sp);
        float3 sunCol = mix(float3(1.0, 0.95, 0.85), tint(pal.y, 0.4), 0.3);
        col += sunCol * (exp(-sd * sd * 300.0) * 1.4 + exp(-sd * 6.0) * 0.09);
    }

    // ---- far dust + specks: cheap soft motes, depth-cycled, occasional glints ----
    for (int L = 0; L < 2; L++) {
        float fl = float(L);
        float K = 16.0 + fl * 10.0;
        float ph = fract(fl * 0.37 + hash11(seed + fl) * 0.6 - t * 0.030);
        float depth = 0.18 + 0.82 * ph;
        float fade = smoothstep(0.0, 0.12, ph) * smoothstep(1.0, 0.85, ph);
        if (fade < 0.01) continue;
        float2 q = uv * depth * K - orbit * t * 0.5 + hash22(float2(fl, seed)) * 20.0;
        float2 id = floor(q); float2 f = fract(q);
        float2 rnd = hash22(id * 1.7 + seed * 11.0 + fl * 5.0);
        if (rnd.x < 0.11) {
            float2 c = 0.5 + (rnd.yx - 0.5) * 0.7;
            float d = length(f - c);
            float g = hash21(id + fl);
            float3 dc = mix(float3(0.5, 0.46, 0.40), float3(0.80, 0.82, 0.90), g);
            float glint = 0.8 + 0.7 * pow(0.5 + 0.5 * sin(gt * (1.0 + 3.0 * g) + g * 30.0), 8.0);
            col += dc * exp(-d * d * 900.0) * 0.5 * fade * glint;
        }
    }

    // ---- medium tumbling rocks: sparse single-cell parallax layers ----
    for (int L = 0; L < 3; L++) {
        float fl = float(L);
        float K = 6.5 + fl * 3.2;
        float ph = fract(fl * 0.31 + hash11(seed * 2.0 + fl) * 0.9 - t * 0.024);
        float depth = 0.16 + 0.84 * ph;
        float fade = smoothstep(0.0, 0.13, ph) * smoothstep(1.0, 0.84, ph);
        if (fade < 0.01) continue;
        float2 q = uv * depth * K - orbit * t * 0.35 + hash22(float2(fl * 3.1, seed * 9.0)) * 14.0;
        float2 id = floor(q); float2 f = fract(q);
        float2 rnd = hash22(id * 1.93 + seed * 17.0 + fl * 7.0);
        if (rnd.x > 0.075) continue;                       // sparse: belts are mostly empty
        float2 center = 0.5 + (rnd.yx - 0.5) * 0.26;       // keep the rock inside its cell
        float2 v = f - center;
        float rh = hash21(id * 1.31 + seed + fl * 2.0);
        float R = mix(0.13, 0.25, rh);
        float rot = gt * mix(0.15, 0.5, hash11(rh * 5.0)) * (rh > 0.5 ? 1.0 : -1.0) + rh * 12.0;
        float cov;
        float3 rk = rockBody(v, R, rot, rh * 40.0 + fl, sun, pal, 2, cov);
        col = mix(col, float3(0.0), cov * 0.85 * fade);    // rock occludes what's behind
        col += rk * fade * mix(1.15, 0.55, ph);            // distant ones sink toward specks
    }

    // ---- HERO asteroid: large lumpy rock crosses slowly, grows then exits ----
    float hside = hash11(seed * 41.0) > 0.5 ? 1.0 : -1.0;
    float2 h0 = float2(-1.3 * hside, mix(-0.5, -0.2, hash11(seed * 13.0)));
    float2 h1 = float2( 1.3 * hside, mix( 0.2,  0.5, hash11(seed * 19.0)));
    float2 hp = mix(h0, h1, smoothstep(0.0, 1.0, prog));
    float env = sin(3.14159 * prog);                       // 0 at edges, 1 mid = closest
    float hR = 0.06 + 0.34 * env;                          // enters small, grows, recedes
    float hrot = gt * 0.22 + seed * 3.0;
    float hcov;
    float3 hero = rockBody(uv - hp, hR, hrot, seed * 5.0 + 3.0, sun, pal, 3, hcov);
    col = mix(col, float3(0.0), hcov * 0.92);              // occlude the background
    col += hero;

    // a tiny moonlet orbiting the hero (Dimorphos-style)
    if (hash11(seed * 23.0) > 0.25 && env > 0.02) {
        float ma = gt * 0.7 + seed * 4.0;
        float2 moff = rot2(ma) * float2(hR * 1.9, 0.0);
        moff.y *= 0.5;                                      // inclined orbit
        float mcov;
        float3 moon = rockBody(uv - (hp + moff), hR * 0.26, gt * 0.9 + seed,
                               seed * 8.0 + 1.0, sun, pal, 2, mcov);
        col = mix(col, float3(0.0), mcov * 0.92);
        col += moon;
    }
    return col;
}

float3 encounterScene(float2 uv, float t, float4 scn, float4 pal, float gt) {
    int sub = int(scn.y + 0.5);
    float dur = max(scn.w, 1.0);
    if (sub == 0) return dysonScene(uv, t, scn.x, pal, gt, dur, int(scn.z + 0.5));
    if (sub == 1) return blackHoleScene(uv, t, scn.x, pal, gt, dur);
    if (sub == 3) return dysonSwarmScene(uv, t, scn.x, pal, gt, dur);
    if (sub == 4) return pulsarScene(uv, t, scn.x, pal, gt, dur);
    if (sub == 5) return asteroidScene(uv, t, scn.x, pal, gt, dur);
    return cometScene(uv, t, scn.x, pal, gt, dur);
}

// ---------- scene 5: deep-field observation (NASA archive imagery) ----------
// scn: x=seed (drift path), y=SCREEN aspect (set by host), z=IMAGE aspect, w=duration

float3 deepfieldScene(float2 uv, float t, float4 scn, float4 pal, float gt,
                      texture2d<float> img) {
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float seed = scn.x;
    float sa = max(scn.y, 0.5);          // screen w/h
    float aspect = max(scn.z, 0.1);      // image w/h
    float dur = max(scn.w, 1.0);
    float prog = smoothstep(0.0, 1.0, clamp(t / dur, 0.0, 1.0));

    // slow drift between two random interior points + gentle zoom
    float2 c0 = 0.5 + (hash22(float2(seed, 7.7)) - 0.5) * 0.16;
    float2 c1 = 0.5 + (hash22(float2(seed, 13.3)) - 0.5) * 0.16;
    float2 c = mix(c0, c1, prog);
    float hx = 0.5 * sa;
    float Kmax = min(0.39 * aspect / hx, 0.78);
    // dolly INTO the field: K shrinks so features grow — travel, not a slideshow
    float K = Kmax * mix(0.95, 0.55, prog);
    float2 uvT = c + float2(uv.x / aspect, -uv.y) * K;

    float3 col = img.sample(smp, uvT).rgb;
    col = pow(max(col, 0.0), float3(2.2));        // back to linear for our pipeline
    col *= 0.95 + 0.05 * sin(gt * 0.21 + seed);   // slow exposure breathing
    // faint parallax starfield drifting in front of the photograph
    float2 sUV = uv * 7.0 + (c - 0.5) * 3.0 + seed * 19.0;
    col += starLayer(sUV, 0.05, seed + 4.0, gt) * 0.20;
    return col * smoothstep(0.0, 0.12, prog);     // arrive out of the dark, no pop
}

// ---------- scene 6: HOME SYSTEM (our own Solar System, one stop at a time) ----------
// kinds: 0 sun, 1 mercury, 2 venus, 3 earth, 4 mars, 5 jupiter, 6 saturn, 7 moon

// dwell weight per kind -> leg duration; earth is the hero, dwells longest
float dwellW(int kd) {
    if (kd == 3) return 1.55;
    if (kd == 0) return 1.00;
    if (kd == 5) return 1.05;
    if (kd == 6) return 1.15;
    return 0.95;                        // mercury / venus / mars
}
// world radius of the body at a stop (recognizability over literal scale)
float bodyR(int kd) {
    if (kd == 0) return 2.20;
    if (kd == 1) return 0.30;
    if (kd == 2) return 0.42;
    if (kd == 3) return 0.52;
    if (kd == 4) return 0.34;
    if (kd == 5) return 0.85;
    if (kd == 6) return 0.75;
    return 0.15;                        // moon
}
// forward distance at closest approach (smaller = bigger / closer pass)
float bodyDClose(int kd) {
    if (kd == 0) return 7.0;
    if (kd == 1) return 3.1;
    if (kd == 2) return 3.3;
    if (kd == 3) return 2.9;           // earth: the closest pass
    if (kd == 4) return 3.2;
    if (kd == 5) return 4.7;
    if (kd == 6) return 4.9;
    return 2.9;
}
// halo tint used when a body is a distant approaching/receding dot
float3 bodyTint(int kd) {
    if (kd == 1) return float3(0.50, 0.48, 0.45);
    if (kd == 2) return float3(0.90, 0.82, 0.55);
    if (kd == 3) return float3(0.40, 0.60, 1.00);
    if (kd == 4) return float3(0.80, 0.40, 0.25);
    if (kd == 5) return float3(0.80, 0.70, 0.55);
    if (kd == 6) return float3(0.85, 0.78, 0.60);
    return float3(0.60, 0.60, 0.62);   // moon
}
// straight-line fly-by: the body starts a far dot ahead, eases past close, exits
// to the side and behind — s is scene-seconds relative to the leg centre.
float3 homeCenter(float s, float legHalf, float dClose, float2 drift, float2 off) {
    float w = s / legHalf;
    float aw = min(abs(w), 1.45);
    float ease = sign(w) * pow(aw, 1.7);   // >1 exponent -> lingers near closest
    float travel = ease * 42.0;
    return float3(off.x + drift.x * ease, off.y + drift.y * ease, dClose - travel);
}

// fixed-body surface shading — no seeds, these are OUR planets
float3 homeSurface(int kind, float3 ns, float lat, float lon, float gt,
                   thread float3 &emis, thread float &oceanMask) {
    emis = float3(0.0);
    oceanMask = 0.0;
    float3 col;
    if (kind == 1) {
        // mercury: gray, heavily cratered
        float h = fbm(ns * 3.4 + 21.0, 5);
        float cr = ridged(ns * 4.2 + 7.0, 4);
        col = mix(float3(0.28, 0.27, 0.25), float3(0.52, 0.50, 0.47), h);
        col *= 1.0 - 0.45 * smoothstep(0.5, 0.85, cr);
    } else if (kind == 2) {
        // venus: creamy, near-featureless cloud deck
        float c = fbm(ns * 2.0 + float3(gt * 0.01, 0.0, 0.0) + 13.0, 4);
        col = mix(float3(0.80, 0.71, 0.48), float3(0.97, 0.91, 0.72), c);
        col = mix(col, float3(0.90, 0.83, 0.62), 0.45);
    } else if (kind == 3) {
        // EARTH: blue oceans, green/brown land, swirling clouds, ice caps, cities
        float h = fbm(ns * 2.6 + 5.0, 6);
        float sea = 0.545;                        // ~70% ocean, like the real thing
        float land = smoothstep(sea - 0.02, sea + 0.02, h);
        float3 ocean = mix(float3(0.015, 0.07, 0.22), float3(0.03, 0.20, 0.42),
                           smoothstep(sea - 0.20, sea, h));
        float3 veg = mix(float3(0.05, 0.28, 0.08), float3(0.24, 0.36, 0.13),
                         smoothstep(sea, sea + 0.14, h));
        float3 ground = mix(veg, float3(0.52, 0.44, 0.30), smoothstep(sea + 0.18, sea + 0.38, h));
        col = mix(ocean, ground, land);
        oceanMask = 1.0 - land;
        float cap = smoothstep(0.66, 0.80, abs(lat) + 0.10 * fbm(ns * 5.0 + 31.0, 3));
        col = mix(col, float3(0.94, 0.97, 1.0), cap);
        float cl = smoothstep(0.50, 0.72,
                    fbm(ns * 3.1 + float3(gt * 0.015, 0.0, gt * 0.006) + 9.0, 5));
        float landNoCloud = land * (1.0 - cl);
        col = mix(col, float3(1.0), cl * 0.9);
        oceanMask *= (1.0 - cl);
        // night-side city lights — sparse soft points, gated to dark side by caller
        float2 cc = float2(lon * 58.0, lat * 44.0);
        float2 cid = floor(cc);
        float2 cf = fract(cc) - 0.5;
        float cp = hash21(cid);
        float2 jit = (hash22(cid) - 0.5) * 0.5;
        float city = step(0.80, cp) * exp(-dot(cf - jit, cf - jit) * 26.0);
        float flick = 0.7 + 0.3 * sin(gt * 3.0 + cp * 50.0);
        emis = float3(1.0, 0.82, 0.48) * city * landNoCloud * flick;
    } else if (kind == 4) {
        // mars: rust red, dark albedo regions, polar cap
        float h = fbm(ns * 3.0 + 17.0, 5);
        col = mix(float3(0.42, 0.19, 0.09), float3(0.74, 0.37, 0.18), h);
        float dark = smoothstep(0.35, 0.62, fbm(ns * 1.8 + 3.0, 4));
        col = mix(col, float3(0.34, 0.17, 0.11), dark * 0.5);
        float cap = smoothstep(0.80, 0.90, abs(lat));
        col = mix(col, float3(0.95, 0.96, 1.0), cap);
    } else if (kind == 5) {
        // jupiter: tan/brown bands + Great Red Spot
        float turb = fbm(ns * 2.6 + float3(gt * 0.01, 0.0, 0.0) + 9.0, 5);
        float band = sin(lat * 14.0 + turb * 2.2);
        float band2 = sin(lat * 7.0 - turb * 1.6);
        float3 c1 = float3(0.84, 0.66, 0.44);   // tan zone
        float3 c2 = float3(0.40, 0.23, 0.12);   // deep rust belt
        float3 c3 = float3(0.95, 0.90, 0.78);   // bright zone
        col = mix(c1, c2, smoothstep(-0.25, 0.25, band));
        col = mix(col, c3, smoothstep(0.2, 0.9, band2) * 0.5);
        col *= 0.88 + 0.24 * turb;
        // Great Red Spot in the southern hemisphere
        float slat = -0.34, slon = 1.4;
        float2 sd = float2((lat - slat) * 2.4, sin(lon - slon - gt * 0.008) * cos(lat) * 1.3);
        float spot = exp(-dot(sd, sd) * 6.0);
        col = mix(col, float3(0.80, 0.30, 0.16), spot * 0.9);
    } else if (kind == 6) {
        // saturn: pale gold bands (rings drawn separately)
        float turb = fbm(ns * 2.4 + float3(gt * 0.008, 0.0, 0.0) + 15.0, 4);
        float band = sin(lat * 11.0 + turb * 2.5);
        float3 c1 = float3(0.86, 0.77, 0.55);
        float3 c2 = float3(0.72, 0.62, 0.42);
        col = mix(c1, c2, 0.5 + 0.5 * band);
        col *= 0.92 + 0.16 * turb;
    } else {
        // moon: gray with dark maria
        float h = fbm(ns * 3.2 + 41.0, 5);
        float maria = smoothstep(0.42, 0.60, fbm(ns * 1.6 + 5.0, 4));
        col = mix(float3(0.36, 0.35, 0.33), float3(0.58, 0.57, 0.55), h);
        col = mix(col, float3(0.20, 0.20, 0.21), maria * 0.6);
        float cr = ridged(ns * 5.0 + 7.0, 4);
        col *= 1.0 - 0.3 * smoothstep(0.6, 0.9, cr);
    }
    return col;
}

float3 homeScene(float2 uv, float t, float4 scn, float4 pal, float gt) {
    float seed = scn.x;
    float dur = max(scn.w, 1.0);

    // itinerary of OUR system; two orderings for variety, earth always central
    const int kA[6] = {0, 2, 3, 4, 5, 6};   // sun, venus, EARTH, mars, jupiter, saturn
    const int kB[6] = {0, 1, 3, 4, 6, 5};   // sun, mercury, EARTH, mars, saturn, jupiter
    bool va = hash11(seed * 3.3) > 0.5;

    // per-leg durations from dwell weights
    float legDur[6];
    float Tc[6];
    float sumW = 0.0;
    for (int k = 0; k < 6; k++) { sumW += dwellW(va ? kA[k] : kB[k]); }
    float acc = 0.0;
    for (int k = 0; k < 6; k++) {
        int kd = va ? kA[k] : kB[k];
        legDur[k] = dwellW(kd) / sumW * dur;
        Tc[k] = acc + legDur[k] * 0.5;
        acc += legDur[k];
    }

    float3 ro = float3(0.0);
    float3 rd = normalize(float3(uv, 1.45));
    float2 rxy = rot2(0.03 * sin(gt * 0.05) + gt * 0.0018) * rd.xy;
    rd.x = rxy.x; rd.y = rxy.y;

    // one consistent light-source direction for the whole tour
    float3 sunToward = normalize(float3(-0.62, 0.20, -0.24));
    float3 sunColG = float3(1.0, 0.93, 0.78);

    float3 col = spaceBG(uv + seed, seed + 2.0, pal, gt, 0.32);
    // fly-through star layers streaming outward = a sense of travel
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float ph = fract(fi / 3.0 - t * 0.03 + hash11(seed * 2.0 + fi));
        float depth = 0.06 + 0.94 * ph;
        float2 q = uv * depth * 6.0 + (hash22(float2(fi, seed * 7.0)) - 0.5) * 9.0;
        float fade = smoothstep(1.0, 0.8, ph) * smoothstep(0.0, 0.1, ph);
        col += starLayerFast(q, 0.12, seed * 5.0 + fi * 13.0, gt) * fade * 0.5;
    }

    // place every stop's body along the fly path
    float3 cen[6]; float Rr[6]; int kd6[6]; bool act[6];
    float3 eCenter = float3(0.0); bool eAct = false;
    for (int k = 0; k < 6; k++) {
        int kd = va ? kA[k] : kB[k];
        float fk = float(k);
        float s = t - Tc[k];
        float lh = legDur[k] * 0.5;
        bool a = abs(s / lh) < 1.45;
        float hk = hash11(seed * 1.7 + fk * 4.1);
        float2 drift = float2(cos(hk * 6.28318), sin(hk * 6.28318)) * mix(2.6, 3.8, hash11(seed * 2.3 + fk));
        float2 off = (hash22(float2(fk * 3.3, seed * 5.0)) - 0.5) * 0.5;
        cen[k] = homeCenter(s, lh, bodyDClose(kd), drift, off);
        Rr[k] = bodyR(kd);
        kd6[k] = kd;
        act[k] = a;
        if (kd == 3) { eCenter = cen[k]; eAct = a; }
    }

    // the moon rides alongside earth during the hero leg — mostly lateral so it
    // stays inside the (wide) frame rather than swinging behind in depth
    float ma = gt * 0.22 + seed * 3.0;
    float3 moonC = eCenter + float3(cos(ma) * 1.25, 0.30 * sin(ma * 0.6), sin(ma) * 0.55);
    float moonR = 0.15;
    bool moonAct = eAct;

    // nearest sphere the ray hits
    float bestT = 1e9; int bestI = -1;
    for (int k = 0; k < 6; k++) {
        if (!act[k]) continue;
        float3 oc = ro - cen[k];
        float b = dot(oc, rd);
        float disc = b * b - (dot(oc, oc) - Rr[k] * Rr[k]);
        if (disc > 0.0) {
            float tH = -b - sqrt(disc);
            if (tH > 0.0 && tH < bestT) { bestT = tH; bestI = k; }
        }
    }
    if (moonAct) {
        float3 oc = ro - moonC;
        float b = dot(oc, rd);
        float disc = b * b - (dot(oc, oc) - moonR * moonR);
        if (disc > 0.0) {
            float tH = -b - sqrt(disc);
            if (tH > 0.0 && tH < bestT) { bestT = tH; bestI = 6; }
        }
    }

    // sun corona + phase-lit halos of the other active bodies (approaching dots)
    for (int k = 0; k < 6; k++) {
        if (!act[k]) continue;
        if (k == bestI && kd6[k] != 0) continue;
        float3 w = cen[k] - ro;
        if (dot(rd, w) <= 0.0) continue;
        float dca = length(cross(rd, w));
        if (kd6[k] == 0) {
            float Rs = Rr[k];
            col += sunColG * exp(-max(dca - Rs, 0.0) * (2.6 / Rs)) * 0.45;
            col += sunColG * exp(-max(dca - Rs, 0.0) * (1.1 / Rs)) * 0.035;
        } else if (dca > Rr[k]) {
            float phase = 0.35 + 0.65 * max(dot(normalize(ro - cen[k]), sunToward), 0.0);
            col += bodyTint(kd6[k]) * exp(-(dca - Rr[k]) * 6.0 / Rr[k]) * 0.35 * phase;
        }
    }
    if (moonAct && bestI != 6) {
        float3 w = moonC - ro;
        if (dot(rd, w) > 0.0) {
            float dca = length(cross(rd, w));
            if (dca > moonR) col += bodyTint(7) * exp(-(dca - moonR) * 6.0 / moonR) * 0.25;
        }
    }

    // shade the hero body we actually hit
    if (bestI >= 0) {
        float3 center = (bestI == 6) ? moonC : cen[bestI];
        float R = (bestI == 6) ? moonR : Rr[bestI];
        int kind = (bestI == 6) ? 7 : kd6[bestI];
        float3 pos = ro + rd * bestT;
        float3 nGeo = normalize(pos - center);

        float3 pcol;
        if (kind == 0) {
            // sun surface: granulation + limb brightening
            float gran = fbm(nGeo * 14.0 + float3(0.0, 0.0, gt * 0.06), 4);
            float limb = pow(max(dot(nGeo, -rd), 0.0), 0.4);
            float3 base = mix(float3(1.05, 0.62, 0.18), float3(1.05, 0.98, 0.75), gran);
            pcol = base * (0.85 + 0.60 * limb);
        } else {
            // spin + tilt so features read as a rotating globe
            float3 ns = nGeo;
            float tilt = 0.24;
            float2 nyz = rot2(tilt) * float2(ns.y, ns.z); ns.y = nyz.x; ns.z = nyz.y;
            float spin = gt * 0.03 + float(kind) * 1.7;
            float2 nxz = rot2(spin) * float2(ns.x, ns.z); ns.x = nxz.x; ns.z = nxz.y;
            float lat = clamp(ns.y, -1.0, 1.0);
            float lon = atan2(ns.z, ns.x);

            float3 emis; float oceanMask;
            float3 surf = homeSurface(kind, normalize(ns), lat, lon, gt, emis, oceanMask);

            float3 n = nGeo;
            if (kind == 1 || kind == 3 || kind == 4 || kind == 7) {
                float3 t1 = normalize(cross(nGeo, float3(0.0, 1.0, 0.001)));
                float3 t2 = cross(nGeo, t1);
                float e = 0.02;
                float h0 = fbm(ns * 6.0 + float(kind) * 5.0, 4);
                float hx = fbm((ns + t1 * e) * 6.0 + float(kind) * 5.0, 4);
                float hy = fbm((ns + t2 * e) * 6.0 + float(kind) * 5.0, 4);
                n = normalize(nGeo + (t1 * (h0 - hx) + t2 * (h0 - hy)) * 1.4);
            }

            float difG = dot(nGeo, sunToward);
            float dif = max(dot(n, sunToward), 0.0);
            // venus: thick cloud deck scatters light past the terminator — wrap it
            if (kind == 2) dif = pow(max(dot(n, sunToward) * 0.5 + 0.5, 0.0), 1.5);
            pcol = surf * (0.03 + 1.2 * pow(dif, 0.9));
            pcol *= (0.4 * sunColG + 0.6);
            // night-side city lights (earth)
            float night = smoothstep(-0.02, -0.30, difG);
            pcol += emis * night * 1.5;
            // ocean glint
            float spec = pow(max(dot(reflect(-sunToward, n), -rd), 0.0), 60.0);
            pcol += sunColG * spec * oceanMask * dif * 0.7;
            // sunset band along the terminator
            float sunset = exp(-pow((difG - 0.02) * 8.0, 2.0));
            if (kind == 3 || kind == 4) pcol += float3(0.95, 0.45, 0.2) * sunset * 0.16;
            // atmosphere rim where sunlight scatters
            float3 atmo = (kind == 3) ? float3(0.35, 0.55, 1.0) :
                          (kind == 2) ? float3(0.90, 0.82, 0.55) :
                          (kind == 5 || kind == 6) ? float3(0.80, 0.70, 0.52) :
                          float3(0.50, 0.50, 0.60);
            float fres = pow(1.0 - max(dot(nGeo, -rd), 0.0), 2.8);
            pcol += atmo * fres * (0.42 * pow(dif, 0.9));   // rim gated to lit sky
        }

        float dcaB = length(cross(rd, center - ro));
        float alpha = smoothstep(R, R - (bestT * 0.002 + 0.001), dcaB);
        col = mix(col, pcol, alpha);
    }

    // Saturn's rings — bright, prominent, depth-tested so the globe occludes them
    for (int k = 0; k < 6; k++) {
        if (!act[k] || kd6[k] != 6) continue;
        float3 sc = cen[k]; float sR = Rr[k];
        float3 rn = normalize(float3(0.34, 1.0, 0.16));
        float denom = dot(rd, rn);
        if (abs(denom) > 1e-4) {
            float tp = dot(sc - ro, rn) / denom;
            if (tp > 0.0 && tp < bestT) {
                float3 hp = ro + rd * tp - sc;
                float rr = length(hp) / sR;
                if (rr > 1.18 && rr < 2.35) {
                    float band = 0.5 + 0.5 * noise3(float3(rr * 55.0, 3.0, 1.0));
                    float cassini = smoothstep(0.03, 0.07, abs(rr - 1.72));   // gap
                    float edge = smoothstep(1.18, 1.26, rr) * smoothstep(2.35, 2.16, rr);
                    float rl = 0.4 + 0.6 * abs(dot(rn, sunToward));
                    float graze = smoothstep(0.02, 0.14, abs(denom));
                    float3 ringCol = float3(0.87, 0.81, 0.63) * rl * (0.55 + 0.5 * band);
                    col = mix(col, ringCol, clamp(edge * cassini * graze * (0.6 + 0.4 * band), 0.0, 0.92));
                }
            }
        }
    }

    return col;
}

// ---------- scene 7: Cassini passage / Saturn and Enceladus ----------
// A single camera flight through one persistent system: the ring material,
// globe, small ice fragments and moon all retain their world positions. World
// units are Saturn radii; Enceladus is enlarged for a readable cinematic pass.

float ringVoyageHit(float3 ro, float3 rd, float3 c, float3 axes) {
    float3 q = (ro - c) / axes;
    float3 d = rd / axes;
    float a = dot(d, d), b = dot(q, d);
    float disc = b * b - a * (dot(q, q) - 1.0);
    if (disc < 0.0) return 1e8;
    float v = (-b - sqrt(disc)) / a;
    return v > 0.0001 ? v : 1e8;
}

float3 ringVoyageSpline(float3 a, float3 b, float3 c, float3 d, float x) {
    return 0.5 * ((2.0 * b) + (-a + c) * x
        + (2.0 * a - 5.0 * b + 4.0 * c - d) * x * x
        + (-a + 3.0 * b - 3.0 * c + d) * x * x * x);
}

float ringVoyageOpacity(float r, float footprint) {
    // C, B, A, Cassini division, Encke gap and the isolated F ring.
    float feather = max(footprint, 0.0007);
    float inner = smoothstep(1.22 - feather, 1.23 + feather, r);
    float outer = 1.0 - smoothstep(2.265 - feather, 2.275 + feather, r);
    float denseB = smoothstep(1.49, 1.54, r) * (1.0 - smoothstep(1.94, 1.95, r));
    float cassini = smoothstep(1.947 - feather, 1.953 + feather, r)
                  * (1.0 - smoothstep(2.024 - feather, 2.031 + feather, r));
    float encke = 1.0 - smoothstep(0.004 + feather, 0.008 + feather, abs(r - 2.213));
    // Integrate fine bands out as they become subpixel, avoiding moire at entry.
    float detail = sin(r * 383.0) * exp(-pow(footprint * 383.0, 2.0)) * 0.12
                 + sin(r * 1103.0 + sin(r * 73.0)) * exp(-pow(footprint * 1103.0, 2.0)) * 0.08;
    float broad = 0.80 + 0.20 * noise3(float3(r * 79.0, 7.0, 12.0));
    float opacity = (0.35 + denseB * 0.57 + smoothstep(2.03, 2.07, r) * 0.23)
                  * (broad + detail) * inner * outer * (1.0 - cassini * 0.975) * (1.0 - encke * 0.87);
    float fRing = exp(-pow((r - 2.326) / max(0.003, feather), 2.0))
                * min(1.0, 0.003 / feather) * 0.52;
    return clamp(opacity + fRing, 0.0, 0.97);
}

float3 ringVoyageIce(float3 n, float3 light, float3 rd, float gt) {
    float frost = fbm(n * 10.0 + 52.0, 3);
    float3 base = mix(float3(0.44, 0.56, 0.64), float3(0.91, 0.96, 1.0), frost);
    // South-pole stereographic coordinates have no seam at the geyser field.
    float2 q = n.xz / max(1.0 - n.y, 0.25) * 16.0;
    float2 cell = floor(q);
    float rim = 0.0, floorDark = 0.0;
    float2 slope = float2(0.0);
    for (int iy = -1; iy <= 1; iy++) {
        for (int ix = -1; ix <= 1; ix++) {
            float2 id = cell + float2(ix, iy);
            if (hash21(id + 39.0) < 0.48) continue;
            float2 dv = q - id - (0.16 + hash22(id + 11.0) * 0.68);
            float radius = 0.09 + pow(hash21(id + 27.0), 1.7) * 0.31;
            float d = length(dv);
            d *= 1.0 + sin(atan2(dv.y, dv.x) * 3.0 + hash21(id) * 9.0) * 0.055;
            float ring = exp(-pow((d - radius) * 27.0, 2.0));
            float bowl = 1.0 - smoothstep(radius * 0.32, radius, d);
            rim += ring;
            floorDark += bowl * 0.12;
            slope += dv / max(d, 0.01) * (d - radius) * ring * 6.5;
        }
    }
    float terrain = (1.0 - smoothstep(0.45, 0.72, n.y)) * smoothstep(-0.96, -0.55, n.y);
    terrain *= 1.0 - smoothstep(0.35, 0.75, max(fwidth(q.x), fwidth(q.y)));
    base *= 1.0 + terrain * (rim * 0.075 - floorDark);
    base *= 0.90 + 0.19 * noise3(n * 76.0 + 18.0);
    float3 bump = normalize(n + float3(slope.x, 0.0, slope.y) * terrain * 0.22);
    // Four curved blue tiger stripes; their narrow cores remain dark cracks.
    float polar = smoothstep(-0.38, -0.79, n.y) * (1.0 - smoothstep(0.35, 0.68, abs(n.z)));
    float line = 1.0;
    for (int j = 0; j < 4; j++) {
        float fj = float(j);
        float stripe = n.x - (fj - 1.5) * 0.15
                     + 0.043 * sin(n.z * 11.0 + fj * 0.6)
                     + 0.012 * sin(n.z * 37.0 + fj);
        line = min(line, abs(stripe));
    }
    float crack = (1.0 - smoothstep(0.002, 0.006, line)) * polar;
    float bank = exp(-pow((line - 0.011) * 94.0, 2.0)) * polar;
    base = mix(base, float3(0.24, 0.38, 0.46), crack * 0.65);
    base += float3(0.09, 0.16, 0.19) * bank;
    float diffuse = max(dot(bump, light), 0.0);
    float saturnBounce = max(dot(n, normalize(float3(-3.7, 0.1, 1.34))), 0.0);
    float3 shade = base * (0.024 + float3(1.0, 0.94, 0.83) * diffuse * 1.6
                        + float3(0.11, 0.095, 0.067) * saturnBounce);
    float sparkle = pow(max(dot(reflect(-light, bump), -rd), 0.0), 72.0);
    return shade + float3(0.58, 0.75, 0.95) * sparkle * diffuse * 0.22;
}

// A compact erf approximation for analytic, depth-clipped Gaussian ice jets.
float ringVoyageErf(float x) {
    float a = abs(x);
    float q = 1.0 + 0.278393 * a + 0.230389 * a * a
            + 0.000972 * a * a * a + 0.078108 * a * a * a * a;
    return sign(x) * (1.0 - 1.0 / (q * q * q * q));
}

float3 ringVoyageScene(float2 uv, float t, float4 scn, float4 pal, float gt) {
    float p = clamp(t / max(scn.w, 1.0), 0.0, 1.0);
    float seed = scn.x;
    // Catmull-Rom knots keep position AND velocity continuous between stages.
    // The flight enters from high above the equator, follows the A ring, then
    // leaves its outer edge before dipping beneath Enceladus's south pole.
    const float3 camera[9] = {
        float3(0.0, 15.0, -64.0), float3(0.0, 5.0, -20.0),
        float3(0.0, 1.4, -6.8), float3(0.65, 0.45, -3.65),
        float3(1.50, 0.075, -1.55), float3(3.85, -0.36, -1.69),
        float3(4.02, -0.19, -1.46), float3(4.65, -0.40, -1.82),
        float3(7.4, -1.3, -3.1)
    };
    const float3 gaze[9] = {
        float3(0.0), float3(0.0), float3(0.0), float3(-0.12, 0.0, 0.0),
        float3(0.2, 0.0, 0.0), float3(3.62, -0.04, -1.31),
        float3(3.64, -0.02, -1.26), float3(3.1, 0.0, -1.1),
        float3(1.8, 0.0, -0.6)
    };
    float segment = p * 8.0;
    int k = min(int(segment), 7);
    float f = min(segment - float(k), 1.0);
    float3 ro = ringVoyageSpline(camera[max(0, k-1)], camera[k], camera[k+1], camera[min(8, k+2)], f);
    float3 look = ringVoyageSpline(gaze[max(0, k-1)], gaze[k], gaze[k+1], gaze[min(8, k+2)], f);
    float3 forward = normalize(look - ro);
    float3 right = normalize(cross(float3(0.0, 1.0, 0.0), forward));
    float3 up = cross(forward, right);
    float bank = -0.10 + 0.06 * sin(p * 5.0 + hash11(seed) * 1.4);
    float2 screen = rot2(bank) * uv;
    float3 rd = normalize(forward * 1.22 + right * screen.x + up * screen.y);
    float rayFootprint = max(length(dfdx(rd)), length(dfdy(rd)));
    float3 light = normalize(float3(-0.25, 0.36, -0.90));
    const float3 saturnAxes = float3(1.0, 0.90, 1.0);
    const float3 moon = float3(3.72, 0.0, -1.34);
    const float moonRadius = 0.145;

    // Background direction is world-locked, so the sky banks with the camera.
    float2 sky = float2(atan2(rd.x, rd.z), asin(clamp(rd.y, -1.0, 1.0)));
    float3 col = float3(0.0015, 0.002, 0.0035);
    col += starLayer(sky * 12.0 + seed, 0.11, seed + 34.0, gt) * 0.70;
    col += starLayerFast(sky * 35.0 + seed * 4.0, 0.16, seed + 11.0, gt) * 0.28;
    float bestT = ringVoyageHit(ro, rd, float3(0.0), saturnAxes);
    int body = bestT < 1e7 ? 0 : -1;
    float mt = ringVoyageHit(ro, rd, moon, float3(moonRadius));
    if (mt < bestT) { bestT = mt; body = 1; }

    // Small permanent ice fragments resolve naturally as the camera skims past.
    float3 fragmentC = float3(0.0); float fragmentR = 1.0;
    for (int j = 0; j < 10; j++) {
        float fj = float(j);
        float angle = -0.61 - hash11(fj * 8.4 + seed) * 0.47;
        float radius = 2.045 + hash11(fj * 11.7 + seed * 2.0) * 0.20;
        float3 c = float3(cos(angle) * radius, 0.009 + hash11(fj + 18.0) * 0.013, sin(angle) * radius);
        float r = 0.006 + hash11(fj * 21.0 + seed) * 0.010;
        float hit = ringVoyageHit(ro, rd, c, float3(r, r * 0.73, r * 0.89));
        if (hit < bestT) { bestT = hit; body = 2; fragmentC = c; fragmentR = r; }
    }

    if (body >= 0) {
        float3 skyColor = col;
        float3 pos = ro + rd * bestT;
        if (body == 0) {
            float3 n = normalize(pos / (saturnAxes * saturnAxes));
            float3 ns = normalize(pos / saturnAxes);
            float2 spun = rot2(gt * 0.026) * ns.xz;
            ns.x = spun.x; ns.z = spun.y;
            float3 unusedEmission; float unusedOcean;
            float3 surf = homeSurface(6, ns, ns.y, atan2(ns.z, ns.x), gt, unusedEmission, unusedOcean);
            float bandFoot = max(fwidth(ns.y), 0.00001);
            float fine = sin(ns.y * 155.0 + noise3(ns * 11.0) * 2.1)
                       * exp(-pow(bandFoot * 155.0, 2.0));
            surf *= 0.94 + fine * 0.055;
            // A restrained polar hexagon and dark vortex, visible from entry.
            float poleR = length(ns.xz);
            float hexR = 0.22 + cos(atan2(ns.z, ns.x) * 6.0) * 0.010;
            float polar = smoothstep(0.84, 0.94, ns.y);
            surf = mix(surf, float3(0.40, 0.49, 0.47), (1.0 - smoothstep(hexR, hexR + 0.025, poleR)) * polar * 0.48);
            surf *= 1.0 - exp(-poleR * poleR * 1600.0) * polar * 0.50;
            float ringShadow = 1.0;
            float shadowT = -pos.y / light.y;
            if (shadowT > 0.0) {
                float rr = length((pos + light * shadowT).xz);
                ringShadow -= ringVoyageOpacity(rr, 0.006) * 0.88;
            }
            float diffuse = max(dot(n, light), 0.0);
            col = surf * (float3(0.022, 0.024, 0.029) + float3(1.0, 0.94, 0.82) * diffuse * ringShadow * 1.45);
            float rim = pow(1.0 - max(dot(n, -rd), 0.0), 3.3);
            col += float3(0.72, 0.63, 0.37) * rim * pow(diffuse, 0.6) * 0.20;
        } else if (body == 1) {
            float3 n = normalize(pos - moon);
            col = ringVoyageIce(n, light, rd, gt);
        } else {
            float3 n = normalize((pos - fragmentC) / float3(1.0, 0.73 * 0.73, 0.89 * 0.89));
            float rough = noise3((pos - fragmentC) / fragmentR * 8.0 + seed);
            col = float3(0.59, 0.66, 0.69) * (0.03 + max(dot(n, light), 0.0) * (0.75 + rough * 0.55));
        }
        float3 center = body == 0 ? float3(0.0) : (body == 1 ? moon : fragmentC);
        float3 axes = body == 0 ? saturnAxes : (body == 1 ? float3(moonRadius) : fragmentR * float3(1.0, 0.73, 0.89));
        float3 q = (ro - center) / axes, d = rd / axes;
        float limbDistance = length(q - d * dot(q, d) / dot(d, d));
        float feather = max(bestT * rayFootprint / min(axes.x, min(axes.y, axes.z)), 0.00001);
        col = mix(skyColor, col, smoothstep(1.0, 1.0 - feather, limbDistance));
    }

    // Ring plane is depth-tested against every foreground body. Saturn's shadow
    // is evaluated in world space and connects correctly to its night side.
    if (abs(rd.y) > 0.00001) {
        float rt = -ro.y / rd.y;
        if (rt > 0.0 && rt < bestT) {
            float3 pos = ro + rd * rt;
            float radius = length(pos.xz);
            if (radius > 1.20 && radius < 2.35) {
                float footprint = max(fwidth(radius), 0.00003);
                float opacity = ringVoyageOpacity(radius, footprint);
                // Optical path through a thin layer becomes denser at grazing angles.
                opacity = 1.0 - pow(max(1.0 - opacity, 0.0001), 0.45 / max(abs(rd.y), 0.09));
                float3 q = pos / saturnAxes, d = light / saturnAxes;
                float projection = dot(q, d) / dot(d, d);
                float nearLine = length(q - d * min(projection, 0.0));
                float shadow = projection < 0.0 ? smoothstep(0.985, 1.018, nearLine) : 1.0;
                float cBand = 0.5 + 0.5 * sin(radius * 29.0 + noise3(float3(radius * 100.0, 2.0, 8.0)));
                float3 ringCol = mix(float3(0.37, 0.31, 0.21), float3(0.79, 0.74, 0.62), cBand * 0.6 + 0.4);
                float transmitted = ro.y < 0.0 ? 0.51 : 1.0;
                ringCol *= (0.026 + shadow * (0.65 + light.y * 0.6)) * transmitted;
                // Close, fixed grains provide travel parallax without a sprite handoff.
                float grain = noise3(float3(pos.xz * 620.0, 9.0));
                float detail = 1.0 - smoothstep(0.006, 0.018, footprint);
                ringCol *= 1.0 + (grain - 0.5) * detail * 0.43;
                col = mix(col, ringCol, opacity);
            }
        }
    }

    // Enceladus south-polar water-ice plumes. An overlapping chain of anisotropic
    // Gaussians forms each widening jet. Integrating each Gaussian along the ray
    // avoids noisy under-sampling at the narrow vents and clips behind the moon.
    float3 plumeCenter = moon + float3(0.0, -0.34, 0.0);
    float3 oc = ro - plumeCenter;
    float b = dot(oc, rd);
    float disc = b * b - (dot(oc, oc) - 0.38 * 0.38);
    if (disc > 0.0) {
        float root = sqrt(disc);
        float start = max(0.0, -b - root), end = min(bestT, -b + root);
        if (end > start) {
            float optical = 0.0;
            for (int j = 0; j < 4; j++) {
                float fj = float(j);
                for (int s = 0; s < 6; s++) {
                    float height = 0.016 + float(s) * 0.078;
                    float2 vent = float2((fj - 1.5) * 0.018, sin(fj * 2.7) * 0.020);
                    float2 drift = float2((fj - 1.5) * 0.075, cos(fj * 3.1) * 0.055) * height;
                    float width = 0.005 + height * (0.065 + fj * 0.012);
                    float3 center = moon + float3(vent.x + drift.x, -moonRadius * 0.92 - height, vent.y + drift.y);
                    float3 axes = float3(width, 0.057 + height * 0.09, width);
                    float3 q = (ro - center) / axes, d = rd / axes;
                    float a = dot(d, d), ab = dot(q, d);
                    float mean = -ab / a;
                    float3 perpendicular = q + d * mean;
                    float density = exp(-dot(perpendicular, perpendicular));
                    if (density < 0.0001) continue;
                    float invSigma = sqrt(a);
                    float clip = 0.5 * (ringVoyageErf((end - mean) * invSigma)
                                      - ringVoyageErf((start - mean) * invSigma));
                    float billow = 0.82 + 0.18 * sin(height * 43.0 - t * 1.1 + fj * 1.7);
                    optical += density * (1.77245 / invSigma) * clip
                             * exp(-height * 4.0) * billow * 25.0;
                }
            }
            float scattering = 0.58 + pow(max(dot(rd, light), 0.0), 6.0) * 1.8;
            float alpha = 1.0 - exp(-optical);
            col = col * (1.0 - alpha * 0.36) + float3(0.53, 0.73, 0.98) * alpha * scattering;
        }
    }
    return col;
}

// ---------- scene 8: star nursery / sculpted dust pillars ----------
// An imagined three-dimensional stellar nursery, inspired by NASA observations.
// No photograph is projected onto the volume; dust has genuine depth/parallax.
float3 nurseryScene(float2 uv, float t, float4 scn, float4 pal, float gt) {
    float seed = scn.x;
    float prog = clamp(t / max(scn.w, 1.0), 0.0, 1.0);
    float travel = smoothstep(0.0, 1.0, prog);
    float3 ro = float3(mix(-1.5, 3.4, travel), 0.65 + 0.35 * sin(prog * 3.14),
                      mix(-44.0, -1.4, travel));
    float3 target = float3(0.0, 0.1, 2.8);
    float3 fwd = normalize(target - ro);
    float3 rightv = normalize(cross(fwd, float3(0.0, 1.0, 0.0)));
    float3 upv = cross(rightv, fwd);
    float2 bank = rot2(0.045 * sin(prog * 4.0)) * uv;
    float3 rd = normalize(fwd * 1.45 + rightv * bank.x + upv * bank.y);
    float2 sky = rd.xy / max(abs(rd.z), 0.25);
    float3 bg = float3(0.0009, 0.0015, 0.003);
    bg += starLayerFast(sky * 27.0 + seed, 0.09, seed + 4.0, gt) * 0.65;
    bg += starLayerFast(sky * 51.0 + seed, 0.07, seed + 9.0, gt) * 0.3;

    // Embedded young stars: rays pass through the same absorbing dust as
    // the background, so stars disappear naturally behind the pillars.
    float3 lightPos = float3(-4.2, 4.8, 0.5);
    bg += sunGlow(ro, rd, lightPos, 0.045, float3(0.61, 0.80, 1.0), 1e6, gt, seed) * 0.7;
    bg += sunGlow(ro, rd, float3(1.7, 1.8, 2.4), 0.018, float3(1.0, 0.59, 0.25), 1e6, gt, seed + 7.0) * 0.45;

    // Each pillar has its own tight ellipsoid bound. Only rays actually
    // crossing dust evaluate fractal density, with six stratified samples
    // across the short chord rather than marching through an empty volume.
    float starts[4], ends[4]; float3 centers[4], axes[4];
    for (int k = 0; k < 4; k++) {
        float fk = float(k), h = hash11(seed + fk * 17.1);
        centers[k] = float3((fk - 1.5) * 2.4, -5.0 + h * 1.5, sin(fk * 3.1) * 0.8);
        axes[k] = float3(0.98 + 0.32 * h, 8.0 + 1.6 * h, 1.08);
        float3 q = (ro - centers[k]) / axes[k];
        float3 d = rd / axes[k];
        float aa = dot(d, d), bb = dot(q, d);
        float disc = bb * bb - aa * (dot(q, q) - 1.0);
        starts[k] = 1e6; ends[k] = 1e6;
        if (disc > 0.0) {
            float nearT = (-bb - sqrt(disc)) / aa;
            float farT = (-bb + sqrt(disc)) / aa;
            if (farT > 0.0) { starts[k] = max(nearT, 0.0); ends[k] = farT; }
        }
    }
    float trans = 1.0;
    float3 accum = float3(0.0);
    float3 lamp = normalize(float3(-0.7, 0.85, -0.7));
    for (int layer = 0; layer < 4; layer++) {
        int nearest = 0;
        for (int k = 1; k < 4; k++) if (starts[k] < starts[nearest]) nearest = k;
        float lo = starts[nearest], hi = ends[nearest];
        if (lo > 1e5) break;
        starts[nearest] = 1e6;
        float ds = (hi - lo) / 6.0;
        float jitter = 0.5 + 0.04 * (hash21(uv * 1100.0 + seed) - 0.5);
        for (int j = 0; j < 6; j++) {
            float3 p = ro + rd * (lo + (float(j) + jitter) * ds);
            float3 q = (p - centers[nearest]) / axes[nearest];
            float coarse = noise3(p * 1.0 + seed);
            float erosion = fbm(p * 2.7 + float3(seed, 0, 0), 2);
            q.x += 0.12 * sin(p.y * 1.3 + float(nearest) * 2.0);
            float shape = 1.0 - dot(q, q) - 0.24 * coarse;
            float density = smoothstep(0.03, 0.55, shape - (erosion - 0.35) * 1.2);
            if (density < 0.005) continue;
            float3 n = normalize(q / axes[nearest] + float3(0.02, 0.01, 0.0));
            float shade = max(dot(n, lamp), 0.0);
            float edge = pow(1.0 - density, 2.0);
            float detail = 0.35 + 1.8 * erosion * erosion;
            float3 lit = mix(float3(0.50, 0.20, 0.07), float3(0.11, 0.37, 0.44), smoothstep(-0.4, 2.5, p.y));
            float3 material = float3(0.008, 0.006, 0.009) + lit * (shade * 0.32 + edge * 0.18) * detail;
            float alpha = 1.0 - exp(-density * ds * 3.4);
            accum += trans * alpha * material;
            trans *= 1.0 - alpha;
            if (trans < 0.015) break;
        }
        if (trans < 0.015) break;
    }
    return accum + bg * trans;
}

// ---------- dispatch ----------

float3 renderScene(int type, float t, float4 scn, float4 pal, float2 uv, float gt,
                   texture2d<float> img) {
    if (type == 0) return cruiseScene(uv, t, scn, pal, gt);
    if (type == 1) return galaxyScene(uv, t, scn, pal, gt, img);
    if (type == 2) return planetScene(uv, t, scn, pal, gt);
    if (type == 4) return encounterScene(uv, t, scn, pal, gt);
    if (type == 5) return deepfieldScene(uv, t, scn, pal, gt, img);
    if (type == 6) return homeScene(uv, t, scn, pal, gt);
    if (type == 7) return ringVoyageScene(uv, t, scn, pal, gt);
    if (type == 8) return nurseryScene(uv, t, scn, pal, gt);
    return warpScene(uv, t, scn, pal, gt);
}

float3 acesish(float3 x) {
    return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}

float4 presentScene(float3 col, float2 frag, float2 resolution, float time) {
    col = acesish(col * 1.15);
    // vignette
    float2 vuv = frag / resolution - 0.5;
    col *= 1.0 - 0.32 * pow(dot(vuv, vuv) * 2.6, 1.4);
    // gamma (bgra8Unorm, manual)
    col = pow(max(col, 0.0), float3(1.0 / 2.2));
    // dither/grain to kill banding
    col += (hash21(frag * 0.71 + fract(time * 0.93) * 371.0) - 0.5) * 0.011;
    return float4(col, 1.0);
}

// Host eagerly builds each scene/subtype variant once. The compiler can then
// discard every unrelated branch and its register footprint from that pipeline.
constant int sceneKind [[function_constant(0)]];
constant int encounterKind [[function_constant(1)]];
constant bool linearOutput [[function_constant(2)]];

fragment float4 fscene(VOut in [[stage_in]], constant Uniforms &U [[buffer(0)]],
                       texture2d<float> img [[texture(0)]]) {
    float2 frag = in.uv * U.resolution;
    float2 uv = (frag - 0.5 * U.resolution) / max(U.resolution.y, 1.0);
    float4 scn = U.scnA;
    if (sceneKind == 4) scn.y = float(encounterKind);
    float3 col = renderScene(sceneKind, U.sceneTime, scn, U.palA, uv, U.time, img);
    if (linearOutput) {
        // Alpha carries the host's eased scene weight for additive blending.
        // Keep radiance representable in the RGBA16Float intermediate target.
        return float4(clamp(col, 0.0, 60000.0), U.transition);
    }
    return presentScene(col, frag, U.resolution, U.time);
}

fragment float4 fcomposite(VOut in [[stage_in]], constant Uniforms &U [[buffer(0)]],
                           texture2d<float> radiance [[texture(0)]]) {
    float3 col = radiance.read(uint2(in.pos.xy)).rgb;
    return presentScene(col, in.uv * U.resolution, U.resolution, U.time);
}
"""#
