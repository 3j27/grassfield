#!/usr/bin/env bash
# Build the Grassfield cursor theme (hyprcursor SVG theme + XCursor fallback) from branding/cursors/src.
#
#   build.sh [--out ICONS_DIR] [--name NAME] [--fill #RRGGBB] [--outline #RRGGBB] [--sizes "24 32 48 64 96"]
#   build.sh --remove [--out ICONS_DIR] [--name NAME]      delete the theme ICONS_DIR/NAME (the shell's "Reset Color")
#   build.sh --clean [--out ICONS_DIR] [--name NAME]       delete the work directories of builds that are no longer running
#
# Output: ICONS_DIR/NAME/{index.theme,manifest.hl,hyprcursors/*.hlc,cursors/*,colors}  (written atomically).
# `colors` is the stamp of the theme: one line "#outline #fill" (lower case), the colours it was built for. The shell
# (shell/platform/PointerTheme.qml) decides from it whether the theme on disk is the one of the stored colours.
# Defaults: ICONS_DIR=<repo>/.dev/share/icons, NAME=grassfield-cursors, fill #000000, outline #FFFFFF.
# The package build uses --out "$pkgdir/usr/share/icons"; the shell (shell/platform/PointerTheme.qml) regenerates the
# theme for the pointer colours at runtime with
#   --name grassfield-cursors-custom --out "$XDG_DATA_HOME/icons" --fill ... --outline ...
# SIGTERM stops the build, its children (renderers, packers) and removes its work directory (the shell supersedes a
# build with a newer colour; it also signals the whole process group, the build is started under setsid). A build that
# was killed (SIGKILL) leaves a work directory named .NAME.build.PID.XXXXXX: the next --clean, --remove or build removes
# every one whose PID is not running any more, at once.
# Tools: hyprcursor-util (package hyprcursor), rsvg-convert (librsvg), python3: runtime dependencies of grassfield-desktop.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../.." && pwd)
out=$root/.dev/share/icons
name=grassfield-cursors
fill='#000000'
outline='#FFFFFF'
sizes='24 32 48 64 96'
verbose=0
remove=0
clean=0
stage() { ((verbose)) && printf 'cursors: %-12s t=%ss\n' "$1" "${EPOCHREALTIME:0:-3}" >&2 || true; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --out) out=${2:?--out needs a directory}; shift ;;
    --name) name=${2:?--name needs a value}; shift ;;
    --fill) fill=${2:?--fill needs a colour}; shift ;;
    --outline) outline=${2:?--outline needs a colour}; shift ;;
    --sizes) sizes=${2:?--sizes needs a list}; shift ;;
    --remove) remove=1 ;;
    --clean) clean=1 ;;
    -v|--verbose) verbose=1 ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "cursors: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

