#version 440
// Synthwave: a striped sun setting over a neon grid rolling towards you.
// bg1 is the sky's top, bg2 the horizon; the sun runs from c2 to c3; the
// grid is c1. Density is how fine the grid is, glow the haze around it.
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

void main() {
    vec2 uv = qt_TexCoord0;
    vec2 px = origin + uv * size;
    float aspect = size.x / max(size.y, 1.0);
    float hz = 0.62;
    vec3 col;

    if (uv.y < hz) {
        col = mix(bg1.rgb, bg2.rgb, pow(uv.y / hz, 1.6));
        // The sun.
        vec2 sp = vec2((uv.x - 0.5) * aspect, uv.y - (hz - 0.17));
        float r = 0.24;
        float d = length(sp);
        float k = clamp((sp.y + r) / (2.0 * r), 0.0, 1.0);
        vec3 sun = mix(c2.rgb, c3.rgb, k);
        // Bands cut across its lower half, drifting down.
        float band = fract((sp.y + r) * 16.0 - time * 0.35);
        float cut = step(0.45, k) * step(band, (k - 0.45) * 1.2);
        float inside = (1.0 - smoothstep(r - 0.002, r + 0.002, d)) * (1.0 - cut);
        col = mix(col, sun, inside);
        col = mix(col, c2.rgb, exp(-max(d - r, 0.0) * 9.0) * glow * 0.45 * (1.0 - inside));
        // Stars, a few.
        vec2 sc = floor(px / 3.0);
        col = mix(col, vec3(1.0), step(0.998, hash1(sc + seedOffset)) * (1.0 - uv.y / hz) * 0.6 * (1.0 - inside));
    } else {
        float y = uv.y - hz;
        float z = 0.12 / max(y, 1e-4);
        float xw = (uv.x - 0.5) * aspect * z;
        float zw = z + time * 0.6;
        float cells = 1.5 + density * 5.0;
        vec2 g = vec2(xw, zw) * cells;
        vec2 fw = max(fwidth(g), vec2(1e-4));
        vec2 l = abs(fract(g - 0.5) - 0.5) / fw;
        float line = 1.0 - min(min(l.x, l.y) / (1.0 + intensity * 1.5), 1.0);
        float fade = smoothstep(0.0, 0.25, y);
        vec3 ground = mix(bg1.rgb * 0.6, bg2.rgb * 0.35, smoothstep(0.0, 0.4, y));
        col = mix(ground, c1.rgb, clamp(line * fade, 0.0, 1.0));
        col = mix(col, c1.rgb, exp(-y * 18.0) * glow * 0.5);
    }
    // The horizon itself.
    col = mix(col, c3.rgb, exp(-abs(uv.y - hz) * size.y * dpr / 3.0) * 0.6);
    fragColor = vec4(dither(col, px), 1.0) * qt_Opacity;
}
