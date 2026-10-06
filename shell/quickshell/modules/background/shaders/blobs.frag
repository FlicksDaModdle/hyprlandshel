#version 440
// Blobs: soft pools of colour drifting over each other — a moving mesh
// gradient. c1, c2, c3 and bg2 are the pools, bg1 what shows between them.
// Density is how many pools, glow how soft their edges are.
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

// Hashes without sine (Dave Hoskins): sin() of a large number is evaluated
// differently by every GPU, and on some it repeats in visible patterns —
// stars in diagonal pairs.
float hash1(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}
vec2 hash2(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
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
    vec2 q = vec2(uv.x * aspect, uv.y);
    // The size setting, relative to the screen.
    float s = unit / 650.0;

    float bw = 0.18 + (1.0 - intensity) * 0.6;
    vec3 acc = bg1.rgb * bw;
    float wsum = bw;
    int n = 3 + int(density * 5.0);
    for (int i = 0; i < 8; i++) {
        if (i >= n) break;
        float fi = float(i);
        vec2 h = hash2(vec2(fi, 3.7) + seedOffset);
        vec2 c = vec2(aspect * (0.5 + 0.48 * sin(time * (0.07 + 0.05 * h.x) + fi * 2.4 + h.y * 6.28)),
                      0.5 + 0.48 * cos(time * (0.06 + 0.05 * h.y) + fi * 1.7 + h.x * 6.28));
        float r = (0.22 + 0.30 * glow) * s;
        float wgt = exp(-dot(q - c, q - c) / (r * r));
        int k = i - (i / 4) * 4;
        vec3 cc = k == 0 ? c1.rgb : (k == 1 ? c2.rgb : (k == 2 ? c3.rgb : bg2.rgb));
        acc += cc * wgt;
        wsum += wgt;
    }
    vec3 col = acc / wsum;
    // Film grain, very light: it is what keeps a wide gradient smooth.
    col += (hash1(px * 0.73 + floor(time * 12.0)) - 0.5) * 0.018;
    fragColor = vec4(col, 1.0) * qt_Opacity;
}
