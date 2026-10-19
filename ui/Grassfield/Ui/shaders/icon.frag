#version 440
// Icon appearance modes (ADR-0014): dark, clear and tinted renderings of an arbitrary theme icon.
// Build: scripts/dev/build-shaders.sh (qsb) -> icon.frag.qsb. Algorithm and limits: docs/specs/ui.md "Icon shader".
//
// Third-party icons have no separate plate and glyph layers, so they are separated per pixel:
//  1. PLATE ESTIMATE. 12 probes on a ring inside the icon (where a rounded-square or round plate is, but a glyph
//     usually is not) give the plate colour (opacity-weighted mean, then a second mean over the probes close to the
//     first, which drops probes that landed on a glyph) and the plate strength (mean opacity of the probes: a logo
//     on transparency has none).
//  2. PLATE MEMBERSHIP. A pixel is plate when its colour is near the plate colour (soft threshold, so a plate
//     gradient stays plate); anything else is glyph.
//  3. The mode maps plate pixels and glyph pixels differently (see each function), then an edge highlight (rim) is
//     added on the plate boundary so a dark plate stays visible on a dark material.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 tint;              // tint colour (Tinted)
    float modeIndex;        // 1 dark, 2 clear, 3 tinted
    float dark;             // 1 in the dark appearance
    float rimUv;            // rim width in texture coordinates
    float plateToleranceLow;
    float plateToleranceHigh;
    float plateAlphaLow;
    float plateAlphaHigh;
    float darkPlateLuma;
    float darkGlyphLuma;
    float darkGlyphBoost;
    float darkRim;
    float clearPlateAlphaDark;
    float clearPlateAlphaLight;
    float clearInkDark;
    float clearInkLight;
    float clearDetail;
    float clearRim;
    float tintedPlateScale;
    float tintedPlateMixLight;
    float tintedGlyphLift;
    float tintedGlyphShadeLight;
    float tintedDetail;
    float tintedRim;
};

layout(binding = 1) uniform sampler2D iconTexture;

