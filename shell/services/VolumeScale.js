.pragma library

// Volume scale of the shell. PipeWire stores a linear channel volume (what Quickshell's PwNodeAudio.volume returns);
// WirePlumber's wpctl, pavucontrol, the Settings Sound page and the volume keys use the cubic scale: shown = cbrt(linear),
// so `wpctl get-volume @DEFAULT_AUDIO_SINK@` 0.50 is a linear 0.125. Every slider, the OSD and the IPC level of the
// shell speak the shown (perceptual) value, the way macOS sliders do; the linear value only crosses at the PipeWire write.

function toPerceptual(linear) {
    if (typeof linear !== "number" || isNaN(linear) || linear <= 0)
        return 0;
    return Math.min(1, Math.cbrt(linear));
}

function toLinear(perceptual) {
    if (typeof perceptual !== "number" || isNaN(perceptual) || perceptual <= 0)
        return 0;
    const p = Math.min(1, perceptual);
    return p * p * p;
}

// What wpctl prints for a shown value: two decimals.
function wpctlText(perceptual) {
    return perceptual.toFixed(2);
}
