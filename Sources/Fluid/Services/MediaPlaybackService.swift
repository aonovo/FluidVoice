import Foundation

/// What a recording session asks the media service to do with audio that is playing.
nonisolated enum MediaSuppression: Equatable, Sendable {
    /// Leave media alone.
    case none
    /// Pause the Now Playing item and resume it once transcription finishes.
    case pause
    /// Lower the default output device volume to `level` (a fraction of the volume at
    /// recording start) and fade it back the moment recording stops.
    case duck(level: Float)

    var logDescription: String {
        switch self {
        case .none: return "none"
        case .pause: return "pause"
        case let .duck(level): return "duck(\(level))"
        }
    }
}

/// One reconciler owns all media queries and commands. Recording events update
/// intent synchronously; they never wait for media control or delay first PCM.
@MainActor
final class MediaPlaybackService {
    static let shared = MediaPlaybackService(transport: MediaPlaybackProcessTransport())

    /// Number of volume writes used to fade the output down and back up, so a duck is
    /// heard as a short fade rather than a jump.
    static let duckRampSteps = 6

    private struct Session {
        let id: Int
        let suppression: MediaSuppression
        var mayPause: Bool
    }

    /// The output volume we lowered. `original` is what gets restored; `applied` is what
    /// the device actually snapped to and is compared on restore to detect a user change.
    private struct DuckedVolume {
        let original: OutputVolumeSnapshot
        let applied: OutputVolumeSnapshot
    }

    private let transport: any MediaPlaybackTransport
    private let volumeController: any SystemAudioVolumeControlling
    private let settle: @Sendable () async -> Void
    private let rampStep: @Sendable () async -> Void
    private let now: @Sendable () -> TimeInterval
    private var session: Session?
    private var revision: UInt64 = 0
    private var attemptedSession: Int?
    private var pausedTarget: MediaPlaybackSnapshot?
    private var duckedVolume: DuckedVolume?
    private var worker: Task<Void, Never>?
    private var suspendedUntil: TimeInterval = 0
    private var isShuttingDown = false

