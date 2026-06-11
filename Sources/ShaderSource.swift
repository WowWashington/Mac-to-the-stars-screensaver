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
    float ge = floor(t / 23.0 + 0.5);
    float2 gh = hash22(float2(ge * 7.1, seed * 31.0));
    if (gh.x > 0.45) {
        float gfr = fract(t / 23.0 + 0.5);
        float genv = sin(3.14159 * gfr);
        float2 gp = (gh - 0.5) * 1.1 * (1.0 + gfr * 0.5);
        float2 gq = rot2(gh.y * 6.28) * (uv - gp);
        gq.y *= 2.2;                            // inclined
        col += galaxyColor(gq * 9.0, seed * 3.0 + ge, pal, gt) * 0.16 * genv;
    }
    return col;
}

// ---------- scene 1: galaxy approach & entry ----------

float3 galaxyScene(float2 uv, float t, float4 scn, float4 pal, float gt) {
    float seed = scn.x;
    float dur = max(scn.w, 1.0);
    float prog = clamp(t / dur, 0.0, 1.0);
    float ease = smoothstep(0.0, 1.0, prog);

    uv = rot2(gt * 0.006 + 0.04 * sin(gt * 0.027)) * uv;
    float3 col = spaceBG(uv * 0.8 + 3.0, seed + 0.5, pal, gt, 0.32);

    // approach: galaxy grows; we aim toward an arm, not the core
    float zoom = mix(0.10, 4.2, pow(ease, 2.2));   // grows from a distant dot
    float2 center = mix(float2(0.0), float2(0.95, 0.30), ease);
    float2 q = rot2(seed * 6.28 + gt * 0.005) * uv;
    float incl = mix(0.42, 0.95, hash11(seed * 5.1));
    q.y /= incl;
    q = q / zoom * 2.0 + center;
    col += galaxyColor(q, seed, pal, gt);

    // entering the disk: dust fog + local stars thicken
    float enter = smoothstep(0.62, 1.0, prog);
    if (enter > 0.001) {
        float fog = fbm(float3(uv * 2.4, seed * 4.4 + gt * 0.01), 4);
        float wisp = fbm(float3(uv * 6.5 + 7.0, seed * 8.8 + gt * 0.015), 4);
        float lane = ridged(float3(uv * 3.4, seed * 6.2), 3);
        float3 fogCol = tint(pal.y, 0.6) * pow(fog, 2.0) * pow(wisp, 1.6) * 0.9;
        fogCol *= 1.0 - 0.75 * smoothstep(0.45, 0.8, lane);
        col += fogCol * enter;
        for (int i = 0; i < 4; i++) {
            float fi = float(i);
            float ph = fract(fi / 4.0 - t * 0.05 + hash11(seed * 2.0 + fi));
            float depth = 0.06 + 0.94 * ph;
            float2 sq = uv * depth * 5.0 + (hash22(float2(fi, seed * 7.0)) - 0.5) * 8.0;
            float fade = smoothstep(1.0, 0.8, ph) * smoothstep(0.0, 0.12, ph);
            col += starLayer(sq, 0.12, seed * 9.0 + fi * 5.0, gt) * fade * enter * 0.8;
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
    float z = L * (0.16 + 0.165 * fi + (h1 - 0.5) * 0.05);
    R = mix(0.55, 1.5, h2);
    float lat;
    float phi;
    if (i == 2) {
        lat = R * 1.4 + mix(0.8, 1.3, h1);
        phi = sunPhi + (h3 - 0.5) * 1.3;      // sunward side of the path
        ptype = int(heroType + 0.5);
        rings = heroRings > 0.5;
    } else {
        lat = mix(3.6, 9.5, h1);
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
                         L * mix(0.35, 0.65, hash11(seed * 4.2)));
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
    C.z = mix(22.0, 1.2, sp);                      // journeys end AT the shell
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
    float3 S = float3(side * (0.3 + 1.6 * sp * sp), 0.1 * sin(prog * 3.0 + seed), mix(19.0, -3.0, sp));
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
    float zoom = mix(0.55, 1.45, sp);              // whole swarm grows on approach
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
        float3 pc = float3(0.04, 0.045, 0.06) + sunCol * pow(max(0.0, sin(fr * 6.0 + he.y * 9.0)), 8.0) * 1.4;
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

float3 blackHoleScene(float2 uv, float t, float seed, float4 pal, float gt, float dur) {
    float prog = clamp(t / dur, 0.0, 1.0);
    float sp = smoothstep(0.0, 1.0, prog);
    float side = hash11(seed * 6.1) > 0.5 ? 1.0 : -1.0;

    float scale = mix(0.05, 1.15, smoothstep(0.0, 0.9, prog));
    float2 p0 = mix(float2(0.40 * side, 0.16), float2(-0.12 * side, -0.04), sp);
    float2 q = (uv - p0) / scale;
    float r = length(q);

    // gravitational lensing of the background
    float2 dir = r > 1e-3 ? q / r : float2(0.0);
    float defl = 0.030 / (r * r + 0.012);
    float2 lensUV = uv - dir * defl * scale;
    float3 col = spaceBG(lensUV + seed * 3.0, seed + 6.0, pal, gt, 0.4);

    // accretion disk: inclined, turbulent, doppler-shifted
    float2 dq = q;
    dq.y *= mix(2.6, 4.0, hash11(seed * 3.7));
    float dr = length(dq);
    float da = atan2(dq.y, dq.x);
    float ann = smoothstep(0.50, 0.40, dr) * smoothstep(0.125, 0.155, dr);
    float swirl = fbm(float3(dr * 11.0 - gt * 0.55, da * 2.5 + dr * 9.0 - gt * 0.8, seed * 11.0), 4);
    float doppler = 0.50 + 0.50 * sin(da + 1.7);
    float heat = smoothstep(0.50, 0.16, dr);          // white-hot inner edge -> red outer
    float3 hot = mix(float3(0.9, 0.30, 0.08), float3(1.0, 0.97, 0.88), heat * (0.4 + 0.6 * swirl));
    col += hot * ann * (0.25 + 2.1 * pow(swirl, 1.7)) * (0.30 + 0.90 * doppler) * 2.2;

    // event horizon shadow, then photon ring on top
    col *= smoothstep(0.105, 0.135, r);
    float ring = exp(-pow(abs(r - 0.165) * 70.0, 1.6));
    col += float3(1.0, 0.85, 0.6) * ring * 1.6;

    // faint relativistic jet, fading with distance
    float jet = exp(-q.x * q.x * 900.0) * smoothstep(0.75, 0.22, abs(q.y)) * smoothstep(0.14, 0.30, abs(q.y));
    col += float3(0.55, 0.7, 1.0) * jet * 0.10;
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
    float2 hp = mix(float2(-0.85 * hside, -0.30), float2(0.85 * hside, 0.22), smoothstep(0.05, 0.95, prog));
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
    col += head * float3(0.92, 0.96, 1.0)
         + dust * float3(1.0, 0.9, 0.72) * 0.6 * wisp
         + ion * float3(0.5, 0.72, 1.0) * 0.6;
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
    float zdir = hash11(seed * 9.1) > 0.5 ? 1.0 : -1.0;
    float K = Kmax * (0.86 + 0.10 * prog * zdir);
    float2 uvT = c + float2(uv.x / aspect, -uv.y) * K;

    float3 col = img.sample(smp, uvT).rgb;
    col = pow(max(col, 0.0), float3(2.2));        // back to linear for our pipeline
    col *= 0.95 + 0.05 * sin(gt * 0.21 + seed);   // slow exposure breathing
    // faint parallax starfield drifting in front of the photograph
    float2 sUV = uv * 7.0 + (c - 0.5) * 3.0 + seed * 19.0;
    col += starLayer(sUV, 0.05, seed + 4.0, gt) * 0.20;
    return col;
}

// ---------- dispatch ----------

float3 renderScene(int type, float t, float4 scn, float4 pal, float2 uv, float gt,
                   texture2d<float> img) {
    if (type == 0) return cruiseScene(uv, t, scn, pal, gt);
    if (type == 1) return galaxyScene(uv, t, scn, pal, gt);
    if (type == 2) return planetScene(uv, t, scn, pal, gt);
    if (type == 4) return encounterScene(uv, t, scn, pal, gt);
    if (type == 5) return deepfieldScene(uv, t, scn, pal, gt, img);
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
