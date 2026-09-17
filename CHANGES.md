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
