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
    float n1 = fbm(p * 2.0 + float3(t * 0.004, 0.0, 0.0), 5);
    float n2 = fbm(p * 4.3 - float3(0.0, t * 0.003, t * 0.002), 4);
    float3 c1 = tint(pal.x, 0.75);
    float3 c2 = tint(pal.y, 0.8);
    float3 col = c1 * pow(n1, 3.2) * 0.34 + c2 * pow(n2, 4.0) * 0.26;
    // sparse dark dust silhouettes
    float dust = smoothstep(0.55, 0.85, fbm(p * 3.1 + 11.0, 4));
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
    float glow = exp(-d * 9.0) * 0.05 * bright;
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
    return miniSystem(p * s, h, gt) / (0.9 + s * 0.35);
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
    float ds = (t1 - t0) / 10.0;
    float3 acc = float3(0.0);
    float T = 1.0;
    float jit = hash21(grd.xy * 731.7 + seed) * ds;   // dither against banding
    for (int i = 0; i < 10; i++) {
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
    col += starLayer(uv * 13.0 + seed * 37.0, 0.10, seed + 3.0, t) * 0.85;
    col += starLayer(uv * 29.0 + seed * 53.0, 0.16, seed + 9.0, t) * 0.45;
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
        col += starLayer(q, 0.10, seed * 5.0 + fi * 13.0, gt) * fade * bright * 0.55;
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
    float3 col = spaceBG(uv * 0.8 + 3.0, seed + 0.5, pal, gt, 0.32);

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
            float3 ic = pow(max(img.sample(gsmp, iuv).rgb, 0.0), float3(2.2));
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
        float fog = fbm(float3(uv * 2.4, seed * 4.4 + gt * 0.01), 4);
        float wisp = fbm(float3(uv * 6.5 + 7.0, seed * 8.8 + gt * 0.015), 3);
        float lane = ridged(float3(uv * 3.4, seed * 6.2), 3);
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
        col = mix(float3(0.55, 0.68, 0.80), float3(0.85, 0.92, 0.99), n);
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
                         L * mix(0.55, 0.90, hash11(seed * 4.2)));
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
        pcol += atmoCol * fres * (0.02 + 0.55 * pow(dif1, 0.7));

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
    float h = fbm(float3(xz * 0.32, seed * 7.0), 5);
    float rdg = ridged(float3(xz * 0.20 + 11.0, seed * 3.0), 4);
    return mix(h, rdg, 0.45);
}

