#version 440
// Icon appearance modes (ADR-0014): dark, clear and tinted renderings of an arbitrary theme icon.
// Build: scripts/dev/build-shaders.sh (qsb) -> icon.frag.qsb. Algorithm and limits: docs/specs/ui.md "Icon shader".
//
// One pass, no analysis of the icon (macOS gives every icon that is not made for the mode a system plate; so does this):
//  1. PLATE. Every icon sits on a system plate: a rounded square (squircle proportions) filling the box less an inset, graphite
//     in Dark, glass in Clear (light on a dark material, smoked on a light one or over the bare wallpaper), tinted in Tinted.
//  2. ARTWORK. The icon is drawn scaled down about the centre onto the plate, recoloured by a fixed transform per mode that
//     depends on the pixel alone (so FolderStyle.modeSamples can repeat it exactly):
//       Dark   a little desaturated, then an affine map in linear light from darkArtLift (black, so it separates from the graphite plate) to darkArtScale.
//       Clear  monochrome ink (light on dark, smoked on light) whose opacity follows the lightness of the artwork's luminance.
//       Tinted the lightness of the artwork's luminance mapped onto a two-tone ramp of the tint.
//     Every map is increasing and keeps a minimum slope, so the internal contrast of an icon survives (A2 "internal contrast").
//  3. RIM. A thin edge highlight on the plate, so a dark plate stays visible on a dark material; its width scales with the
//     icon size (never below a minimum) and it fades on small icons.
// The folder colour (FolderIcon) recolours the artwork only, after the mode transform: the plate and its rim stay.

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
    float sysPlateInset;    // system plate: inset from the icon box, in box fractions
    float sysPlateRadius;   // corner radius over the plate side
    float sysGlyphScale;    // scale of the artwork sitting on the plate
    float darkPlateLuma;
    float darkArtSaturation;
    float darkArtScale;
    float darkArtLift;
    float darkRim;
    float clearPlateAlphaDark;
    float clearPlateAlphaWallpaper;
    float overWallpaper;      // 1: drawn over the bare wallpaper (desktop), not over a window material
    float clearPlateAlphaLight;
    float clearInkDark;
    float clearInkLight;
    float clearBackdropDark;
    float clearBackdropLight;
    float clearBackdropMid;
    float rimInner;
    float darkRimLight;
    float tintedRimMixDark;
    float tintedRimShadeLight;
    float clearPlateAlphaAccent;
    float accentFill;         // 0: none; 1: over a bright accent fill (selected row), 2: over a dark one
    float clearRim;
    float tintedPlateScale;
    float tintedPlateMixLight;
    float tintedRampLowDark;
    float tintedRampHighDark;
    float tintedRampLowLight;
    float tintedRampHighLight;
    float tintedRim;
    vec4 folderTint;          // folder colour step (FolderIcon): a = 1 when the artwork is recoloured, 0 otherwise
    float folderBrightness;   // MultiEffect arithmetic of the folder colour (FolderEffect, tokens folderIcon*)
    float folderContrast;
    float folderColorization;
    float folderSaturation;
};

layout(binding = 1) uniform sampler2D iconTexture;

// Lightness of a colour: its relative luminance (linear light, gamma 2.2) encoded again. A pure red is 0.5 (its luminance is 0.21), not
// the 0.21 of a weighted sum of coded values: two colours that differ in luminance keep their difference in every mode.
float lightness(vec3 c) {
    return pow(dot(pow(c, vec3(2.2)), vec3(0.2126, 0.7152, 0.0722)), 1.0 / 2.2);
}

// Linear-light maps (gamma 2.2): the output luminance is an affine function of the input's, so a ratio of two luminances survives
// as well as a floor allows (black art mapped to a floor lo against white mapped to hi: (hi + 0.05) / (lo + 0.05) at most).
vec3 toLinear(vec3 c) {
    return pow(c, vec3(2.2));
}

vec3 fromLinear(vec3 c) {
    return pow(max(c, vec3(0.0)), vec3(1.0 / 2.2));
}

