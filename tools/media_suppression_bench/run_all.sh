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
ORIG_INPUT=$(defaults read $DOMAIN PreferredInputDeviceUID)
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
  defaults write $DOMAIN PreferredInputDeviceUID "$ORIG_INPUT"
  [[ -n "$ORIG_OUTPUT" ]] && $HERE/set-output "$ORIG_OUTPUT"
}
trap restore EXIT
trap "exit 130" INT TERM
# label | output device | input UID
configs=(
  "airpods-same|AirPods 4 aonovo|08-5D-53-E2-FD-D2:input"
  "airpods-out-builtin-mic|AirPods 4 aonovo|BuiltInMicrophoneDevice"
  "speakers-builtin-mic|Динамики MacBook Pro|BuiltInMicrophoneDevice"
)
# Optional arguments pick configurations by label, e.g. ./run_all.sh speakers-builtin-mic
for config in $configs; do
  IFS='|' read -r label output input <<< "$config"
  (( $# == 0 )) || (( ${@[(Ie)$label]} )) || continue
  $HERE/set-output "$output" || exit 1
  defaults write $DOMAIN PreferredInputDeviceUID "$input"
  for build in before after; do
    pkill -f "FluidVoice Debug.app"; sleep 2
    launch_build $build
    osascript -e 'tell application "TextEdit" to activate'
    python3 $HERE/bench_media.py run --modes none,pause,duck --count 20 --label "$label-$build" || exit 1
  done
done
python3 $HERE/bench_media.py report $HERE/results/*-{before,after}.json(N)