// inside the completed sphere: skim the inner surface — ocean, ranges, cities —
// with the captive sun overhead and the far shell as the "sky"
float3 dysonInterior(float2 uv, float t, float seed, float4 pal, float gt) {
    float3 rd = normalize(float3(uv, 1.45));
    float2 rxy = rot2(0.05 * sin(gt * 0.05)) * rd.xy;
    rd.x = rxy.x; rd.y = rxy.y;
    rd.y += 0.06 * sin(t * 0.18 + seed);          // gentle altitude swells
    rd = normalize(rd);

    float3 sunDir = normalize(float3(0.10, 1.0, 0.14));
    float2 fwd = float2(t * 1.5, t * 0.22);       // ground speed
    float3 col;

    if (rd.y < -0.015) {
        float tg = -1.25 / rd.y;
        float2 xz = fwd + rd.xz * tg;
        float h = interiorH(xz, seed);
        float e = 0.22;
        float hx = interiorH(xz + float2(e, 0.0), seed);
        float hz = interiorH(xz + float2(0.0, e), seed);
        // amplified slopes so ranges throw real relief shading
        float3 n = normalize(float3((h - hx) * 9.0, 1.0, (h - hz) * 9.0));
        float sea = 0.42;
        float3 gcol;
        float oce = 0.0;
        if (h < sea) {
            gcol = mix(float3(0.008, 0.05, 0.12), float3(0.03, 0.18, 0.26),
                       smoothstep(sea - 0.25, sea, h));
            n = normalize(float3(0.0, 1.0, 0.0) + 0.04 * float3(sin(xz.x * 3.0 + gt), 0.0, cos(xz.y * 2.7 + gt)));
            oce = 1.0;
        } else {
            float3 low = mix(float3(0.07, 0.22, 0.06), float3(0.32, 0.26, 0.14),
                             smoothstep(sea, sea + 0.25, h));
            gcol = mix(low, float3(0.90, 0.93, 1.0), smoothstep(sea + 0.32, sea + 0.44, h));
        }
        float dif = max(dot(n, sunDir), 0.0);
        col = gcol * (0.08 + 1.35 * dif * dif);
        float spec = pow(max(dot(reflect(-sunDir, n), -rd), 0.0), 90.0);
        col += float3(1.0, 0.95, 0.8) * spec * oce * 0.9;
        // habitat lights / arcology clusters on land
        float2 cid = floor(xz * 0.55);
        float ch = hash21(cid + seed * 9.0);
        if (ch > 0.84 && h > sea) {
            float2 cf = fract(xz * 0.55) - 0.5;
            float d2c = dot(cf, cf);
            col += float3(1.0, 0.75, 0.45) * exp(-d2c * 55.0) * (0.7 + 0.3 * sin(gt * 1.7 + ch * 40.0));
        }
        float fog = 1.0 - exp(-tg * 0.020);
        col = mix(col, float3(0.36, 0.45, 0.65) * 0.40, fog);
    } else {
        // interior "sky": haze, the far side of the shell, and the sun
        float up = clamp(rd.y, 0.0, 1.0);
        col = mix(float3(0.24, 0.31, 0.46) * 0.38, float3(0.06, 0.08, 0.16), up);
        float farShell = fbm(float3(rd.xz * 2.6 / (0.25 + rd.y) + fwd * 0.01, seed * 5.0), 4);
        col += float3(0.20, 0.27, 0.24) * farShell * up * 0.30;   // faint far continents
        float sg = max(dot(rd, sunDir), 0.0);
        col += float3(1.0, 0.92, 0.75) * (pow(sg, 900.0) * 4.0 + pow(sg, 30.0) * 0.35 + pow(sg, 6.0) * 0.10);
    }
    // horizon haze band
    col += float3(0.9, 0.75, 0.55) * exp(-abs(rd.y) * 26.0) * 0.10;
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
    float edge = smoothstep(2.55, 2.95, hr) * smoothstep(7.6, 5.4, hr);
    if (edge < 0.003) { alpha = 0.0; return float3(0.0); }

    // differentially rotating turbulence: each radius co-rotates at its own
    // Keplerian rate, so spiral streaks shear out on their own (no seam)
    float om = spinDir * 1.9 / (hr * sqrt(hr));
    float2 q = rot2(om * gt) * hit.xz;
    float dens = 0.35 + 0.90 * fbm(float3(q * 1.15, seed * 9.0), 3);
    dens *= 0.72 + 0.28 * sin(hr * 7.0 + (dens - 0.5) * 6.0 + seed * 31.0);

    // temperature falls with radius: white-hot ISCO -> orange -> deep red
    float3 tc = mix(float3(1.05, 0.98, 0.92), float3(1.0, 0.60, 0.22),
                    smoothstep(2.7, 4.6, hr));
    tc = mix(tc, float3(0.55, 0.20, 0.07), smoothstep(4.6, 7.4, hr));
    float heat = pow(2.8 / hr, 2.2);

    // relativistic beaming: approaching side blasts brighter and bluer
    float beta = 0.55 / sqrt(hr);
    float3 vdir = spinDir * normalize(float3(hit.z, 0.0, -hit.x));
    float dop = clamp(1.0 / pow(max(1.0 + beta * dot(vdir, rd), 0.25), 3.0), 0.08, 4.5);
    float3 shift = mix(float3(1.12, 0.85, 0.62), float3(0.84, 0.93, 1.22),
                       clamp((dop - 0.6) * 0.9, 0.0, 1.0));
    float gz = sqrt(max(1.0 - 1.0 / hr, 0.0));   // gravitational redshift dims inner rim

    // Sgr A*-style flare: a white-hot blob on a tight Keplerian orbit
    float sr = 3.3;
    float sa = seed * 6.28 - spinDir * 1.9 / (sr * sqrt(sr)) * gt;
    float3 spd = hit - float3(cos(sa) * sr, 0.0, sin(sa) * sr);
    float spot = exp(-dot(spd, spd) * 6.0);

    alpha = clamp(edge * (0.30 + dens) * 0.85, 0.0, 0.95);
    return (tc * dens * 1.9 + float3(1.0, 0.96, 0.88) * spot * 8.0)
           * heat * edge * dop * shift * gz;
}