    init(
        transport: any MediaPlaybackTransport,
        volumeController: any SystemAudioVolumeControlling = SystemAudioVolumeController(),
        settle: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(nanoseconds: 150_000_000)
        },
        rampStep: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(nanoseconds: 20_000_000)
        },
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.transport = transport
        self.volumeController = volumeController
        self.settle = settle
        self.rampStep = rampStep
        self.now = now
    }

    func recordingStarted(sessionID: Int, enabled: Bool) {
        self.recordingStarted(sessionID: sessionID, suppression: enabled ? .pause : .none)
    }

    func recordingStarted(sessionID: Int, suppression: MediaSuppression) {
        guard !self.isShuttingDown else { return }
        self.session = suppression == .none
            ? nil
            : Session(id: sessionID, suppression: suppression, mayPause: true)
        self.revision &+= 1
        self.log("recording_started session=\(sessionID) suppression=\(suppression.logDescription)")
        self.wake()
    }

    /// Prevent a slow query from issuing pause after the hotkey is released.
    /// A previously confirmed pause stays owned until transcription finishes;
    /// a ducked volume is faded back right away so music returns on key release.
    func recordingStopped(sessionID: Int) {
        guard self.session?.id == sessionID else { return }
        self.session?.mayPause = false
        self.revision &+= 1
        self.log("recording_stopped session=\(sessionID)")
        self.wake()
    }

    /// An older transcription finishing cannot resume a newer recording's media.
    func sessionFinished(sessionID: Int) {
        guard self.session?.id == sessionID else { return }
        self.session = nil
        self.revision &+= 1
        self.log("session_finished session=\(sessionID)")
        self.wake()
    }

    func beginShutdown() {
        guard !self.isShuttingDown else { return }
        self.isShuttingDown = true
        self.session = nil
        self.revision &+= 1
        self.wake()
    }

    func shutdown() async {
        self.beginShutdown()
        await self.waitUntilSettled()
    }

    /// Also used by deterministic tests; no continuous observer or polling task.
    func waitUntilSettled() async {
        while let worker = self.worker {
            await worker.value
        }
    }

    private func wake() {
        guard self.worker == nil else { return }
        self.worker = Task { await self.reconcile() }
    }

    private func reconcile() async {
        while true {
            let observedRevision = self.revision
            if let session = self.session {
                if session.mayPause, self.attemptedSession != session.id {
                    self.attemptedSession = session.id
                    await self.suppress(session)
                } else if session.mayPause == false, self.duckedVolume != nil {
                    await self.restoreDuckedVolume(context: "recording_stopped session=\(session.id)")
                }
            } else {
                if self.duckedVolume != nil {
                    await self.restoreDuckedVolume(context: "session_finished")
                }
                if let target = self.pausedTarget {
                    await self.resume(target: target)
                }
            }
            guard observedRevision != self.revision else {
                self.worker = nil
                return
            }
        }
    }

    private func suppress(_ session: Session) async {
        switch session.suppression {
        case .none:
            return
        case .pause:
            await self.pause(sessionID: session.id)
        case let .duck(level):
            guard await self.duck(sessionID: session.id, level: level) == false else { return }
            self.log("duck_fallback session=\(session.id) action=pause")
            await self.pause(sessionID: session.id)
        }
    }

    // MARK: - Ducking

    /// Fades the default output device down to `level` of its current volume.
    /// Returns `false` when the volume could not be lowered, so the caller can
    /// fall back to pausing instead.
    private func duck(sessionID: Int, level: Float) async -> Bool {
        if let ducked = self.duckedVolume {
            // The previous session's duck has not been restored yet (its stop is still in
            // flight). Keep it rather than capturing the ducked level as the "original".
            self.log("duck_retained session=\(sessionID) reason=already_owned level=\(ducked.applied.averageLevel)")
            return true
        }
        guard let original = self.volumeController.captureOutputVolume() else {
            self.log("duck_skipped session=\(sessionID) reason=no_settable_output_volume")
            return false
        }
        let target = original.scaled(by: level)
        let outcome = await self.ramp(from: original, to: target)
        guard outcome == .applied else {
            // Undo whatever landed so the device is not left in a mixed state.
            if self.volumeController.apply(original) != .applied {
                _ = self.volumeController.applyVirtualMainVolume(original)
            }
            self.log("duck_failed session=\(sessionID) outcome=\(outcome)")
            return false
        }
        // Re-read what the device actually snapped to (volume can be quantized to
        // coarse steps) so the restore-time change check is accurate.
        let applied = self.volumeController.reread(target) ?? target
        self.duckedVolume = DuckedVolume(original: original, applied: applied)
        self.log("duck_applied session=\(sessionID) from=\(original.averageLevel) to=\(applied.averageLevel)")
        return true
    }

    /// Fades the output back to the level captured before the duck. If the user changed
    /// the volume (or muted) during dictation, their choice is left alone.
    private func restoreDuckedVolume(context: String) async {
        guard let ducked = self.duckedVolume else { return }
        self.duckedVolume = nil
        guard let current = self.volumeController.reread(ducked.applied) else {
            self.log("duck_restore_skipped context=\(context) reason=device_unavailable")
            return
        }
        if Self.userChangedVolume(current, from: ducked.applied) {
            self.log(
                "duck_restore_skipped context=\(context) reason=user_changed_volume " +
                    "from=\(ducked.applied.averageLevel) to=\(current.averageLevel)"
            )
            return
        }
        if await self.ramp(from: current, to: ducked.original) == .applied {
            self.log("duck_restored context=\(context) level=\(ducked.original.averageLevel)")
        } else if self.volumeController.applyVirtualMainVolume(ducked.original) {
            // Some or all raw channel writes failed. The HAL virtual main volume keeps a
            // channel from staying stuck at the ducked level.
            self.log("duck_restored context=\(context) via=virtual_main_volume")
        } else {
            self.log("duck_restore_failed context=\(context) reason=output_device_unavailable")
        }
    }

    /// Writes intermediate levels between `start` and `end`, then `end` itself. The
    /// outcome of the final write is what counts; a failed intermediate step just ends
    /// the fade early. Shutdown skips the fade so quit stays within its deadline.
    private func ramp(
        from start: OutputVolumeSnapshot,
        to end: OutputVolumeSnapshot
    ) async -> SystemAudioVolumeController.ApplyOutcome {
        let steps = self.isShuttingDown ? 1 : Self.duckRampSteps
        for step in 1..<max(steps, 1) {
            let fraction = Float(step) / Float(steps)
            guard self.volumeController.apply(start.interpolated(toward: end, fraction: fraction)) == .applied else { break }
            await self.rampStep()
        }
        return self.volumeController.apply(end)
    }

    private static func userChangedVolume(
        _ current: OutputVolumeSnapshot,
        from applied: OutputVolumeSnapshot
    ) -> Bool {
        guard current.channels.count == applied.channels.count else { return true }

        return zip(current.channels, applied.channels).contains { currentChannel, appliedChannel in
            guard currentChannel.selector == appliedChannel.selector,
                  currentChannel.element == appliedChannel.element
            else { return true }

            // Mute is checked separately from the tolerance: a deeply ducked level can sit
            // within 0.02 of zero, and restoring over a mute would turn the user's audio
            // back on against their explicit intent.
            let userMuted = currentChannel.volume <= 0.001 && appliedChannel.volume > 0.001
            return userMuted || abs(currentChannel.volume - appliedChannel.volume) > 0.02
        }
    }

    // MARK: - Pausing

    private func canPause(_ sessionID: Int) -> Bool {
        self.session?.id == sessionID && self.session?.mayPause == true
    }

    private func pause(sessionID: Int) async {
        guard self.now() >= self.suspendedUntil else {
            self.log("pause_suppressed session=\(sessionID) reason=player_backoff")
            return
        }
        guard let before = await self.queryBeforePause(sessionID: sessionID) else { return }
        guard self.canPause(sessionID) else {
            self.log("pause_skipped session=\(sessionID) reason=stale_recording")
            return
        }
        if let owned = self.pausedTarget, owned.matches(before), before.isPlaying == false {
            self.log("pause_retained session=\(sessionID) reason=already_owned")
            return
        }
        // A player change or manual playback invalidates our previous ownership.
        self.pausedTarget = nil
        guard before.isPlaying == true else {
            self.log("pause_skipped session=\(sessionID) reason=not_known_playing")
            return
        }
        let result = await self.transport.send(.pause)
        self.logCommand(.pause, result: result, sessionID: sessionID)
        // Even a timed-out helper might have sent its command before exiting.
        // Observe state before deciding whether we own a pause to restore.
        if let paused = await self.verify(target: before, playing: false, context: "pause session=\(sessionID)") {
            self.pausedTarget = paused
            self.log("pause_verified session=\(sessionID)")
        } else {
            self.backOff(context: "pause session=\(sessionID)")
        }
    }

    private func queryBeforePause(sessionID: Int) async -> MediaPlaybackSnapshot? {
        for attempt in 1...3 {
            guard self.canPause(sessionID) else { return nil }
            if let snapshot = await self.query(context: "before_pause session=\(sessionID) attempt=\(attempt)") {
                return snapshot
            }
            guard self.canPause(sessionID) else { return nil }
            if attempt < 3 { await self.settle() }
        }
        return nil
    }

    private func resume(target: MediaPlaybackSnapshot) async {
        // Retry a command only after fresh metadata confirms the same paused item.
        // Retain ownership while a new recording may inherit the pause.
        for attempt in 1...2 {
            guard let before = await self.queryBeforeResume() else {
                guard self.session == nil else { return }
                // Missing metadata is not evidence that our confirmed pause ended.
                // Allow one more bounded read cycle; never issue Play without a
                // matching paused item. Keep ownership for the next session/quit
                // event if the outage outlasts this recovery window.
                if !self.isShuttingDown, attempt < 2 {
                    await self.settle()
                    continue
                }
                self.log("resume_deferred reason=unknown_player ownership=retained")
                return
            }
            guard self.session == nil else {
                self.log("resume_skipped reason=new_recording")
                return
            }
            guard target.matches(before), before.isPlaying == false else {
                self.pausedTarget = nil
                self.log("resume_skipped reason=player_item_or_state_changed")
                return
            }
            let result = await self.transport.send(.play)
            self.logCommand(.play, result: result, sessionID: nil)
            if await self.verify(target: before, playing: true, context: "resume") != nil {
                self.pausedTarget = nil
                self.log("resume_verified")
                return
            }
            guard self.session == nil else { return }
            // Quit is best-effort within the app's overall termination deadline.
            // Do not add another command cycle while shutdown is in progress.
            if self.isShuttingDown || attempt == 2 {
                self.pausedTarget = nil
                self.backOff(context: "resume")
                return
            }
        }
    }

    private func queryBeforeResume() async -> MediaPlaybackSnapshot? {
        // Retain confirmed ownership across brief metadata outages. Retry reads,
        // never playback commands; give up after three bounded helper calls.
        for attempt in 1...3 {
            guard self.session == nil else { return nil }
            if let snapshot = await self.query(context: "before_resume attempt=\(attempt)") {
                return snapshot
            }
            guard self.session == nil else { return nil }
            if self.isShuttingDown { return nil }
            if attempt < 3 { await self.settle() }
        }
        return nil
    }

    private func verify(
        target: MediaPlaybackSnapshot, playing: Bool, context: String
    ) async -> MediaPlaybackSnapshot? {
        // Read at most twice; never retry a playback command blindly. This checks
        // reported state, not rendered video: Netflix can disagree with its UI.
        for attempt in 1...2 {
            if attempt > 1, self.isShuttingDown { break }
            await self.settle()
            guard let observed = await self.query(context: "verify_\(context) attempt=\(attempt)") else {
                continue
            }
            guard target.matches(observed) else {
                self.log("verification_failed context=\(context) reason=player_or_item_changed")
                return nil
            }
            if observed.isPlaying == playing { return observed }
        }
        self.log("verification_failed context=\(context) reason=state_not_confirmed")
        return nil
    }

    private func query(context: String) async -> MediaPlaybackSnapshot? {
        let started = self.now()
        let result = await self.transport.query()
        let elapsed = Int((self.now() - started) * 1000)
        switch result {
        case let .snapshot(snapshot):
            self.log(
                "query context=\(context) elapsedMs=\(elapsed) " +
                    "bundle=\(snapshot.bundleIdentifier) pid=\(snapshot.processID) " +
                    "playing=\(snapshot.isPlaying.map(String.init) ?? "unknown") " +
                    "hasTitle=\(snapshot.title != nil)"
            )
            return snapshot
        case let .unavailable(reason):
            self.log("query_unavailable context=\(context) elapsedMs=\(elapsed) reason=\(reason)")
            return nil
        }
    }

    private func backOff(context: String) {
        // A finite cooldown limits damage from hotkey spam against an unresponsive
        // player. The next recording after the cooldown performs a fresh query.
        self.suspendedUntil = self.now() + 10
        self.log("commands_suspended context=\(context) seconds=10")
    }

    private func logCommand(
        _ command: MediaPlaybackCommand, result: MediaPlaybackCommandResult, sessionID: Int?
    ) {
        let status: String
        switch result {
        case .helperCompleted: status = "helper_completed_player_unconfirmed"
        case let .failed(reason): status = "failed:\(reason)"
        }
        self.log("command=\(command.rawValue) session=\(sessionID.map(String.init) ?? "none") result=\(status)")
    }

    private func log(_ message: String) {
        DebugLogger.shared.info("MEDIA_CONTROL \(message)", source: "MediaPlaybackService")
    }
}