float luma(vec3 c) {
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

float chroma(vec3 c) {
    return max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
}

// Straight (non-premultiplied) colour of a premultiplied texel; w = opacity.
vec4 straight(vec4 t) {
    return vec4(t.rgb / max(t.a, 0.0001), t.a);
}

void main() {
    vec4 px = straight(texture(iconTexture, qt_TexCoord0));
    vec3 c = px.rgb;
    float a = px.a;

    // 1. Plate estimate.
    const int N = 12;
    vec2 probe[N] = vec2[N](
        vec2(0.91, 0.5), vec2(0.09, 0.5), vec2(0.5, 0.91), vec2(0.5, 0.09),
        vec2(0.81, 0.81), vec2(0.19, 0.19), vec2(0.81, 0.19), vec2(0.19, 0.81),
        vec2(0.88, 0.66), vec2(0.12, 0.34), vec2(0.66, 0.12), vec2(0.34, 0.88));
    vec4 taps[N];
    vec4 sum = vec4(0.0);
    for (int i = 0; i < N; ++i) {
        taps[i] = straight(texture(iconTexture, probe[i]));
        sum += vec4(taps[i].rgb * taps[i].a, taps[i].a);
    }
    vec3 mean1 = sum.rgb / max(sum.a, 0.0001);
    vec4 sum2 = vec4(0.0);
    for (int i = 0; i < N; ++i) {
        float near = 1.0 - smoothstep(plateToleranceLow, plateToleranceHigh, distance(taps[i].rgb, mean1));
        sum2 += vec4(taps[i].rgb * taps[i].a * near, taps[i].a * near);
    }
    vec3 plate = sum2.a > 0.0001 ? sum2.rgb / sum2.a : mean1;
    float strength = smoothstep(plateAlphaLow, plateAlphaHigh, sum.a / float(N));

    // 2. Plate membership (0 glyph .. 1 plate).
    float member = (1.0 - smoothstep(plateToleranceLow, plateToleranceHigh, distance(c, plate))) * strength;
    float Lc = luma(c);
    float Lp = max(luma(plate), 0.04);
    bool isDark = dark > 0.5;

    // Edge band: inside the shape, within rimUv of a transparent texel.
    float lowest = min(min(texture(iconTexture, qt_TexCoord0 + vec2(rimUv, 0.0)).a, texture(iconTexture, qt_TexCoord0 - vec2(rimUv, 0.0)).a),
                       min(texture(iconTexture, qt_TexCoord0 + vec2(0.0, rimUv)).a, texture(iconTexture, qt_TexCoord0 - vec2(0.0, rimUv)).a));
    float edge = clamp(a - lowest, 0.0, 1.0) * strength;

    vec4 outc;   // premultiplied
    if (modeIndex < 1.5) {
        // DARK: the plate is darkened to near black keeping its hue and gradient; neutral glyphs on a light plate
        // invert (dark glyph -> light), coloured glyphs keep their colour, brightened if dark.
        float k = min(darkPlateLuma / Lp, 1.0);
        vec3 plateRgb = c * k;
        float lightPlate = smoothstep(0.45, 0.65, Lp) * strength;
        float neutral = 1.0 - smoothstep(0.08, 0.25, chroma(c));
        float r = clamp(Lc / Lp, 0.0, 1.0);
        vec3 ink = vec3(mix(darkGlyphLuma, darkPlateLuma, r));
        float boost = lightPlate * darkGlyphBoost * (1.0 - smoothstep(0.25, 0.6, Lc));
        vec3 keep = min(c * (1.0 + boost * (1.0 - Lc) * 2.0), vec3(1.0));
        vec3 glyphRgb = mix(keep, ink, neutral * lightPlate);
        vec3 rgb = mix(glyphRgb, plateRgb, member);
        rgb = mix(rgb, vec3(1.0), edge * darkRim * (isDark ? 1.0 : 0.0));
        outc = vec4(rgb * a, a);
    } else if (modeIndex < 2.5) {
        // CLEAR: the plate becomes translucent glass (light in the dark appearance, smoked in the light one) and the
        // glyph a monochrome ink whose shading follows the glyph's contrast with the plate.
        float inkL = isDark ? clearInkDark : clearInkLight;
        float ref = mix(0.5, Lp, strength);
        float detail = mix(Lc, clamp(abs(Lc - ref) * 2.2, 0.0, 1.0), strength);
        vec3 ink = isDark ? vec3(inkL * (1.0 - clearDetail * 0.55 * (1.0 - detail)))
                          : vec3(inkL + clearDetail * 0.5 * (1.0 - detail));
        vec3 glass = isDark ? vec3(1.0) : vec3(0.0);
        float glassA = (isDark ? clearPlateAlphaDark : clearPlateAlphaLight) * a;
        vec4 plateP = vec4(glass * glassA, glassA);
        vec4 glyphP = vec4(ink * a, a);
        outc = mix(glyphP, plateP, member);
        float rimA = edge * clearRim * a;
        outc = vec4(vec3(inkL) * rimA, rimA) + outc * (1.0 - rimA);
    } else {
        // TINTED: a dark tinted plate with a tint-coloured glyph (dark appearance), a light tinted plate with a dark
        // tint-coloured glyph (light appearance). The glyph's own shading modulates the tint.
        vec3 t = tint.rgb;
        float ref = mix(0.5, Lp, strength);
        float detail = mix(Lc, clamp(abs(Lc - ref) * 2.2, 0.0, 1.0), strength);
        float shade = mix(1.0, 0.55 + 0.45 * detail, tintedDetail);
        vec3 base = isDark ? mix(t, vec3(1.0), tintedGlyphLift) : t * tintedGlyphShadeLight;
        vec3 ink = base * shade;
        float rr = clamp(Lc / Lp, 0.8, 1.2);
        vec3 plateRgb = (isDark ? t * tintedPlateScale : mix(t, vec3(1.0), tintedPlateMixLight)) * rr;
        vec3 rgb = mix(ink, min(plateRgb, vec3(1.0)), member);
        rgb = mix(rgb, base, edge * tintedRim);
        outc = vec4(rgb * a, a);
    }
    fragColor = outc * qt_Opacity;
}