// Ray-marched Schwarzschild black hole (rs = 1). Null rays bend under
// a = -1.5 h^2 p / r^5 (h = |p x v| conserved) — the standard geodesic
// approximation — so the photon ring, the Einstein-lensed starfield and the
// disk wrapping over/under the shadow all EMERGE from the integration;
// nothing here is painted on.
float3 blackHoleScene(float2 uv, float t, float seed, float4 pal, float gt, float dur) {
    float prog = clamp(t / dur, 0.0, 1.0);
    float spinDir = hash11(seed * 6.1) > 0.5 ? 1.0 : -1.0;

    // approach from a distant dot to a close pass, then orbit slowly
    float dist = mix(55.0, 12.0, smoothstep(0.0, 0.8, prog));
    float az = gt * 0.045 + seed * 6.28;
    float inc = mix(0.12, 0.40, hash11(seed * 2.3)) + 0.05 * sin(gt * 0.05);

    uv = rot2(0.04 * sin(gt * 0.035)) * uv;
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
        col += T * spaceBG(bg + seed * 5.0, seed + 6.0, pal, gt, 0.38);
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
                col += amp * (head * float3(0.9, 0.95, 1.0)
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

float3 encounterScene(float2 uv, float t, float4 scn, float4 pal, float gt) {
    int sub = int(scn.y + 0.5);
    float dur = max(scn.w, 1.0);
    if (sub == 0) return dysonScene(uv, t, scn.x, pal, gt, dur, int(scn.z + 0.5));
    if (sub == 1) return blackHoleScene(uv, t, scn.x, pal, gt, dur);
    if (sub == 3) return dysonSwarmScene(uv, t, scn.x, pal, gt, dur);
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
        float3 c1 = float3(0.86, 0.72, 0.50);   // tan zone
        float3 c2 = float3(0.48, 0.32, 0.20);   // brown belt
        float3 c3 = float3(0.94, 0.88, 0.76);   // bright zone
        col = mix(c1, c2, smoothstep(-0.4, 0.4, band));
        col = mix(col, c3, smoothstep(0.2, 0.9, band2) * 0.5);
        col *= 0.92 + 0.16 * turb;
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
            pcol += atmo * fres * (0.02 + 0.5 * pow(dif, 0.7));
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

// ---------- dispatch ----------

float3 renderScene(int type, float t, float4 scn, float4 pal, float2 uv, float gt,
                   texture2d<float> img) {
    if (type == 0) return cruiseScene(uv, t, scn, pal, gt);
    if (type == 1) return galaxyScene(uv, t, scn, pal, gt, img);
    if (type == 2) return planetScene(uv, t, scn, pal, gt);
    if (type == 4) return encounterScene(uv, t, scn, pal, gt);
    if (type == 5) return deepfieldScene(uv, t, scn, pal, gt, img);
    if (type == 6) return homeScene(uv, t, scn, pal, gt);
    return warpScene(uv, t, scn, pal, gt);
}

float3 acesish(float3 x) {
    return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}

fragment float4 fmain(VOut in [[stage_in]], constant Uniforms &U [[buffer(0)]],
                      texture2d<float> img [[texture(0)]]) {
    float2 frag = in.uv * U.resolution;
    float2 uv = (frag - 0.5 * U.resolution) / max(U.resolution.y, 1.0);

    float3 col = renderScene(U.sceneType, U.sceneTime, U.scnA, U.palA, uv, U.time, img);
    if (U.transition < 1.0) {
        float3 prev = renderScene(U.prevSceneType, U.prevSceneTime, U.scnB, U.palB, uv, U.time, img);
        col = mix(prev, col, smoothstep(0.0, 1.0, U.transition));
    }

    col = acesish(col * 1.15);
    // vignette
    float2 vuv = frag / U.resolution - 0.5;
    col *= 1.0 - 0.32 * pow(dot(vuv, vuv) * 2.6, 1.4);
    // gamma (bgra8Unorm, manual)
    col = pow(max(col, 0.0), float3(1.0 / 2.2));
    // dither/grain to kill banding
    col += (hash21(frag * 0.71 + fract(U.time * 0.93) * 371.0) - 0.5) * 0.011;
    return float4(col, 1.0);
}
"""#
