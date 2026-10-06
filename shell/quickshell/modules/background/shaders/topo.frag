#version 440
// A topographic map: contour lines over a made-up terrain.
//
// The terrain is fractal noise, bent by more noise ("flow") so the ridges
// wander rather than sit on a grid. Its coordinates are the screen's place
// in the whole layout, so side-by-side monitors show one continuous map.
// Lines are measured in device pixels (fwidth), so they stay the same
// width however steep the ground is, and fade out where they would crowd
// into a smear.
//
// Compiled for Qt with qsb (see ../Topography.qml); the .qsb beside this is
// what is loaded.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 origin;       // this screen's top-left in the layout, logical px
    vec2 size;         // this screen, logical px
    vec2 seedOffset;   // where on the endless terrain the map is
    float unit;        // logical px per unit of terrain
    float detail;      // octaves, 1-6
    float warp;        // 0-1
    float levels;      // contour lines per full height
    float lineWidth;   // device px
    float majorEvery;  // every Nth line heavier; 0 for none
    float lineAlpha;   // 0-1
    float shade;       // 0 flat, 1 smooth, 2 bands
    float time;        // drift
    float rise;        // contours flowing: how far they have moved, in levels
    float glowAmt;     // 0-1, light around the lines
    vec4 lineColor;
    vec4 bgLow;
    vec4 bgHigh;
};

vec2 hash2(vec2 p) {
    p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
    return -1.0 + 2.0 * fract(sin(p) * 43758.5453123);
}

// Gradient noise, about -0.7..0.7.
float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(dot(hash2(i), f),
                   dot(hash2(i + vec2(1.0, 0.0)), f - vec2(1.0, 0.0)), u.x),
               mix(dot(hash2(i + vec2(0.0, 1.0)), f - vec2(0.0, 1.0)),
                   dot(hash2(i + vec2(1.0, 1.0)), f - vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
    float amp = 0.5;
    float sum = 0.0;
    float norm = 0.0;
    mat2 turn = mat2(0.8, 0.6, -0.6, 0.8);
    for (int i = 0; i < 6; i++) {
        if (float(i) >= detail) break;
        sum += amp * noise(p);
        norm += amp;
        p = turn * p * 2.03 + vec2(1.7, 9.2);
        amp *= 0.5;
    }
    return sum / norm;
}

void main() {
    vec2 p = (origin + qt_TexCoord0 * size) / unit + seedOffset;

    vec2 q = vec2(fbm(p + vec2(0.0, 0.0) + time * vec2(0.021, 0.013)),
                  fbm(p + vec2(5.2, 1.3) - time * vec2(0.017, 0.024)));
    float h = fbm(p + warp * 2.5 * q);
    h = clamp(0.5 + h * 1.25, 0.0, 1.0);

    // Flowing: every line climbs the slope and the next takes its place,
    // which reads as the ground itself rising and falling.
    float v = h * levels + rise;
    float fw = max(fwidth(v), 1e-5);
    // Distance to the nearest line, in device pixels.
    float d = abs(fract(v + 0.5) - 0.5) / fw;
    float index = floor(v + 0.5);
    bool major = majorEvery > 0.5 && mod(index, majorEvery) < 0.5;
    float w = lineWidth * (major ? 1.9 : 1.0);
    float a = 1.0 - smoothstep(w * 0.5 - 0.6, w * 0.5 + 0.6, d);
    a *= lineAlpha * (major || majorEvery < 0.5 ? 1.0 : 0.65);
    // Lines closer together than a few pixels are a smear, not a map.
    a *= 1.0 - smoothstep(0.25, 0.5, fw);
    // Glow: a soft light either side of each line.
    float g = glowAmt * exp(-d / max(w * 2.5, 1.0)) * lineAlpha * (1.0 - smoothstep(0.25, 0.5, fw));

    float t = shade < 0.5 ? qt_TexCoord0.y
            : shade < 1.5 ? h
            // Back and forth rather than round: a flowing map's bands
            // would otherwise jump from the top colour to the bottom.
            : 1.0 - abs(fract(floor(v) / max(levels - 1.0, 1.0) * 0.5) * 2.0 - 1.0);
    vec3 bg = mix(bgLow.rgb, bgHigh.rgb, clamp(t, 0.0, 1.0));

    // Bands follow the flow, so they move with their lines.
    vec3 outc = mix(bg, lineColor.rgb, a) + lineColor.rgb * g * 0.6;
    fragColor = vec4(outc, 1.0) * qt_Opacity;
}
