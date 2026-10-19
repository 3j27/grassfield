#version 440
// Plate analysis of an icon (ADR-0014), run ONCE per icon texture, not per pixel: it renders into a 2x1 texture that icon.frag
// reads (two texture fetches per pixel instead of 16 probes and a clustering). IconEffect.qml draws this shader over a 2x1 item
// whose output is a ShaderEffectSource; the source is live, so it is re-rendered only when the icon's texture changes.
// Build: scripts/dev/build-shaders.sh (qsb) -> icon_analysis.frag.qsb. Algorithm and limits: docs/specs/ui.md "Icon shader".
//
//  Texel 0: rgb = the plate colour, a = the strength of the icon's OWN plate (0 none .. 1 a rounded square filling the box).
//  Texel 1: rgb = the second plate colour (a two-colour plate), a = how much of it to use.
//
// PLATE ESTIMATE. 16 probes on a ring at about 0.36 from the centre: inside a plate and inside the thin light border some icons
// have at their edge (it starts near 0.40), but away from most glyphs. The plate is the DOMINANT colour cluster of the probes
// (the probe with the most close neighbours, weighted by opacity); probes on a glyph fall outside it. The strength is the share
// of probes in the cluster: a multi-coloured logo or a transparent background has no dominant cluster, hence no plate. The
// icon's own plate must also be a rounded square filling the box: the corner and edge-midpoint probes are opaque.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float plateToleranceLow;
    float plateToleranceHigh;
    float plateAlphaLow;
    float plateAlphaHigh;
};

layout(binding = 1) uniform sampler2D iconTexture;

// Straight (non-premultiplied) colour of a premultiplied texel; w = opacity.
vec4 straight(vec4 t) {
    return vec4(t.rgb / max(t.a, 0.0001), t.a);
}

void main() {
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
    // the probes outside the first one, accepted when it holds a quarter of the probes.
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
    float strength = smoothstep(plateAlphaLow, plateAlphaHigh, share1 + use2 * share2);

    float corners = (texture(iconTexture, vec2(0.15, 0.15)).a + texture(iconTexture, vec2(0.85, 0.15)).a +
                     texture(iconTexture, vec2(0.15, 0.85)).a + texture(iconTexture, vec2(0.85, 0.85)).a) * 0.25;
    float edges = (texture(iconTexture, vec2(0.5, 0.08)).a + texture(iconTexture, vec2(0.5, 0.92)).a +
                   texture(iconTexture, vec2(0.08, 0.5)).a + texture(iconTexture, vec2(0.92, 0.5)).a) * 0.25;
    float own = strength * smoothstep(0.65, 0.9, min(corners, edges));

    fragColor = qt_TexCoord0.x < 0.5 ? vec4(plate1, own) : vec4(plate2, use2);
}
