.pragma library

// The size of an output in LOGICAL pixels, the unit window positions and sizes are in (Hyprland's `at` / `size`, the Overview's
// layout area). A Hyprland monitor reports its size in device pixels, so on an output with scale 1.5 or 2 it is 1.5 or 2 times too
// large and a desktop miniature drawn from it shrinks the windows by the same factor.
//   screens: the shell's screens (name, width, height: logical), monitor: the Hyprland monitor ({width, height, lastIpcObject})
// Returns {w, h}; {w: 0, h: 0} when neither is known.
function logicalSize(screens, name, monitor) {
    if (screens) {
        for (let i = 0; i < screens.length; i++) {
            const s = screens[i];
            if (s && s.name === name && s.width > 0 && s.height > 0)
                return {w: s.width, h: s.height};
        }
    }
    if (!monitor || !(monitor.width > 0) || !(monitor.height > 0))
        return {w: 0, h: 0};
    const ipc = monitor.lastIpcObject;
    const scale = ipc && ipc.scale > 0 ? ipc.scale : 1;
    return {w: monitor.width / scale, h: monitor.height / scale};
}