void main() {
    bool wall = overWallpaper > 0.5;
    bool accent = accentFill > 0.5;
    bool accentBright = accentFill < 1.5;
    bool isDark = dark > 0.5 || wall;

    // The artwork: the icon texture scaled about the centre by sysGlyphScale. Straight (non-premultiplied) colour.
    vec2 uv = vec2(0.5) + (qt_TexCoord0 - vec2(0.5)) / sysGlyphScale;
    bool inBox = uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0;
    vec4 px = texture(iconTexture, clamp(uv, vec2(0.0), vec2(1.0))) * (inBox ? 1.0 : 0.0);
    float a = px.a;
    vec3 c = px.rgb / max(a, 0.0001);
    vec3 lin = toLinear(c);
    float Y = dot(lin, vec3(0.2126, 0.7152, 0.0722));   // relative luminance of the artwork pixel

    // Per-mode transform of the artwork: rgb (straight) and the opacity it is drawn with.
    vec3 art;
    float artA = a;
    if (modeIndex < 1.5) {
        // Affine from darkArtLift (black) to darkArtScale (white): monotonic, a minimum slope, black stays darker than light art.
        vec3 d = mix(vec3(Y), lin, darkArtSaturation);
        vec3 lo = toLinear(vec3(darkArtLift));
        art = fromLinear(lo + (toLinear(vec3(darkArtScale)) - lo) * d);
    } else if (modeIndex < 2.5) {
        // Over an accent fill the ink is the opposite of the fill (light on a bright accent, dark on a dark one).
        bool lightInk = accent ? accentBright : isDark;
        float ink = lightInk ? clearInkDark : clearInkLight;
        art = vec3(ink);
        // The ink opacity is solved so that the colour on screen is affine in linear light between the glass (black art) and the ink
        // (white art), the glass being the plate over an assumed material: the contrast between two parts of the artwork survives.
        float pa = accent ? clearPlateAlphaAccent : (wall ? clearPlateAlphaWallpaper : (isDark ? clearPlateAlphaDark : clearPlateAlphaLight));
        float pg = accent ? (accentBright ? 0.0 : 1.0) : ((isDark && !wall) ? 1.0 : 0.0);
        float bd = (accent || wall) ? clearBackdropMid : (isDark ? clearBackdropDark : clearBackdropLight);
        float under = pg * pa + (1.0 - pa) * bd;
        float target = mix(pow(under, 2.2), pow(ink, 2.2), lightInk ? Y : 1.0 - Y);
        artA = a * clamp((pow(target, 1.0 / 2.2) - under) / (ink - under), 0.0, 1.0);
    } else {
        vec3 t = tint.rgb;
        vec3 lo = isDark ? t * tintedRampLowDark : t * tintedRampLowLight;
        vec3 hi = isDark ? mix(t, vec3(1.0), tintedRampHighDark) : mix(t, vec3(1.0), tintedRampHighLight);
        art = fromLinear(mix(toLinear(lo), toLinear(hi), Y));
    }
    art = clamp(art, 0.0, 1.0);
    if (folderTint.a > 0.5) {
        // The folder colour maps the luminance of the artwork onto the colour (the arithmetic of Qt's MultiEffect, which
        // FolderEffect uses as a layer over the plain icon in default mode). Only the artwork is recoloured.
        vec3 cc = (art - vec3(0.5)) * (1.0 + folderContrast) + vec3(0.5 + folderBrightness);
        float gray = dot(cc, vec3(0.299, 0.587, 0.114));
        vec3 rc = vec3(gray) + (folderTint.rgb * gray * folderColorization + cc * (1.0 - folderColorization) - vec3(gray)) * (1.0 + folderSaturation);
        art = clamp(rc, 0.0, 1.0);
    }
    vec4 artP = vec4(art * artA, artA);

    // The system plate: a rounded square, with the rim on its edge.
    float hs = 0.5 - sysPlateInset;
    float rad = sysPlateRadius * 2.0 * hs;
    vec2 q = abs(qt_TexCoord0 - vec2(0.5)) - vec2(hs - rad);
    float sdf = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - rad;
    float aa = max(fwidth(sdf), 0.0005);
    float mask = 1.0 - smoothstep(-aa, aa, sdf);
    float inside = -sdf;
    float band = smoothstep(0.0, aa, inside) * (1.0 - smoothstep(rimUv * rimInner, rimUv * 1.0, inside)) * rimGain;
    vec3 plateRgb;
    float plateA;
    vec3 rimRgb;
    float rimK;
    if (modeIndex < 1.5) {
        plateRgb = vec3(darkPlateLuma);
        plateA = 1.0;
        rimRgb = vec3(1.0);
        rimK = wall ? 1.0 : darkRim * (isDark ? 1.0 : darkRimLight);   // over the bare wallpaper the rim is fully opaque (it must read on any wallpaper)
    } else if (modeIndex < 2.5) {
        // Light glass on a dark material; smoked glass on a light one, and over the bare wallpaper (any brightness).
        bool lightInk = accent ? accentBright : isDark;
        plateRgb = accent ? vec3(accentBright ? 0.0 : 1.0) : ((isDark && !wall) ? vec3(1.0) : vec3(0.0));
        plateA = accent ? clearPlateAlphaAccent : (wall ? clearPlateAlphaWallpaper : (isDark ? clearPlateAlphaDark : clearPlateAlphaLight));
        rimRgb = vec3(lightInk ? clearInkDark : clearInkLight);
        rimK = clearRim;
    } else {
        vec3 t = tint.rgb;
        plateRgb = isDark ? t * tintedPlateScale : mix(t, vec3(1.0), tintedPlateMixLight);
        plateA = 1.0;
        rimRgb = isDark ? mix(t, vec3(1.0), tintedRimMixDark) : t * tintedRimShadeLight;
        rimK = tintedRim;
    }
    vec4 plateP = vec4(plateRgb * plateA, plateA);
    float rimA = band * rimK;
    plateP = vec4(rimRgb * rimA, rimA) + plateP * (1.0 - rimA);
    plateP *= mask;
    fragColor = (artP + plateP * (1.0 - artP.a)) * qt_Opacity;
}
