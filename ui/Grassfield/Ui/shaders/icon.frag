#version 440
// Icon appearance modes (ADR-0014): dark, clear and tinted renderings of an arbitrary theme icon.
// Build: scripts/dev/build-shaders.sh (qsb) -> icon.frag.qsb. Algorithm and limits: docs/specs/ui.md "Icon shader".
//
// Third-party icons have no separate plate and glyph layers, so they are separated per pixel:
//  1. PLATE ESTIMATE, once per icon texture (shaders/icon_analysis.frag renders it into a 2x1 texture that this shader reads):
//     16 probes on a ring inside the icon give the plate colour (dominant cluster), a second plate colour and the strength of
//     the icon's own plate (a rounded square filling the box; a logo on transparency has none).
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
    vec4 folderTint;          // folder colour step (FolderIcon): a = 1 when the artwork is recoloured, 0 otherwise
    float folderBrightness;   // MultiEffect arithmetic of the folder colour (FolderEffect, tokens folderIcon*)
    float folderContrast;
    float folderColorization;
    float folderSaturation;
    float localLow;           // local contrast (a stroke of nearly the plate's colour): below this it is not a stroke
    float localHigh;
    float strokeLod;          // mip level of the neighbourhood read: about a tenth of the decoded icon
};

layout(binding = 1) uniform sampler2D iconTexture;
layout(binding = 2) uniform sampler2D analysis;   // 2x1 plate analysis (icon_analysis.frag)

