# FluidVoice — fork with media volume ducking

Unofficial fork of [FluidVoice](https://github.com/altic-dev/FluidVoice), the open-source,
on-device dictation app for macOS by [altic-dev](https://github.com/altic-dev). Same app, same
GPLv3 license, plus the changes listed below. The original README is preserved as
[UPSTREAM-README.md](UPSTREAM-README.md); everything it says about features, models, privacy and
contributing still applies.

## What's different

### Lower Volume Instead of Pausing

Upstream can only *pause* whatever is playing while you dictate. This fork adds a gentler option:
fade the Mac's output volume down to a fraction of its current level while recording, and fade it
back the moment you stop.

Settings → Dictation → **Pause Media During Transcription** → **Lower Volume Instead of Pausing**,
then pick the level with **Volume While Dictating** (5–100 % of the current volume, default 20 %).

How it behaves:

- Fades over ~120 ms instead of jumping, both down and back up.
- Volume comes back when you release the hotkey, not after transcription finishes.
- If you change the volume (or mute) during a dictation, your choice is kept.
- Does not depend on the Now Playing service, so it also quiets browser tabs, games and calls,
  and works on Intel Macs. If the output device has no adjustable volume, it falls back to pausing.
- Per-channel balance is preserved; the last device that was ducked is the one restored, even if
  the default output changed mid-dictation.
- The start/stop sound cues never fight the duck: while ducking owns the system volume, the
  cues' *Independent Volume* override is skipped.

Implementation: `SystemAudioVolumeController` (CoreAudio, adapted from upstream
[PR #459](https://github.com/altic-dev/FluidVoice/pull/459) by akar016012) and a `duck` mode inside
`MediaPlaybackService`, the media reconciler upstream introduced in
[#955](https://github.com/altic-dev/FluidVoice/pull/955). Eleven unit tests cover the duck/restore
paths.

### Automatic updates point at this fork

Upstream's updater installs new GitHub releases automatically. In a fork that would silently replace
the app with the next upstream release, so the updater (hourly check, menu bar item, Settings button)
now watches `aonovo/FluidVoice`. Until this fork publishes releases it simply reports "up to date".
The in-app changelog viewer still shows upstream's release notes.

## Install

Requirements: macOS 15 or later, Xcode 26.2 or later, and a code-signing identity. A free personal
Apple Development certificate is enough for a Debug build; a Developer ID Application certificate
gives you a Release build that keeps its Accessibility permission across rebuilds.

```bash
git clone https://github.com/aonovo/FluidVoice.git
cd FluidVoice

# Debug build (bundle id com.FluidApp.app.debug, separate settings and permissions)
./build.sh
open "DerivedData/Build/Products/Debug/FluidVoice Debug.app"

# Release build signed with your Developer ID (bundle id com.FluidApp.app)
./scripts/build-release.sh
cp -R dist/FluidVoice.app /Applications/
```

The Release build is **not notarized**. That is fine for the Mac it was built on (no quarantine
flag, Gatekeeper never asks). To share the app with other Macs, notarize it with `notarytool` first.

If you installed upstream through Homebrew, run `brew uninstall --cask fluidvoice` first so a later
`brew upgrade` does not put upstream back. After replacing the app, macOS will ask for Accessibility
and Microphone again, because the signing identity differs from upstream's.

## Tips

- Dictating into a terminal TUI (Claude Code in cmux, Ghostty, tmux)? Set Settings → Dictation →
  **Text Insertion Mode** to **Clipboard Paste**; the default key-event path is swallowed by those
  apps (upstream [#479](https://github.com/altic-dev/FluidVoice/issues/479)).
- Keep **Independent Volume** for the sound cues off: it rewrites the system volume for every cue
  and is the cause of the volume spike reported in upstream
  [#522](https://github.com/altic-dev/FluidVoice/issues/522).
- Ducking activity is logged in `~/Library/Logs/Fluid/Fluid.log` as `MEDIA_CONTROL duck_*` lines.

## Known issues

- On macOS 15 with Xcode 26.x the full test suite aborts 41 times inside Swift's back-deployed
  isolated deinit (upstream [#772](https://github.com/altic-dev/FluidVoice/issues/772),
  [swiftlang/swift#85663](https://github.com/swiftlang/swift/issues/85663)). The app is not affected;
  run targeted suites, e.g.
  `xcodebuild test -scheme Fluid -only-testing:FluidDictationIntegrationTests/MediaPlaybackServiceTests`.
  Fixed in Xcode 27.

## Tracking upstream

`main` is upstream's `main` plus this fork's commits and is re-synced periodically. Each change is
listed with its date in [CHANGES.md](CHANGES.md). Bug reports about FluidVoice itself belong
upstream; issues about the ducking option belong here.

## License and attribution

FluidVoice is free software under the GNU General Public License v3.0, see [LICENSE](LICENSE).
Copyright © altic-dev and the FluidVoice contributors. Modifications copyright © 2026
Aleksandr Novozhilov ([aonovo](https://github.com/aonovo)), released under the same license.
As required by GPLv3 §5, modified files carry their changes in git history and are summarized in
[CHANGES.md](CHANGES.md). Fluid Intelligence, upstream's privately maintained local AI runtime, is not
part of this repository, exactly as with upstream.
