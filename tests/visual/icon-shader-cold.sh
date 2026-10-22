#!/usr/bin/env bash
# Cold compile of the icon shader (ADR-0014): a window animates, an effect with shaders/icon.frag.qsb appears at frame 8, and the
# length of each frame is printed. Every cache is off (QT_DISABLE_SHADER_DISK_CACHE, QSG_RHI_DISABLE_DISK_CACHE: Qt's; Mesa's
# MESA_SHADER_CACHE_DISABLE), so the frame in which the effect first draws holds the whole compile: a frame of 17 ms is the
# normal one. NOT a regression scenario. Needs the nested session (any scenario starts it). Run it as a BARE command.
#
#   tests/visual/icon-shader-cold.sh
source "$(dirname "$0")/lib.sh"
vs_session
sock=$(vs_nested_wayland)
"$VS_ROOT/scripts/dev/isolated.sh" --name cold env WAYLAND_DISPLAY="$sock" QT_QPA_PLATFORM=wayland QT_DISABLE_SHADER_DISK_CACHE=1 \
  QSG_RHI_DISABLE_DISK_CACHE=1 MESA_SHADER_CACHE_DISABLE=true QT_FORCE_STDERR_LOGGING=1 /usr/lib/qt6/bin/qml "$VS_HERE/icon-shader-cold.qml" 2>&1 \
  | grep -E "COLD frame (6|7|8|9|10|11|12) |status"
