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
    float rimGain;          // 0..1: the rim fades out on small icons
    float plateToleranceLow;
    float plateToleranceHigh;
    float plateAlphaLow;
    float plateAlphaHigh;
    float darkPlateLuma;
    float darkChromaKeep;
    float darkGlyphLuma;
    float darkGlyphBoost;
    float darkGlyphFloor;
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

    // 1. Plate estimate. 16 probes on a ring at about 0.36 from the centre: inside a plate and inside the thin light
    //    border some icons have at their edge (it starts near 0.40), but away from most glyphs. The plate is the
    //    DOMINANT colour cluster of the probes (the probe with the most close neighbours, weighted by opacity); probes
    //    on a glyph fall outside it. The strength is the share of probes in the cluster: a multi-coloured logo or a
    //    transparent background has no dominant cluster, hence no plate.
    const int N = 16;
    vec2 probe[N] = vec2[N](
        vec2(0.86, 0.5), vec2(0.14, 0.5), vec2(0.5, 0.86), vec2(0.5, 0.14),
        vec2(0.76, 0.76), vec2(0.24, 0.24), vec2(0.76, 0.24), vec2(0.24, 0.76),
        vec2(0.83, 0.64), vec2(0.83, 0.36), vec2(0.17, 0.64), vec2(0.17, 0.36),
        vec2(0.64, 0.83), vec2(0.36, 0.83), vec2(0.64, 0.17), vec2(0.36, 0.17));
    vec4 taps[N];
    for (int i = 0; i < N; ++i)
        taps[i] = straight(texture(iconTexture, probe[i]));
    float best = -1.0;
    int bi = 0;
    for (int i = 0; i < N; ++i) {
        float w = 0.0;
        for (int j = 0; j < N; ++j)
            w += taps[j].a * (1.0 - smoothstep(plateToleranceLow, plateToleranceHigh, distance(taps[i].rgb, taps[j].rgb)));
        w *= taps[i].a;
        if (w > best) {
            best = w;
            bi = i;
        }
    }
    vec4 sum2 = vec4(0.0);
    for (int j = 0; j < N; ++j) {
        float near = 1.0 - smoothstep(plateToleranceLow, plateToleranceHigh, distance(taps[bi].rgb, taps[j].rgb));
        sum2 += vec4(taps[j].rgb * taps[j].a * near, taps[j].a * near);
    }
    vec3 plate = sum2.a > 0.0001 ? sum2.rgb / sum2.a : taps[bi].rgb;
    float strength = smoothstep(plateAlphaLow, plateAlphaHigh, sum2.a / float(N));

    // Context for icons without a plate: the local average colour (a blurred read) and the average of the whole icon.
    vec4 localT = textureLod(iconTexture, qt_TexCoord0, 2.5);
    vec3 local = localT.rgb / max(localT.a, 0.0001);
    vec4 wholeT = textureLod(iconTexture, vec2(0.5), 12.0);
    float Lmean = max(luma(wholeT.rgb / max(wholeT.a, 0.0001)), 0.05);

    // 2. Plate membership (0 glyph .. 1 plate).
    float member = (1.0 - smoothstep(plateToleranceLow, plateToleranceHigh, distance(c, plate))) * strength;
    float Lc = luma(c);
    float Lp = max(luma(plate), 0.04);
    bool isDark = dark > 0.5;

    // Edge band: inside the shape, within rimUv of a transparent texel.
    float lowest = min(min(texture(iconTexture, qt_TexCoord0 + vec2(rimUv, 0.0)).a, texture(iconTexture, qt_TexCoord0 - vec2(rimUv, 0.0)).a),
                       min(texture(iconTexture, qt_TexCoord0 + vec2(0.0, rimUv)).a, texture(iconTexture, qt_TexCoord0 - vec2(0.0, rimUv)).a));
    float edge = clamp(a - lowest, 0.0, 1.0) * strength * rimGain;

    vec4 outc;   // premultiplied
    if (modeIndex < 1.5) {
        // DARK: the plate is darkened to near black keeping its hue and gradient; neutral glyphs on a light plate
        // invert (dark glyph -> light), coloured glyphs keep their colour, brightened if dark.
        // A saturated plate keeps part of its brightness (a full-bleed logo is indistinguishable from a coloured plate and
        // must not turn navy on a dark material); a neutral plate goes to darkPlateLuma.
        float plateTarget = mix(darkPlateLuma, Lp * darkChromaKeep, smoothstep(0.25, 0.6, chroma(plate)));
        float k = min(plateTarget / Lp, 1.0);
        vec3 plateRgb = c * k;
        float lightPlate = smoothstep(0.45, 0.65, Lp) * strength;
        float neutral = 1.0 - smoothstep(0.08, 0.25, chroma(c));
        float r = clamp(Lc / Lp, 0.0, 1.0);
        vec3 ink = vec3(mix(darkPlateLuma, darkGlyphLuma, clamp((1.0 - r) * 3.0, 0.0, 1.0)));
        // Coloured glyphs on a light plate stay vivid: dark ones are scaled up to a luma floor.
        vec3 keep = min(c * mix(1.0, clamp(darkGlyphFloor / max(Lc, 0.02), 1.0, 4.0), lightPlate * darkGlyphBoost), vec3(1.0));
        vec3 glyphRgb = mix(keep, ink, neutral * lightPlate);
        vec3 rgb = mix(glyphRgb, plateRgb, member);
        // No plate (a white page, a light logo): a large light neutral area is darkened like a plate, and a neutral dark
        // glyph inside it inverts.
        float lightCtx = (1.0 - strength) * smoothstep(0.55, 0.8, luma(local)) * (1.0 - smoothstep(0.08, 0.25, chroma(local)));
        float memberV = 1.0 - smoothstep(plateToleranceLow, plateToleranceHigh, distance(c, local));
        vec3 plateV = c * min(darkPlateLuma / max(luma(local), 0.1), 1.0);
        vec3 inkV = vec3(mix(darkPlateLuma, darkGlyphLuma, clamp((1.0 - Lc / max(luma(local), 0.1)) * 3.0, 0.0, 1.0)));
        vec3 glyphV = mix(c, inkV, neutral);
        rgb = mix(rgb, mix(glyphV, plateV, memberV), lightCtx);
        rgb = mix(rgb, vec3(1.0), edge * darkRim * (isDark ? 1.0 : 0.0));
        outc = vec4(rgb * a, a);
    } else if (modeIndex < 2.5) {
        // CLEAR: the plate becomes translucent glass (light in the dark appearance, smoked in the light one) and the
        // glyph a monochrome ink whose shading follows the glyph's contrast with the plate.
        float inkL = isDark ? clearInkDark : clearInkLight;
        float relShade = clamp(0.3 + 0.7 * Lc / (Lmean * 1.5), 0.3, 1.0);   // no plate: the icon's mean is a bright ink, darker parts dim
        float detail = mix(clamp((relShade - 0.405) / 0.595, 0.0, 1.0), clamp(distance(c, plate) * 1.6, 0.0, 1.0), strength);
        vec3 ink = isDark ? vec3(inkL * (1.0 - clearDetail * 0.7 * (1.0 - detail)))
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
        float relShade = clamp(0.3 + 0.7 * Lc / (Lmean * 1.5), 0.3, 1.0);
        float detail = mix(clamp((relShade - 0.3) / 0.7, 0.0, 1.0), clamp(distance(c, plate) * 1.6, 0.0, 1.0), strength);
        float shade = mix(1.0, 0.3 + 0.7 * detail, tintedDetail);
        vec3 base = isDark ? mix(t, vec3(1.0), tintedGlyphLift) : t * tintedGlyphShadeLight;
        vec3 ink = base * shade;
        float rr = clamp(Lc / Lp, 0.8, 1.2);
        vec3 plateRgb = (isDark ? t * tintedPlateScale : mix(t, vec3(1.0), tintedPlateMixLight)) * rr;
        vec3 rgb = mix(ink, min(plateRgb, vec3(1.0)), member);
        rgb = mix(rgb, isDark ? mix(base, vec3(1.0), 0.4) : base * 0.6, edge * tintedRim);
        outc = vec4(rgb * a, a);
    }
    fragColor = outc * qt_Opacity;
}
