#!/bin/zsh
# Runs every device configuration against the before/after Debug builds.
# Setup: swiftc -O post-note.swift -o post-note; swiftc -O set-output.swift -o set-output;
# put the two Debug builds in ../apps/{before,after}/ (before = 7962e6d8, after = 324913e3).
# Transcripts are pasted into the frontmost app: keep a blank TextEdit window in front
# and do not use the Mac while it runs (about 35 minutes).
set -u
HERE=${0:A:h}
APPS=${APPS:-$HERE/../apps}
DOMAIN=com.FluidApp.app.debug
ORIG_INPUT=$(defaults read $DOMAIN PreferredInputDeviceUID)
ORIG_OUTPUT="AirPods 4 aonovo"
restore() {
  pkill -f "FluidVoice Debug.app"
  defaults write $DOMAIN PreferredInputDeviceUID "$ORIG_INPUT"
  $HERE/set-output "$ORIG_OUTPUT"
}
trap restore EXIT
trap "exit 130" INT TERM
# label | output device | input UID
configs=(
  "airpods-same|AirPods 4 aonovo|08-5D-53-E2-FD-D2:input"
  "airpods-out-builtin-mic|AirPods 4 aonovo|BuiltInMicrophoneDevice"
  "speakers-builtin-mic|Динамики MacBook Pro|BuiltInMicrophoneDevice"
)
for config in $configs; do
  IFS='|' read -r label output input <<< "$config"
  $HERE/set-output "$output" || exit 1
  defaults write $DOMAIN PreferredInputDeviceUID "$input"
  for build in before after; do
    pkill -f "FluidVoice Debug.app"; sleep 2
    open -n "$APPS/$build/FluidVoice Debug.app"
    sleep 15
    osascript -e 'tell application "TextEdit" to activate'
    python3 $HERE/bench_media.py run --modes none,pause,duck --count 20 --label "$label-$build" || exit 1
  done
done
python3 $HERE/bench_media.py report $HERE/results/{airpods-same,airpods-out-builtin-mic,speakers-builtin-mic}-{before,after}.json
