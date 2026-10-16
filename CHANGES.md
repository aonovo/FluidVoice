# Changes from upstream

This fork tracks [altic-dev/FluidVoice](https://github.com/altic-dev/FluidVoice). Per GPLv3 §5(a),
this file lists the modifications and their dates; `git log upstream/main..main` has the details.

## 2026-09-17 — base: upstream `main` @ 0039d64 (1.6.10-beta.2)

- **feat(media): lower output volume instead of pausing during dictation.** New
  `Sources/Fluid/Services/SystemAudioVolumeController.swift` (adapted from upstream PR #459);
  `MediaPlaybackService` gains a `MediaSuppression` mode (`none` / `pause` / `duck`) with fade,
  restore on stop, user-change and mute detection and pause fallback; new settings
  `duckMediaInsteadOfPausing` and `duckMediaVolumeLevel` with backup support; Settings UI toggle
  and slider; settings-search entry; `TranscriptionSoundPlayer` skips the cues' independent-volume
  override while ducking is active; eleven new tests in `MediaPlaybackServiceTests`.
  Modified: `ASRService.swift`, `BackupService.swift`, `MediaPlaybackService.swift`,
  `SettingsSearch.swift`, `SettingsStore.swift`, `SettingsView.swift`,
  `TranscriptionSoundPlayer.swift`, `MediaPlaybackServiceTests.swift`.
- **feat(text): speech cleanup with language rule packs.** New
  `Sources/Fluid/Services/SpeechCleanup.swift` replaces the body of `ASRService.removeFillerWords`:
  tokenizer-based removal of filler phrases and punctuation-guarded filler words per language pack
  (English, Russian), hesitation sounds, stuttered repeats, Whisper-style hallucination phrases and
  Latin letters inside Cyrillic words; new settings `speechCleanupLanguagePackIDs`,
  `speechCleanupRemovesRepeatedWords`, `speechCleanupRemovesHallucinations`,
  `speechCleanupFixesLatinInCyrillic` (backup-compatible); Voice Engine settings UI; tests in
  `SpeechCleanupTests`. Modified: `ASRService.swift`, `AISettingsView+SpeechRecognition.swift`,
  `BackupService.swift`, `SettingsStore.swift`.
- **chore(updater): point automatic updates at this fork.** `AppDelegate.swift`,
  `MenuBarManager.swift`, `SettingsView.swift` now query `aonovo/FluidVoice` releases.
- **docs:** fork README (original kept as `UPSTREAM-README.md`), this file,
  `scripts/build-release.sh`, `dist/` ignored.

## 2026-09-24 — rebased onto upstream `main` @ a0f4f4b (1.6.10-beta.7)

- **feat(media)** ported onto upstream's media reconciler (#957): ducking is the `duck` mode of
  `MediaSuppression`, handled with the reconciler's session tracking and shutdown. The
  `TranscriptionSoundPlayer` change was dropped, upstream #989 removed Independent Volume.
- **fix(build):** split three upstream expressions the Xcode 26.2 type checker gives up on.
- **fix(ui):** `ReleaseHighlightsPresenter.WindowReference` is `nonisolated`; its isolated deinit
  crashed the test host on macOS 15 (swiftlang/swift#85663).

## 2026-10-01 — ducking and microphone timing (review on upstream PR #459)

- **perf(media):** every CoreAudio volume read/write goes through `OutputVolumeWorker`, an actor
  on its own serial queue, instead of the main actor. A failed post-duck reread no longer
  suppresses the restore; a partial duck that cannot be undone is restored on stop.
- **chore(media):** Debug builds log each volume call (`MEDIA_BENCH`) with duration and thread.
- **feat(media):** the ducking setting notes that it works best with headphones.
- **chore(tools):** `tools/media_suppression_bench/`, a latency and accuracy bench for the media
  suppression modes (fork only).

## 2026-10-14 — ducking waits for the microphone

- **fix(media):** ducking starts only after `ASRService` reports the first PCM buffer
  (`MediaPlaybackService.captureStarted`), so no volume call overlaps microphone startup; a
  restore that fails keeps the original level owed. Four new tests. Modified: `ASRService.swift`,
  `MediaPlaybackService.swift`, `MediaPlaybackServiceTests.swift`.
- **chore(tools):** the bench picks the microphone through `MicrophonePriority` and checks which
  microphone each session used and that the volume came back.
- **docs:** `scripts/notarize-release.sh` notarizes the Release build and builds a disk image.
