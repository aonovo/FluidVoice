#!/bin/zsh
# Runs every device configuration against the before/after Debug builds.
# Setup: swiftc -O post-note.swift -o post-note; swiftc -O set-output.swift -o set-output;
# put the two Debug builds in apps/{before,after}/ (outside /tmp, which macOS cleans) (before = 7962e6d8, after = 324913e3).
# Transcripts are pasted into the frontmost app: keep a blank TextEdit window in front
# and do not use the Mac while it runs (about 35 minutes).
set -u
HERE=${0:A:h}
APPS=${APPS:-$HERE/apps}
DOMAIN=com.FluidApp.app.debug
ORIG_OUTPUT=$(python3 -c "import sys; sys.path.insert(0, '$HERE'); import bench_media as b; print(b.output_device().get('output', ''))")
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
DERIVED="$HERE/../../DerivedData/Build/Products/Debug/FluidVoice Debug.app"
# All copies share one bundle id, and `open` may start whichever LaunchServices prefers.
# Unregister the other copies and check the running path before measuring.
launch_build() {
  local app="$APPS/$1/FluidVoice Debug.app"
  for other in "$DERIVED" "$APPS/before/FluidVoice Debug.app" "$APPS/after/FluidVoice Debug.app"; do
    [[ "$other" != "$app" && -d "$other" ]] && $LSREGISTER -u "$other"
  done
  $LSREGISTER -f "$app"
  open -n "$app"
  sleep 15
  if ! pgrep -fl "FluidVoice Debug" | grep -qF "${app:A}/Contents/MacOS"; then
    echo "wrong build running, expected $app:"; pgrep -fl "FluidVoice Debug"
    exit 1
  fi
}
restore() {
  pkill -f "FluidVoice Debug.app"
  [[ -d "$DERIVED" ]] && $LSREGISTER -f "$DERIVED"
  python3 $HERE/bench_media.py restore-mic
  [[ -n "$ORIG_OUTPUT" ]] && $HERE/set-output "$ORIG_OUTPUT"
}
trap restore EXIT
trap "exit 130" INT TERM
# A Bluetooth headset can be connected while its audio still goes to the phone; picking
# it in the menu bar Sound menu turns it into a CoreAudio device.
select_in_sound_menu() {
  osascript - "$1" <<'APPLESCRIPT' >/dev/null
on run argv
  tell application "System Events" to tell process "ControlCenter"
    click (first menu bar item of menu bar 1 whose description is "Звук" or description is "Sound")
    delay 1.5
    repeat with c in checkboxes of scroll area 1 of group 1 of window 1
      if (value of attribute "AXIdentifier" of c as text) contains (item 1 of argv) then click c
    end repeat
  end tell
  delay 3
  tell application "System Events" to key code 53
end run
APPLESCRIPT
}
# label | output device | input UID | expected mic name in Fluid.log
configs=(
  "airpods-same|AirPods 4 aonovo|08-5D-53-E2-FD-D2:input|AirPods"
  "airpods-out-builtin-mic|AirPods 4 aonovo|BuiltInMicrophoneDevice|MacBook"
  "speakers-builtin-mic|Динамики MacBook Pro|BuiltInMicrophoneDevice|MacBook"
)
# Optional arguments pick configurations by label, e.g. ./run_all.sh speakers-builtin-mic
for config in $configs; do
  IFS='|' read -r label output input expected <<< "$config"
  (( $# == 0 )) || (( ${@[(Ie)$label]} )) || continue
  if ! $HERE/set-output "$output"; then
    select_in_sound_menu "$output"
    $HERE/set-output "$output" || exit 1
  fi
  python3 $HERE/bench_media.py set-mic "$input"
  for build in before after; do
    pkill -f "FluidVoice Debug.app"; sleep 2
    launch_build $build
    osascript -e 'tell application "TextEdit" to activate'
    python3 $HERE/bench_media.py run --modes none,pause,duck --count 20 --label "$label-$build" --expect-input "$expected" || exit 1
  done
done
python3 $HERE/bench_media.py report $HERE/results/*-{before,after}.json(N)
