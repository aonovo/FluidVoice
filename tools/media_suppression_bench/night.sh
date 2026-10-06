#!/bin/zsh
# Unattended run: latency bench for every configuration, then the speaker accuracy check.
# Usage: APPS=/path/to/apps MUSIC=/path/to/track.mp3 ./night.sh
set -u
HERE=${0:A:h}
DOMAIN=com.FluidApp.app.debug
caffeinate -dimsu -w $$ &
osascript -e 'tell application "TextEdit" to activate' -e 'tell application "TextEdit" to make new document' >/dev/null
sleep 1
echo "== latency $(date +%T)"
$HERE/run_all.sh || echo "latency bench stopped with $?"

echo "== accuracy $(date +%T)"
ORIG_INPUT=$(defaults read $DOMAIN PreferredInputDeviceUID)
$HERE/set-output "Динамики MacBook Pro"
SPEAKER_VOLUME=$(osascript -e 'output volume of (get volume settings)')
osascript -e 'set volume output volume 50'
defaults write $DOMAIN PreferredInputDeviceUID BuiltInMicrophoneDevice
pkill -f "FluidVoice Debug.app"; sleep 2
open -n "$APPS/after/FluidVoice Debug.app"
sleep 15
osascript -e 'tell application "TextEdit" to activate'
python3 $HERE/accuracy.py --music "$MUSIC" --label speakers || echo "accuracy stopped with $?"
pkill -f "FluidVoice Debug.app"
osascript -e "set volume output volume $SPEAKER_VOLUME"
defaults write $DOMAIN PreferredInputDeviceUID "$ORIG_INPUT"
$HERE/set-output "AirPods 4 aonovo"
echo "== done $(date +%T)"