# Letters, digits, - and _ only: the name becomes a directory name, the manifest name and an index.theme value
# ("..", "." and names with dots or slashes are refused).
[[ $name =~ ^[A-Za-z0-9_-]+$ ]] || { echo "cursors: invalid theme name (letters, digits, - and _ only)" >&2; exit 2; }
# Work directories of builds that are no longer running (their PID is in the name; a name without one is stale too).
clean_stale() {
  local d base pid
  for d in "$out"/."$name".build.*; do
    [[ -d $d ]] || continue
    base=${d##*/}
    pid=${base#".$name.build."}
    pid=${pid%%.*}
    if [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then continue; fi
    rm -rf -- "$d"
  done
  return 0
}
if ((clean)); then
  clean_stale
  exit 0
fi
if ((remove)); then
  # Only a directory that is a cursor theme of ours (it holds manifest.hl) is deleted, nothing else under ICONS_DIR.
  if [[ -f $out/$name/manifest.hl ]]; then rm -rf -- "${out:?}/${name:?}"; fi
  rm -rf -- "${out:?}/${name:?}.old"
  clean_stale
  exit 0
fi

hex_re='^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$'
[[ $fill =~ $hex_re && $outline =~ $hex_re ]] || { echo "cursors: --fill/--outline must be #RRGGBB or #RRGGBBAA" >&2; exit 2; }
[[ $sizes =~ ^[0-9]+( [0-9]+)*$ ]] || { echo "cursors: --sizes must be a space separated list of integers" >&2; exit 2; }
for tool in hyprcursor-util rsvg-convert python3; do
  command -v "$tool" >/dev/null || { echo "cursors: $tool not found" >&2; exit 1; }
done

mkdir -p "$out"
# Work directories left by a build that was killed (SIGKILL): removed now, not after an hour.
clean_stale
work=$(mktemp -d "$out/.${name}.build.$$.XXXXXX")
# Every process below this one (a renderer, a packer, the subshell around it): children first.
descendants() {
  local c
  for c in $(pgrep -P "$1" 2>/dev/null || true); do
    descendants "$c"
    echo "$c"
  done
}
# Stop the children, wait for them, then remove the work directory (retried: a child that is still exiting may be
# writing into it). Runs on every way out, so no process outlives the build and no directory is left behind.
cleanup() {
  local i p
  trap - EXIT
  for p in $(descendants "$$"); do kill -TERM "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8 9 10; do
    rm -rf -- "$work" 2>/dev/null || true
    [[ -e $work ]] || return 0
    sleep 0.2
  done
  return 0
}
trap cleanup EXIT
# SIGTERM (the shell superseding this build with a newer colour): the EXIT trap stops the children and cleans up.
trap 'trap "" TERM INT; exit 143' TERM INT
svgdir=$work/svg pngdir=$work/png hc=$work/hc theme=$work/theme
mkdir -p "$svgdir" "$pngdir" "$hc/hyprcursors" "$theme/cursors"

# frame_angle FRAME FRAMES -> rotation of the spinner template in degrees
frame_angle() { echo $(( $1 * 360 / $2 )); }

# 1. Render the templates: svg/<source>-<frame>.svg
declare -a table=()
while read -r source hx hy frames names; do
  [[ -z $source || $source == \#* ]] && continue
  table+=("$source $hx $hy $frames $names")
  for ((f = 0; f < frames; f++)); do
    sed -e "s|{{FILL}}|$fill|g" -e "s|{{OUTLINE}}|$outline|g" -e "s|{{ANGLE}}|$(frame_angle "$f" "$frames")|g" \
      "$here/src/$source.svg.in" > "$svgdir/$source-$f.svg"
  done
done < "$here/cursors.tsv"

# 2. hyprcursor source tree (SVG, size independent): one folder per source, canonical name = first name.
{
  echo "name = $name"
  echo "description = Grassfield cursors (original, CC-BY-SA-4.0)"
  echo "version = 1.0"
  echo "cursors_directory = hyprcursors"
} > "$hc/manifest.hl"
# 3. PNG render jobs and the XCursor packer commands, one line each.
: > "$work/png-jobs"
: > "$work/pack-jobs"
for row in "${table[@]}"; do
  read -r source hx hy frames names <<<"$row"
  canon=${names%%,*}
  dir=$hc/hyprcursors/$canon
  mkdir -p "$dir"
  cp "$svgdir/$source"-*.svg "$dir/"
  {
    echo "resize_algorithm = none"
    # Seven decimals keep the 1/64 steps of the table exact: libhyprcursor rounds the product with the size, and a
    # shorter number (%.5f) turns 12.5/32 into 0.39062 and a hotspot of 12 where the XCursor file has 13.
    awk -v x="$hx" -v y="$hy" 'BEGIN { printf "hotspot_x = %.7f\nhotspot_y = %.7f\n", x / 32, y / 32 }'
    echo "nominal_size = 1.0"
    IFS=, read -ra all <<<"$names"
    for alias in "${all[@]:1}"; do echo "define_override = $alias"; done
    for ((f = 0; f < frames; f++)); do
      if ((frames > 1)); then echo "define_size = 0, $source-$f.svg, 80"; else echo "define_size = 0, $source-$f.svg"; fi
    done
  } > "$dir/meta.hl"

  args=()
  for size in $sizes; do
    for ((f = 0; f < frames; f++)); do
      printf '%s\t%s\t%s\n' "$size" "$pngdir/$source-$f-$size.png" "$svgdir/$source-$f.svg" >> "$work/png-jobs"
      args+=("$size:$pngdir/$source-$f-$size.png")
    done
  done
  delay=0; ((frames > 1)) && delay=80
  # Tab separated: paths may contain spaces.
  { printf '%s\t%s\t%s\t%s' "$theme/cursors/$canon" "$hx" "$hy" "$delay"; printf '\t%s' "${args[@]}"; echo; } >> "$work/pack-jobs"
done

stage render-svg
# Bounded parallelism (GRASSFIELD_CURSOR_JOBS, default min(nproc, 4)): a machine under load (other builds, a memory
# limited cgroup) kills renders with SIGKILL when eight run at once.
par=$(nproc 2>/dev/null || echo 4)
jobs_max=${GRASSFIELD_CURSOR_JOBS:-4}
[[ $jobs_max =~ ^[1-9][0-9]*$ ]] || jobs_max=4
((par > jobs_max)) && par=$jobs_max
export GRASSFIELD_CURSOR_JOBS=$par
# render SIZE PNG SVG: one retry after a failure (a killed or crashed renderer), then a clear error.
render() {
  rsvg-convert -w "$1" -h "$1" -o "$2" "$3" 2>/dev/null && return 0
  sleep 1
  rsvg-convert -w "$1" -h "$1" -o "$2" "$3" && return 0
  echo "cursors: rendering $3 at $1 px failed twice (rsvg-convert; out of memory or killed?)" >&2
  return 1
}
stage png
while IFS=$'\t' read -r size png svg; do
  render "$size" "$png" "$svg" &
  while (($(jobs -rp | wc -l) >= par)); do wait -n || exit 1; done
done < "$work/png-jobs"
wait || { echo "cursors: rendering failed" >&2; exit 1; }
stage xcursor
while IFS=$'\t' read -r -a job; do
  { python3 -I "$here/xcursor-pack.py" "${job[0]}" --hotspot "${job[1]}" "${job[2]}" --delay "${job[3]}" "${job[@]:4}" \
    || { sleep 1; python3 -I "$here/xcursor-pack.py" "${job[0]}" --hotspot "${job[1]}" "${job[2]}" --delay "${job[3]}" "${job[@]:4}"; }; } &
  while (($(jobs -rp | wc -l) >= par)); do wait -n || exit 1; done
done < "$work/pack-jobs"
wait || { echo "cursors: xcursor-pack failed" >&2; exit 1; }

stage aliases
# 4. Aliases: relative symlinks to the canonical file.
for row in "${table[@]}"; do
  read -r source hx hy frames names <<<"$row"
  IFS=, read -ra all <<<"$names"
  for alias in "${all[@]:1}"; do ln -sf "${all[0]}" "$theme/cursors/$alias"; done
done

# 5. hyprcursor theme (.hlc archives) next to the XCursor folder.
stage hyprcursor
mkdir -p "$work/hcout"
hyprcursor-util --create "$hc" -o "$work/hcout" >"$work/hyprcursor-util.log" 2>&1 \
  || { cat "$work/hyprcursor-util.log" >&2; echo "cursors: hyprcursor-util --create failed" >&2; exit 1; }
built=$(find "$work/hcout" -mindepth 1 -maxdepth 1 -type d | head -n 1)
[[ -n $built && -f $built/manifest.hl ]] || { cat "$work/hyprcursor-util.log" >&2; echo "cursors: no hyprcursor theme produced" >&2; exit 1; }
cp -a "$built/." "$theme/"
# The stamp: the colours this theme was built for (the shell compares it with the stored colours).
printf '%s %s\n' "${outline,,}" "${fill,,}" > "$theme/colors"
cat > "$theme/index.theme" <<EOF
[Icon Theme]
Name=$name
Comment=Grassfield cursors (original artwork, CC-BY-SA-4.0)
EOF

stage install
# 6. Install atomically.
rm -rf "$out/$name.old"
[[ -e $out/$name ]] && mv "$out/$name" "$out/$name.old"
mv "$theme" "$out/$name"
rm -rf "$out/$name.old"
echo "$out/$name"