float luma(vec3 c) {
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

float chroma(vec3 c) {
    return max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
}

// Dark: the luma a plate colour is darkened to (a neutral plate goes to darkPlateLuma, a saturated one keeps part of its brightness).
float darkTarget(vec3 p) {
    float l = max(luma(p), 0.04);
    return mix(darkPlateLuma, l * darkChromaKeep, smoothstep(0.25, 0.6, chroma(p)));
}

// Straight (non-premultiplied) colour of a premultiplied texel; w = opacity.
vec4 straight(vec4 t) {
    return vec4(t.rgb / max(t.a, 0.0001), t.a);
}

void main() {
    // 1. Plate estimate: analysed once per icon texture by icon_analysis.frag into a 2x1 texture (not per pixel). Texel 0: the
    //    plate colour and the strength of the icon's own plate; texel 1: the second plate colour of a two-colour plate and how
    //    much of it to use.
    vec4 an0 = texture(analysis, vec2(0.25, 0.5));
    vec4 an1 = texture(analysis, vec2(0.75, 0.5));
    vec3 plate1 = an0.rgb;
    vec3 plate2 = an1.rgb;
    float use2 = an1.a;
    vec3 plate = plate1;
    float strength = an0.a;

    // Every icon sits on a system plate (macOS 26 gives non-conforming icons one in every style, Dark included). An icon without its own plate also shrinks to sit inside it.
    float sysW = 1.0 - strength;
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
    bool second = modeIndex < 1.5 && use2 > 0.5 && distance(c, plate2) < distance(c, plate1);
    if (second)
        plate = plate2;
    float member = (1.0 - smoothstep(plateToleranceLow, plateToleranceHigh, distance(c, plate))) * strength;
    float Lc = luma(c);
    float Lp = max(luma(plate), 0.04);
    // A glyph of nearly the plate's colour (a project-tool logo: the same hue, a little darker) is inside the plate tolerance and
    // would vanish into it. Local contrast brings it back: a pixel that is farther from the plate than its neighbourhood (a
    // blurred read) is on a stroke, one that is nearer (the plate beside a glyph) is not, so no halo forms around glyphs.
    vec4 wideT = textureLod(iconTexture, uv, strokeLod);
    vec3 wide = wideT.rgb / max(wideT.a, 0.0001);
    float dcol = max(distance(c, plate), 2.0 * abs(Lc - Lp));
    float dwide = max(distance(wide, plate), 2.0 * abs(luma(wide) - Lp));
    float stroke = smoothstep(localLow, localHigh, max(abs(Lc - luma(wide)), 0.6 * distance(c, wide))) * smoothstep(0.01, 0.05, dcol - dwide) * strength;
    member *= 1.0 - stroke;
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
        float plateTarget = darkTarget(plate);
        if (use2 > 0.5) {
            // Two plate colours (a split face, a sky and a mountain): darkened separately they become the same near-black. The
            // lighter one is lifted so that the pair keeps its contrast ratio (at most 2.5:1), never above its own brightness.
            float Y1 = pow(max(luma(plate1), 0.04), 2.2);
            float Y2 = pow(max(luma(plate2), 0.04), 2.2);
            float T1 = pow(darkTarget(plate1), 2.2);
            float T2 = pow(darkTarget(plate2), 2.2);
            bool firstIsLight = Y1 >= Y2;
            float Rn = min((max(Y1, Y2) + 0.05) / (min(Y1, Y2) + 0.05), 2.5);
            float Tlight = firstIsLight ? T1 : T2;
            float Tdark = firstIsLight ? T2 : T1;
            float Tlifted = min(max(Tlight, Rn * (Tdark + 0.05) - 0.05), max(Y1, Y2));
            bool pixelLight = second ? !firstIsLight : firstIsLight;
            plateTarget = pow(pixelLight ? Tlifted : Tdark, 1.0 / 2.2);
        }
        float k = min(plateTarget / Lp, 1.0);
        vec3 plateRgb = c * k;
        // Neutral dark glyphs invert when any of the plate colours is light (a two-colour plate with a light half).
        float Lplate = max(Lp, use2 > 0.5 ? luma(plate2) : 0.0);
        float lightPlate = smoothstep(0.45, 0.65, Lplate) * strength;
        float neutral = 1.0 - smoothstep(0.08, 0.25, chroma(c));
        // A glyph darker than the plate inverts to light; one LIGHTER than the plate (a white gear on a light grey plate) is light
        // too: the ink is as far from the plate as the glyph was, in either direction.
        float r = Lc / max(Lplate, 0.04);
        vec3 ink = vec3(mix(darkPlateLuma, darkGlyphLuma, clamp(abs(1.0 - r) * 3.0, 0.0, 1.0)));
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
        // No plate and not a page: the artwork sits on a dark system plate, so dark colours are lifted to a luma floor and a
        // near-black neutral glyph becomes light (a coloured logo keeps its colours).
        vec3 lifted = mix(min(c * clamp(darkGlyphFloor / max(Lc, 0.02), 1.0, 4.0), vec3(1.0)), vec3(darkGlyphLuma), neutral * (1.0 - smoothstep(0.2, 0.5, Lc)));
        rgb = mix(rgb, lifted, sysW * (1.0 - lightCtx));
        // The rim also lights the outline of a darkened plateless page.
        rgb = mix(rgb, vec3(1.0), edge0 * max(strength, lightCtx) * (wall ? 1.0 : darkRim * (isDark ? 1.0 : 0.25)));
        outc = vec4(rgb * a, a);
    } else if (modeIndex < 2.5) {
        // CLEAR: the plate becomes translucent glass (light in the dark appearance, smoked in the light one) and the
        // glyph a monochrome ink whose shading follows the glyph's contrast with the plate.
        float inkL = isDark ? clearInkDark : clearInkLight;
        float relShade = clamp(0.3 + 0.7 * Lc / (Lmean * 1.5), 0.3, 1.0);   // no plate: the icon's mean is a bright ink, darker parts dim
        float detail = mix(clamp((relShade - 0.405) / 0.595, 0.0, 1.0), max(clamp(distance(c, plate) * 3.0, 0.0, 1.0), stroke), strength);
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
        float detail = mix(clamp((relShade - 0.3) / 0.7, 0.0, 1.0), max(clamp(distance(c, plate) * 3.0, 0.0, 1.0), stroke), strength);
        float shade = mix(1.0, 0.3 + 0.7 * detail, tintedDetail);
        vec3 base = isDark ? mix(t, vec3(1.0), tintedGlyphLift) : t * tintedGlyphShadeLight;
        vec3 ink = base * shade;
        float rr = clamp(Lc / Lp, 0.8, 1.2);
        vec3 plateRgb = (isDark ? t * tintedPlateScale : mix(t, vec3(1.0), tintedPlateMixLight)) * rr;
        vec3 rgb = mix(ink, min(plateRgb, vec3(1.0)), member);
        rgb = mix(rgb, isDark ? mix(base, vec3(1.0), 0.9) : base * 0.6, edge * tintedRim);
        outc = vec4(rgb * a, a);
    }
    if (folderTint.a > 0.5 && outc.a > 0.0001) {
        // The folder colour maps the luminance of the artwork onto the colour (the arithmetic of Qt's MultiEffect, which
        // FolderEffect used as a layer over the whole icon, system plate and rim included). Only the artwork is recoloured: the
        // plate and its edge highlight stay, so a black folder keeps a visible plate on a black wallpaper.
        vec3 sc = outc.rgb / outc.a;
        vec3 cc = (sc - vec3(0.5)) * (1.0 + folderContrast) + vec3(0.5 + folderBrightness);
        float gray = dot(cc, vec3(0.299, 0.587, 0.114));
        vec3 rc = vec3(gray) + (folderTint.rgb * gray * folderColorization + cc * (1.0 - folderColorization) - vec3(gray)) * (1.0 + folderSaturation);
        outc = vec4(clamp(rc, 0.0, 1.0) * outc.a, outc.a);
    }
    if (sysW > 0.001) {
        // The system plate: a rounded square (macOS squircle proportions), graphite in Dark, glass in Clear, tinted in Tinted.
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
        if (modeIndex < 1.5) {
            sysRgb = vec3(darkPlateLuma);
            sysA = 1.0;
            rimRgb = vec3(1.0);
            rimK = wall ? 1.0 : darkRim * (isDark ? 1.0 : 0.25);   // over the bare wallpaper the rim is fully opaque (it must read on any wallpaper)
        } else if (modeIndex < 2.5) {
            sysRgb = (isDark && !wall) ? vec3(1.0) : vec3(0.0);
            sysA = wall ? clearPlateAlphaWallpaper : (isDark ? clearPlateAlphaDark : clearPlateAlphaLight);
            rimRgb = vec3(isDark ? clearInkDark : clearInkLight);
            rimK = clearRim;
        } else {
            vec3 t2 = tint.rgb;
            vec3 baseS = isDark ? mix(t2, vec3(1.0), tintedGlyphLift) : t2 * tintedGlyphShadeLight;
            sysRgb = isDark ? t2 * tintedPlateScale : mix(t2, vec3(1.0), tintedPlateMixLight);
            sysA = 1.0;
            rimRgb = isDark ? mix(baseS, vec3(1.0), 0.9) : baseS * 0.6;
            rimK = tintedRim;
        }
        vec4 plateS = vec4(sysRgb * sysA, sysA);
        float rimS = band * rimK;
        plateS = vec4(rimRgb * rimS, rimS) + plateS * (1.0 - rimS);
        outc = outc + plateS * (mask * sysW) * (1.0 - outc.a);
    }
    fragColor = outc * qt_Opacity;
}
