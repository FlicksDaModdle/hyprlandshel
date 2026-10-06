#version 440
// Cells: a shifting mosaic — points wander, and the cells around them
// follow. Cells are shades between bg1 and bg2 with a slow pulse of c2;
// their edges are c1 (intensity), with a glow of c3 around them.
// Density is how many cells.
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
    vec2 p = px / unit * (1.5 + density * 6.0) + seedOffset;
    vec2 ip = floor(p), fp = fract(p);
    float f1 = 8.0, f2 = 8.0;
    vec2 best = vec2(0.0);
    for (int j = -1; j <= 1; j++)
    for (int i = -1; i <= 1; i++) {
        vec2 o = vec2(float(i), float(j));
        vec2 h = hash2(ip + o);
        vec2 pt = o + 0.5 + 0.42 * sin(time * 0.35 + 6.2831 * h);
        float d = length(pt - fp);
        if (d < f1) { f2 = f1; f1 = d; best = ip + o; }
        else if (d < f2) { f2 = d; }
    }
    float edge = f2 - f1;
    float h = hash1(best);
    vec3 fill = mix(bg1.rgb, bg2.rgb, h);
    fill = mix(fill, c2.rgb, 0.18 * (0.5 + 0.5 * sin(time * 0.6 + h * 30.0)));
    float fwv = fwidth(edge);
    float line = 1.0 - smoothstep(0.0, fwv * (1.2 + intensity * 2.5), edge);
    vec3 col = mix(fill, c1.rgb, line * (0.35 + intensity * 0.65));
    col += c3.rgb * exp(-edge * (30.0 - glow * 22.0)) * glow * 0.45;
    fragColor = vec4(dither(col, px), 1.0) * qt_Opacity;
}
