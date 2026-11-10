#!/usr/bin/env bash
# Tiny helper to drive Rocket League's window under Xwayland during shader capture.
#   rl-ui.sh shot OUT.png      screenshot of the game window
#   rl-ui.sh key KEY [...]     send keys (xdotool names) to the game window
#   rl-ui.sh click X Y         click at X,Y in screenshot coordinates (960 wide)
#   rl-ui.sh hold KEY SECS     hold a key
#   rl-ui.sh mouse BTN SECS    hold a mouse button (1 boost, 3 jump in default binds)
#   rl-ui.sh wid               print the window id
set -eu
X="$(cd "$(dirname "$0")/../.." && pwd)/build/tools-xdotool/root"
export DISPLAY="${DISPLAY:-:0}" LD_LIBRARY_PATH="$X/usr/lib/x86_64-linux-gnu"
XD="$X/usr/bin/xdotool"
wid() { "$XD" search --name 'Rocket League' 2>/dev/null | tail -1; }
case "$1" in
  wid) wid ;;
  shot) W=$(wid); xwd -silent -id "$W" | ffmpeg -loglevel error -y -f xwd_pipe -i - -vf scale=960:-2 -frames:v 1 "$2" ;;
  click) W=$(wid); eval "$("$XD" getwindowgeometry --shell "$W")"; SX=$(( $2 * WIDTH / 960 )); SY=$(( $3 * WIDTH / 960 ))
         "$XD" windowactivate --sync "$W" 2>/dev/null || true; "$XD" mousemove --window "$W" "$SX" "$SY"; sleep 0.3; "$XD" click 1 ;;
  hold) W=$(wid); "$XD" keydown --window "$W" "$2"; sleep "$3"; "$XD" keyup --window "$W" "$2" ;;
  mouse) W=$(wid); "$XD" mousedown "$2"; sleep "$3"; "$XD" mouseup "$2" ;;
  key) W=$(wid); shift; "$XD" windowactivate --sync "$W" 2>/dev/null || true; for k in "$@"; do "$XD" key --window "$W" "$k"; sleep 0.6; done ;;
esac
