#version 440
// Starfield: three layers of stars drifting at different depths, twinkling,
// over a nebula in c1 and c2 (glow is how much nebula). Stars are white
// tinged with c3; density is how many.
//
// Compiled with qsb (see ../AnimatedWallpaper.qml); the .qsb beside this
// is what is loaded. The uniform block is the same in every animated style.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 origin;       // this screen's top-left in the layout, logical px
    vec2 size;         // this screen, logical px
    vec2 seedOffset;   // which variation
    float time;        // seconds, scaled by the speed setting
    float unit;        // logical px per unit, from the size setting
    float density;     // 0-1
    float glow;        // 0-1
    float intensity;   // 0-1
    float dpr;         // device pixels per logical pixel
    vec4 bg1;          // background, top / low
    vec4 bg2;          // background, bottom / high
    vec4 c1;
    vec4 c2;
    vec4 c3;
};

float hash1(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123); }
vec2 hash2(vec2 p) {
    p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
    return fract(sin(p) * 43758.5453123);
}
float noise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    float a = hash1(i), b = hash1(i + vec2(1.0, 0.0));
    float c = hash1(i + vec2(0.0, 1.0)), d = hash1(i + vec2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
float fbm(vec2 p) {
    float s = 0.0, a = 0.5;
    mat2 r = mat2(0.8, 0.6, -0.6, 0.8);
    for (int i = 0; i < 5; i++) { s += a * noise(p); p = r * p * 2.02 + 3.1; a *= 0.5; }
    return s;
}
// A whisper of noise, so slow gradients do not band.
vec3 dither(vec3 c, vec2 px) { return c + (hash1(px + fract(time)) - 0.5) / 255.0; }

float starLayer(vec2 px, float cell, float chance, float t, float seed) {
    vec2 g = px / cell;
    vec2 id = floor(g);
    vec2 h = hash2(id + seed);
    if (h.x > chance) return 0.0;
    vec2 pos = id + 0.2 + 0.6 * hash2(id + seed + 7.0);
    float d = length(g - pos) * cell;
    float tw = 0.65 + 0.35 * sin(t * (1.0 + 2.0 * h.y) + h.y * 40.0);
    float r = 0.6 + 1.4 * h.y;
    return tw * (1.0 - smoothstep(r * 0.4, r, d)) + tw * 0.25 * exp(-d / (r * 2.5));
}
void main() {
    vec2 uv = qt_TexCoord0;
    vec2 px = origin + uv * size;
    vec3 col = mix(bg1.rgb, bg2.rgb, uv.y);

    vec2 np = px / unit * 1.3 + seedOffset;
    float neb = fbm(np + vec2(time * 0.015, -time * 0.01));
    float neb2 = fbm(np * 1.7 - 4.0 + vec2(-time * 0.01, time * 0.012));
    vec3 nc = mix(c1.rgb, c2.rgb, smoothstep(0.3, 0.7, neb2));
    col = mix(col, nc, smoothstep(0.42, 0.85, neb) * glow * 0.75);

    float chance = 0.05 + density * 0.30;
    float s = 0.0;
    s += starLayer(px + vec2(time * 2.0, 0.0), 28.0 * dpr, chance, time, seedOffset.x);
    s += starLayer(px + vec2(time * 5.0, time * 0.6), 46.0 * dpr, chance * 0.7, time * 1.3, seedOffset.y) * 1.1;
    s += starLayer(px + vec2(time * 11.0, time * 1.4), 80.0 * dpr, chance * 0.5, time * 0.8, seedOffset.x + 3.0) * 1.3;
    vec3 sc = mix(vec3(1.0), c3.rgb, 0.35);
    col = mix(col, sc, clamp(s * (0.4 + intensity * 0.8), 0.0, 1.0));
    fragColor = vec4(dither(col, px), 1.0) * qt_Opacity;
}
