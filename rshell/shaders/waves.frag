#version 440
// Waves: many fine lines rolling across the screen, each a little behind
// the one above. Coloured from c1 at the top through c2 to c3. Density is
// how many lines, glow a soft light around them, intensity their weight.
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
    float x = px.x / unit + seedOffset.x;
    vec3 col = mix(bg1.rgb, bg2.rgb, uv.y);
    float ys = size.y / unit;

    int n = int(8.0 + density * 52.0);
    float halo = 0.0;
    vec3 haloCol = vec3(0.0);
    for (int i = 0; i < 60; i++) {
        if (i >= n) break;
        float t = float(i) / max(float(n - 1), 1.0);
        float y0 = 0.06 + t * 0.88;
        float amp = 0.5 + 0.5 * sin(t * 3.14159);
        float y = y0 + amp * (0.055 * sin(x * 1.5 + time * 0.45 + t * 2.6)
                            + 0.030 * sin(x * 3.3 - time * 0.33 + t * 5.0 + seedOffset.y)
                            + 0.030 * (noise(vec2(x * 0.9 + time * 0.08, t * 3.0)) - 0.5)) / max(ys, 0.5) * 1.6;
        float d = abs(uv.y - y) * size.y * dpr;
        float w = 0.5 + intensity * 1.6;
        float a = 1.0 - smoothstep(w - 0.6, w + 0.6, d);
        vec3 lc = t < 0.5 ? mix(c1.rgb, c2.rgb, t * 2.0) : mix(c2.rgb, c3.rgb, t * 2.0 - 1.0);
        col = mix(col, lc, a * (0.55 + 0.45 * intensity));
        float g = exp(-d / (4.0 + glow * 14.0));
        halo += g;
        haloCol += lc * g;
    }
    col += haloCol * glow * 0.10;
    fragColor = vec4(dither(col, px), 1.0) * qt_Opacity;
}
