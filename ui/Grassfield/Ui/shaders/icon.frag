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
    float sysPlateInset;    // system plate (Clear, Tinted): inset from the icon box, in box fractions
    float sysPlateRadius;   // corner radius over the plate side
    float sysGlyphScale;    // scale of the artwork sitting on the system plate
    float plateToleranceLow;
    float plateToleranceHigh;
    float plateAlphaLow;
    float plateAlphaHigh;
    float darkPlateLuma;
    float darkPageLuma;
    float darkChromaKeep;
    float darkGlyphLuma;
    float darkGlyphBoost;
    float darkGlyphFloor;
    float darkRim;
    float clearPlateAlphaDark;
    float clearPlateAlphaWallpaper;
    float overWallpaper;      // 1: drawn over the bare wallpaper (desktop), not over a window material
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
    vec3 plate1 = sum2.a > 0.0001 ? sum2.rgb / sum2.a : taps[bi].rgb;
    float share1 = sum2.a / float(N);

    // A second plate colour (a plate of two colours, as the split face of a file-manager icon has): the dominant cluster of
    // the probes outside the first one, accepted when it holds a quarter of the probes. A pixel is plate when it is
    // near either colour, and each pixel is mapped by the colour it is nearest to.
    float best2 = -1.0;
    int bj = 0;
    float out1[N];
    for (int j = 0; j < N; ++j)
        out1[j] = taps[j].a * smoothstep(plateToleranceLow, plateToleranceHigh, distance(taps[bi].rgb, taps[j].rgb));
    for (int i = 0; i < N; ++i) {
        float w = 0.0;
        for (int j = 0; j < N; ++j)
            w += out1[j] * (1.0 - smoothstep(plateToleranceLow, plateToleranceHigh, distance(taps[i].rgb, taps[j].rgb)));
        w *= out1[i];
        if (w > best2) {
            best2 = w;
            bj = i;
        }
    }
    vec4 sumB = vec4(0.0);
    for (int j = 0; j < N; ++j) {
        float nearB = out1[j] * (1.0 - smoothstep(plateToleranceLow, plateToleranceHigh, distance(taps[bj].rgb, taps[j].rgb)));
        sumB += vec4(taps[j].rgb * nearB, nearB);
    }
    vec3 plate2 = sumB.a > 0.0001 ? sumB.rgb / sumB.a : plate1;
    float share2 = sumB.a / float(N);
    float use2 = smoothstep(0.2, 0.3, share2) * (best2 > 0.0 ? 1.0 : 0.0);
    vec3 plate = plate1;
    float strength = smoothstep(plateAlphaLow, plateAlphaHigh, share1 + use2 * share2);

    // The icon's own plate must also be a rounded square filling the box: the four corner probes are opaque. A round logo,
    // or a one-colour blob such as a mascot, is not a plate even when its colour dominates the probes.
    float corners = (texture(iconTexture, vec2(0.15, 0.15)).a + texture(iconTexture, vec2(0.85, 0.15)).a +
                     texture(iconTexture, vec2(0.15, 0.85)).a + texture(iconTexture, vec2(0.85, 0.85)).a) * 0.25;
    // ... and so are the four edge midpoints (a mascot logo with a notch between its ears is not).
    float edges = (texture(iconTexture, vec2(0.5, 0.08)).a + texture(iconTexture, vec2(0.5, 0.92)).a +
                   texture(iconTexture, vec2(0.08, 0.5)).a + texture(iconTexture, vec2(0.92, 0.5)).a) * 0.25;
    float own = strength * smoothstep(0.4, 0.8, min(corners, edges));
    strength = own;

    // Clear and Tinted: every icon sits on a system plate. An icon without its own plate also shrinks to sit inside it.
    float sysW = modeIndex > 1.5 ? 1.0 - own : 0.0;
    vec2 uv = mix(qt_TexCoord0, vec2(0.5) + (qt_TexCoord0 - vec2(0.5)) / sysGlyphScale, sysW);
    bool inBox = uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0;
    vec4 px = inBox ? straight(texture(iconTexture, uv)) : vec4(0.0);
    vec3 c = px.rgb;
    float a = px.a;

    // Context for icons without a plate: the local average colour (a blurred read) and the average of the whole icon.
    vec4 localT = textureLod(iconTexture, uv, 2.5);
    vec3 local = localT.rgb / max(localT.a, 0.0001);
    vec4 wholeT = textureLod(iconTexture, vec2(0.5), 12.0);
    float Lmean = max(luma(wholeT.rgb / max(wholeT.a, 0.0001)), 0.05);

    // 2. Plate membership (0 glyph .. 1 plate).
    // Per pixel: the nearer of the plate colours.
    if (use2 > 0.5 && distance(c, plate2) < distance(c, plate1))
        plate = plate2;
    float member = (1.0 - smoothstep(plateToleranceLow, plateToleranceHigh, distance(c, plate))) * strength;
    float Lc = luma(c);
    float Lp = max(luma(plate), 0.04);
    bool wall = overWallpaper > 0.5;
    bool isDark = dark > 0.5 || wall;

    // Edge band: inside the shape, within rimUv of a transparent texel.
    float lowest = min(min(texture(iconTexture, uv + vec2(rimUv, 0.0)).a, texture(iconTexture, uv - vec2(rimUv, 0.0)).a),
                       min(texture(iconTexture, uv + vec2(0.0, rimUv)).a, texture(iconTexture, uv - vec2(0.0, rimUv)).a));
    // Only opaque pixels carry the rim: a drop shadow around the shape (low opacity) is not lit.
    float edge0 = clamp(a - lowest, 0.0, 1.0) * smoothstep(0.8, 0.95, a) * rimGain;
    float edge = edge0 * strength;

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
        vec3 plateV = c * min(darkPageLuma / max(luma(local), 0.1), 1.0);
        vec3 inkV = vec3(mix(darkPlateLuma, darkGlyphLuma, clamp((1.0 - Lc / max(luma(local), 0.1)) * 3.0, 0.0, 1.0)));
        vec3 glyphV = mix(c, inkV, neutral);
        rgb = mix(rgb, mix(glyphV, plateV, memberV), lightCtx);
        // The rim also lights the outline of a darkened plateless page.
        rgb = mix(rgb, vec3(1.0), edge0 * max(strength, lightCtx) * darkRim * (isDark ? 1.0 : 0.25));
        outc = vec4(rgb * a, a);
    } else if (modeIndex < 2.5) {
        // CLEAR: the plate becomes translucent glass (light in the dark appearance, smoked in the light one) and the
        // glyph a monochrome ink whose shading follows the glyph's contrast with the plate.
        float inkL = isDark ? clearInkDark : clearInkLight;
        float relShade = clamp(0.3 + 0.7 * Lc / (Lmean * 1.5), 0.3, 1.0);   // no plate: the icon's mean is a bright ink, darker parts dim
        float detail = mix(clamp((relShade - 0.405) / 0.595, 0.0, 1.0), clamp(distance(c, plate) * 1.6, 0.0, 1.0), strength);
        vec3 ink = isDark ? vec3(inkL * (1.0 - clearDetail * 0.7 * (1.0 - detail)))
                          : vec3(inkL + clearDetail * 0.5 * (1.0 - detail));
        // Over a window material the glass is light on dark and smoked on light; over the bare wallpaper (any brightness)
        // it is strongly smoked, so the white ink and rim read on a white wallpaper and the plate edge on a black one.
        vec3 glass = (isDark && !wall) ? vec3(1.0) : vec3(0.0);
        float glassA = (wall ? clearPlateAlphaWallpaper : (isDark ? clearPlateAlphaDark : clearPlateAlphaLight)) * a;
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
        rgb = mix(rgb, isDark ? mix(base, vec3(1.0), 0.7) : base * 0.6, edge * tintedRim);
        outc = vec4(rgb * a, a);
    }
    if (modeIndex > 1.5 && sysW > 0.001) {
        // The system plate: a rounded square (macOS squircle proportions), glass in Clear, tinted in Tinted.
        float hs = 0.5 - sysPlateInset;
        float rad = sysPlateRadius * 2.0 * hs;
        vec2 q = abs(qt_TexCoord0 - vec2(0.5)) - vec2(hs - rad);
        float sdf = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - rad;
        float aa = max(fwidth(sdf), 0.0005);
        float mask = 1.0 - smoothstep(-aa, aa, sdf);
        float inside = -sdf;
        float band = smoothstep(0.0, aa, inside) * (1.0 - smoothstep(rimUv * 0.8, rimUv * 1.0, inside)) * rimGain;
        vec3 sysRgb;
        float sysA;
        vec3 rimRgb;
        float rimK;
        if (modeIndex < 2.5) {
            sysRgb = (isDark && !wall) ? vec3(1.0) : vec3(0.0);
            sysA = wall ? clearPlateAlphaWallpaper : (isDark ? clearPlateAlphaDark : clearPlateAlphaLight);
            rimRgb = vec3(isDark ? clearInkDark : clearInkLight);
            rimK = clearRim;
        } else {
            vec3 t2 = tint.rgb;
            vec3 baseS = isDark ? mix(t2, vec3(1.0), tintedGlyphLift) : t2 * tintedGlyphShadeLight;
            sysRgb = isDark ? t2 * tintedPlateScale : mix(t2, vec3(1.0), tintedPlateMixLight);
            sysA = 1.0;
            rimRgb = isDark ? mix(baseS, vec3(1.0), 0.7) : baseS * 0.6;
            rimK = tintedRim;
        }
        vec4 plateS = vec4(sysRgb * sysA, sysA);
        float rimS = band * rimK;
        plateS = vec4(rimRgb * rimS, rimS) + plateS * (1.0 - rimS);
        outc = outc + plateS * (mask * sysW) * (1.0 - outc.a);
    }
    fragColor = outc * qt_Opacity;
}
