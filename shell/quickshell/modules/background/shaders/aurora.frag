#version 440
// Aurora: curtains of light over a night sky. Each curtain hangs from a
// wavering line, bright at its foot and fading upwards, streaked with rays.
// c1, c2, c3 colour the curtains; bg1 is the top of the sky, bg2 the
// bottom. Density is how many curtains, glow how tall they reach.
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

// Small round stars that twinkle, a few to every 22 px cell; px logical.
float sparkle(vec2 px, float chance, float t) {
    const float cell = 22.0;
    vec2 g = px / cell;
    vec2 id = floor(g);
    vec2 h = hash2(id + seedOffset);
    if (h.x > chance) return 0.0;
    vec2 pos = id + 0.15 + 0.7 * hash2(id + seedOffset + 17.0);
    float d = length(g - pos) * cell;
    float r = 0.6 + 0.9 * h.y;
    float tw = 0.6 + 0.4 * sin(t * (0.8 + 1.6 * h.y) + h.y * 50.0);
    return tw * (0.45 + 0.55 * h.y) * ((1.0 - smoothstep(0.0, r, d)) + 0.25 * exp(-d / (r * 1.8)));
}

void main() {
    vec2 uv = qt_TexCoord0;
    vec2 px = origin + uv * size;
    float x = px.x / unit + seedOffset.x;
    vec3 col = mix(bg1.rgb, bg2.rgb, uv.y);

    // Stars, faint, in the upper sky.
    col = mix(col, vec3(1.0), clamp(sparkle(px, 0.16, time * 1.7), 0.0, 1.0) * (1.0 - uv.y) * 0.6);

    int n = int(2.0 + density * 4.0);
    for (int i = 0; i < 6; i++) {
        if (i >= n) break;
        float fi = float(i);
        float base = 0.30 + 0.36 * (fi + 0.5) / float(n);
        float w = sin(x * 1.1 + time * 0.31 + fi * 1.7) * 0.07
                + sin(x * 2.7 - time * 0.23 + fi * 0.9) * 0.035
                + (fbm(vec2(x * 0.7 + fi * 3.1, time * 0.06)) - 0.5) * 0.18;
        float d = uv.y - (base + w);
        // Above the line, a long fade; below it, a sharp edge.
        float reach = 5.0 + (1.0 - glow) * 11.0;
        float a = d < 0.0 ? exp(d * reach) : exp(-d * d * 3500.0);
        float rays = 0.45 + 0.55 * fbm(vec2(x * 9.0 + fi * 7.0, time * 0.25 + fi));
        vec3 cA = i == 0 ? c1.rgb : (i == 1 ? c2.rgb : (i == 2 ? c3.rgb : (i == 3 ? c1.rgb : (i == 4 ? c2.rgb : c3.rgb))));
        vec3 cB = i == 0 ? c2.rgb : (i == 1 ? c3.rgb : c1.rgb);
        vec3 cc = mix(cA, cB, clamp(-d * 3.0, 0.0, 1.0));
        // Painted over what is behind, so it reads on a light sky as well
        // as a dark one.
        float k = 1.0 - exp(-a * rays * (0.35 + intensity * 1.1) * 1.6);
        col = mix(col, cc, k);
    }
    fragColor = vec4(dither(col, px), 1.0) * qt_Opacity;
}
