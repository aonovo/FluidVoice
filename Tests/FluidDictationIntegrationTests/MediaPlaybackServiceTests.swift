import CoreAudio
@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class MediaPlaybackServiceTests: XCTestCase {
    func testVerifiedPauseAndResumeAreOrdered() async {
        let transport = FakeMediaPlaybackTransport([self.state(true), self.state(false), self.state(false), self.state(true)])
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await service.waitUntilSettled()
        service.recordingStopped(sessionID: 1)
        service.sessionFinished(sessionID: 1)
        await service.waitUntilSettled()
        let commands = await transport.commands
        let maxInFlight = await transport.maximumInFlight
        XCTAssertEqual(commands, [.pause, .play])
        XCTAssertEqual(maxInFlight, 1)
    }

    func testUnavailableOrPausedMediaNeverStartsPlayback() async {
        for result in [MediaPlaybackQueryResult.unavailable("no_media"), self.state(false), self.state(nil)] {
            let transport = FakeMediaPlaybackTransport([result])
            let service = self.service(transport)
            service.recordingStarted(sessionID: 1, enabled: true)
            await service.waitUntilSettled()
            service.sessionFinished(sessionID: 1)
            await service.waitUntilSettled()
            let commands = await transport.commands
            XCTAssertTrue(commands.isEmpty)
        }
    }

    func testInitialQueryRetriesTransientFailure() async {
        let transport = FakeMediaPlaybackTransport([
            .unavailable("temporary"), self.state(true), self.state(false),
        ])
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await service.waitUntilSettled()
        let commands = await transport.commands
        XCTAssertEqual(commands, [.pause])
    }

    func testInitialQueryRetriesAreBounded() async {
        let transport = FakeMediaPlaybackTransport([
            .unavailable("temporary"), .unavailable("temporary"), .unavailable("temporary"),
        ])
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await service.waitUntilSettled()
        let commands = await transport.commands
        let count = await transport.queryCount
        XCTAssertTrue(commands.isEmpty)
        XCTAssertEqual(count, 3)
    }

    func testReleasedRecordingDoesNotRetryUnavailableInitialQuery() async {
        let transport = FakeMediaPlaybackTransport([])
        await transport.holdQuery(1)
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await transport.waitForQuery(1)
        service.recordingStopped(sessionID: 1)
        await transport.releaseQuery(.unavailable("temporary"))
        await service.waitUntilSettled()
        let commands = await transport.commands
        let count = await transport.queryCount
        XCTAssertTrue(commands.isEmpty)
        XCTAssertEqual(count, 1)
    }

    func testDisabledSettingDoesNoMediaIO() async {
        let transport = FakeMediaPlaybackTransport([])
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: false)
        await service.waitUntilSettled()
        let count = await transport.queryCount
        XCTAssertEqual(count, 0)
    }

    func testStopDuringQueryPreventsLatePause() async {
        let transport = FakeMediaPlaybackTransport([])
        await transport.holdQuery(1)
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await transport.waitForQuery(1)
        service.recordingStopped(sessionID: 1)
        await transport.releaseQuery(self.state(true))
        await service.waitUntilSettled()
        let commands = await transport.commands
        XCTAssertTrue(commands.isEmpty)
        service.sessionFinished(sessionID: 1)
        await service.waitUntilSettled()
    }

    func testFailedStartDuringQueryNeverPauses() async {
        let transport = FakeMediaPlaybackTransport([])
        await transport.holdQuery(1)
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await transport.waitForQuery(1)
        service.sessionFinished(sessionID: 1)
        await transport.releaseQuery(self.state(true))
        await service.waitUntilSettled()
        let commands = await transport.commands
        XCTAssertTrue(commands.isEmpty)
    }

    func testFailedStartDuringPauseRestoresPlaybackOnce() async {
        let transport = FakeMediaPlaybackTransport([self.state(true), self.state(false), self.state(false), self.state(true)])
        await transport.holdCommand(1)
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await transport.waitForCommand(1)
        service.sessionFinished(sessionID: 1)
        service.sessionFinished(sessionID: 1)
        await transport.releaseCommand(.helperCompleted)
        await service.waitUntilSettled()
        let commands = await transport.commands
        let maxInFlight = await transport.maximumInFlight
        XCTAssertEqual(commands, [.pause, .play])
        XCTAssertEqual(maxInFlight, 1)
    }

    func testNewRecordingSupersedesPendingQueryAndOldFinish() async {
        let transport = FakeMediaPlaybackTransport([self.state(true), self.state(false)])
        await transport.holdQuery(1)
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await transport.waitForQuery(1)
        service.recordingStarted(sessionID: 2, enabled: true)
        service.sessionFinished(sessionID: 1)
        await transport.releaseQuery(self.state(true))
        await service.waitUntilSettled()
        let commands = await transport.commands
        let count = await transport.queryCount
        XCTAssertEqual(commands, [.pause])
        XCTAssertEqual(count, 3)
    }

    func testStopDuringPauseWaitsForConfirmationBeforeResume() async {
        let transport = FakeMediaPlaybackTransport([self.state(true), self.state(false), self.state(false), self.state(true)])
        await transport.holdCommand(1)
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await transport.waitForCommand(1)
        service.recordingStopped(sessionID: 1)
        service.sessionFinished(sessionID: 1)
        let pendingCommands = await transport.commands
        XCTAssertEqual(pendingCommands, [.pause])
        await transport.releaseCommand(.helperCompleted)
        await service.waitUntilSettled()
        let commands = await transport.commands
        let maxInFlight = await transport.maximumInFlight
        XCTAssertEqual(commands, [.pause, .play])
        XCTAssertEqual(maxInFlight, 1)
    }

    func testNewRecordingDuringResumeQueryRetainsPause() async {
        let transport = FakeMediaPlaybackTransport([
            self.state(true), self.state(false), self.state(false), self.state(false), self.state(true),
        ])
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await service.waitUntilSettled()
        await transport.holdQuery(3)
        service.sessionFinished(sessionID: 1)
        await transport.waitForQuery(3)
        service.recordingStarted(sessionID: 2, enabled: true)
        await transport.releaseQuery(self.state(false))
        await service.waitUntilSettled()
        let beforeFinish = await transport.commands
        XCTAssertEqual(beforeFinish, [.pause])
        service.sessionFinished(sessionID: 1)
        service.sessionFinished(sessionID: 2)
        await service.waitUntilSettled()
        let commands = await transport.commands
        XCTAssertEqual(commands, [.pause, .play])
    }

    func testFailedPlayRetriesOnlyAfterConfirmingSamePausedPlayer() async {
        let transport = FakeMediaPlaybackTransport([
            self.state(true), self.state(false), self.state(false), self.state(false), self.state(false),
            self.state(false), self.state(true),
        ])
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await service.waitUntilSettled()
        service.sessionFinished(sessionID: 1)
        await service.waitUntilSettled()
        let commands = await transport.commands
        XCTAssertEqual(commands, [.pause, .play, .play])
    }

    func testFailedPlayDoesNotRetryForChangedPlayer() async {
        let transport = FakeMediaPlaybackTransport([
            self.state(true), self.state(false), self.state(false), self.state(false), self.state(false),
            self.state(false, pid: 2),
        ])
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await service.waitUntilSettled()
        service.sessionFinished(sessionID: 1)
        await service.waitUntilSettled()
        let commands = await transport.commands
        XCTAssertEqual(commands, [.pause, .play])
    }

    func testFailedPlayRetryIsBounded() async {
        let transport = FakeMediaPlaybackTransport([
            self.state(true), self.state(false), self.state(false), self.state(false), self.state(false),
            self.state(false), self.state(false), self.state(false),
        ])
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await service.waitUntilSettled()
        service.sessionFinished(sessionID: 1)
        await service.waitUntilSettled()
        let commands = await transport.commands
        XCTAssertEqual(commands, [.pause, .play, .play])
    }

    func testShutdownDuringPauseUsesOneVerificationPerCommand() async {
        let transport = FakeMediaPlaybackTransport([
            self.state(true), self.state(false), self.state(false), self.state(false),
        ])
        await transport.holdCommand(1)
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await transport.waitForCommand(1)
        service.beginShutdown()
        service.beginShutdown()
        service.recordingStarted(sessionID: 2, enabled: true)
        await transport.releaseCommand(.helperCompleted)
        await service.shutdown()
        let commands = await transport.commands
        let count = await transport.queryCount
        XCTAssertEqual(commands, [.pause, .play])
        XCTAssertEqual(count, 4)
    }

    func testNewRecordingDuringFailedPlayRetainsPause() async {
        let transport = FakeMediaPlaybackTransport([
            self.state(true), self.state(false), self.state(false), self.state(false), self.state(false),
            self.state(false), self.state(false), self.state(true),
        ])
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await service.waitUntilSettled()
        await transport.holdCommand(2)
        service.sessionFinished(sessionID: 1)
        await transport.waitForCommand(2)
        service.recordingStarted(sessionID: 2, enabled: true)
        await transport.releaseCommand(.failed("timeout"))
        await service.waitUntilSettled()
        let beforeFinish = await transport.commands
        XCTAssertEqual(beforeFinish, [.pause, .play])
        service.sessionFinished(sessionID: 2)
        await service.waitUntilSettled()
        let commands = await transport.commands
        XCTAssertEqual(commands, [.pause, .play, .play])
    }

    func testShutdownDoesNotRetryUnavailableQuery() async {
        let transport = FakeMediaPlaybackTransport([
            self.state(true), self.state(false), .unavailable("temporary"),
        ])
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await service.waitUntilSettled()
        await service.shutdown()
        let commands = await transport.commands
        let count = await transport.queryCount
        XCTAssertEqual(commands, [.pause])
        XCTAssertEqual(count, 3)
    }

    func testTransientResumeQueryFailureRetriesBeforePlaying() async {
        let transport = FakeMediaPlaybackTransport([
            self.state(true), self.state(false), .unavailable("temporary"), self.state(false), self.state(true),
        ])
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await service.waitUntilSettled()
        service.sessionFinished(sessionID: 1)
        await service.waitUntilSettled()
        let commands = await transport.commands
        XCTAssertEqual(commands, [.pause, .play])
    }

    func testResumeQueryFailureStopsAfterBoundedRetries() async {
        let transport = FakeMediaPlaybackTransport([
            self.state(true), self.state(false), .unavailable("temporary"),
            .unavailable("temporary"), .unavailable("temporary"),
        ])
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await service.waitUntilSettled()
        service.sessionFinished(sessionID: 1)
        await service.waitUntilSettled()
        let commands = await transport.commands
        let count = await transport.queryCount
        XCTAssertEqual(commands, [.pause])
        XCTAssertEqual(count, 8)
    }

    func testResumeRecoversAfterFirstReadCycleIsUnavailable() async {
        let transport = FakeMediaPlaybackTransport([
            self.state(true), self.state(false),
            .unavailable("temporary"), .unavailable("temporary"), .unavailable("temporary"),
            self.state(false), self.state(true),
        ])
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await service.waitUntilSettled()
        service.sessionFinished(sessionID: 1)
        await service.waitUntilSettled()
        let commands = await transport.commands
        XCTAssertEqual(commands, [.pause, .play])
    }

    func testExhaustedResumeReadsRetainPauseForNextSession() async {
        let transport = FakeMediaPlaybackTransport(
            [self.state(true), self.state(false)]
                + Array(repeating: .unavailable("temporary"), count: 6)
                + [self.state(false), self.state(false), self.state(true)]
        )
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await service.waitUntilSettled()
        service.sessionFinished(sessionID: 1)
        await service.waitUntilSettled()
        let before = await transport.commands
        XCTAssertEqual(before, [.pause], "Unavailable metadata must never trigger blind Play")
        service.recordingStarted(sessionID: 2, enabled: true)
        await service.waitUntilSettled()
        service.sessionFinished(sessionID: 2)
        await service.waitUntilSettled()
        let commands = await transport.commands
        XCTAssertEqual(commands, [.pause, .play], "The original confirmed pause must survive the outage")
    }

    func testResumeRetryDoesNotPlayChangedItem() async {
        let transport = FakeMediaPlaybackTransport([
            self.state(true), self.state(false), .unavailable("temporary"), self.state(false, title: "Other"),
        ])
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await service.waitUntilSettled()
        service.sessionFinished(sessionID: 1)
        await service.waitUntilSettled()
        let commands = await transport.commands
        XCTAssertEqual(commands, [.pause])
    }

    func testNewRecordingDuringUnavailableResumeQueryRetainsPause() async {
        let transport = FakeMediaPlaybackTransport([
            self.state(true), self.state(false), self.state(false), self.state(false), self.state(true),
        ])
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await service.waitUntilSettled()
        await transport.holdQuery(3)
        service.sessionFinished(sessionID: 1)
        await transport.waitForQuery(3)
        service.recordingStarted(sessionID: 2, enabled: true)
        await transport.releaseQuery(.unavailable("temporary"))
        await service.waitUntilSettled()
        let beforeFinish = await transport.commands
        XCTAssertEqual(beforeFinish, [.pause])
        service.sessionFinished(sessionID: 2)
        await service.waitUntilSettled()
        let commands = await transport.commands
        XCTAssertEqual(commands, [.pause, .play])
    }

    func testUnconfirmedPauseDoesNotResumeOrSpamCommands() async {
        let transport = FakeMediaPlaybackTransport([self.state(true), self.state(true), self.state(true)])
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await service.waitUntilSettled()
        service.sessionFinished(sessionID: 1)
        for id in 2...10 {
            service.recordingStarted(sessionID: id, enabled: true)
            await service.waitUntilSettled()
            service.sessionFinished(sessionID: id)
        }
        await service.waitUntilSettled()
        let commands = await transport.commands
        let count = await transport.queryCount
        XCTAssertEqual(commands, [.pause])
        XCTAssertEqual(count, 3)
    }

    func testNewRecordingDuringPlayWaitsBeforePausingAgain() async {
        let transport = FakeMediaPlaybackTransport([
            self.state(true), self.state(false), self.state(false), self.state(true), self.state(true), self.state(false),
        ])
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await service.waitUntilSettled()
        await transport.holdCommand(2)
        service.sessionFinished(sessionID: 1)
        await transport.waitForCommand(2)
        service.recordingStarted(sessionID: 2, enabled: true)
        service.sessionFinished(sessionID: 1)
        await transport.releaseCommand(.helperCompleted)
        await service.waitUntilSettled()
        let commands = await transport.commands
        let maxInFlight = await transport.maximumInFlight
        XCTAssertEqual(commands, [.pause, .play, .pause])
        XCTAssertEqual(maxInFlight, 1)
    }

    func testPauseRemainsOwnedUntilTranscriptionFinishes() async {
        let transport = FakeMediaPlaybackTransport([self.state(true), self.state(false), self.state(false), self.state(true)])
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await service.waitUntilSettled()
        service.recordingStopped(sessionID: 1)
        await service.waitUntilSettled()
        let beforeFinish = await transport.commands
        XCTAssertEqual(beforeFinish, [.pause])
        service.sessionFinished(sessionID: 1)
        await service.waitUntilSettled()
        let commands = await transport.commands
        XCTAssertEqual(commands, [.pause, .play])
    }

    func testCooldownHasBoundedExit() async {
        let transport = FakeMediaPlaybackTransport([
            self.state(true), self.state(true), self.state(true), self.state(true), self.state(false),
        ])
        let clock = MediaTestClock()
        let service = MediaPlaybackService(transport: transport, settle: {}, now: { clock.value })
        service.recordingStarted(sessionID: 1, enabled: true)
        await service.waitUntilSettled()
        clock.advance(11)
        service.recordingStarted(sessionID: 2, enabled: true)
        await service.waitUntilSettled()
        let commands = await transport.commands
        XCTAssertEqual(commands, [.pause, .pause])
    }

    func testChangedPlayerOrItemAndManualPlayAreNotResumed() async {
        for changed in [self.state(false, pid: 2), self.state(false, title: "Other"), self.state(true)] {
            let transport = FakeMediaPlaybackTransport([self.state(true), self.state(false), changed])
            let service = self.service(transport)
            service.recordingStarted(sessionID: 1, enabled: true)
            await service.waitUntilSettled()
            service.sessionFinished(sessionID: 1)
            await service.waitUntilSettled()
            let commands = await transport.commands
            XCTAssertEqual(commands, [.pause])
        }
    }

    func testUnknownVerificationNeverClaimsOwnership() async {
        let transport = FakeMediaPlaybackTransport([
            self.state(true), .unavailable("timeout"), .unavailable("empty_output"),
        ])
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await service.waitUntilSettled()
        service.sessionFinished(sessionID: 1)
        await service.waitUntilSettled()
        let commands = await transport.commands
        XCTAssertEqual(commands, [.pause])
    }

    func testCommandTimeoutStillChecksForAppliedPause() async {
        let transport = FakeMediaPlaybackTransport([self.state(true), self.state(false), self.state(false), self.state(true)])
        await transport.holdCommand(1)
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await transport.waitForCommand(1)
        await transport.releaseCommand(.failed("helper_timeout"))
        await service.waitUntilSettled()
        service.sessionFinished(sessionID: 1)
        await service.waitUntilSettled()
        let commands = await transport.commands
        XCTAssertEqual(commands, [.pause, .play])
    }

    func testShutdownRestoresConfirmedPauseAndRejectsNewStarts() async {
        let transport = FakeMediaPlaybackTransport([self.state(true), self.state(false), self.state(false), self.state(true)])
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await service.waitUntilSettled()
        await service.shutdown()
        service.recordingStarted(sessionID: 2, enabled: true)
        await service.waitUntilSettled()
        let commands = await transport.commands
        XCTAssertEqual(commands, [.pause, .play])
    }

    func testRawQueryFailuresAreDistinct() {
        for (text, reason) in [("", "empty_output"), ("NIL\n", "no_media_reported"), ("{", "invalid_payload")] {
            guard case let .unavailable(actual) = MediaPlaybackProcessTransport.decode(Data(text.utf8)) else {
                return XCTFail("Expected unavailable: \(reason)")
            }
            XCTAssertEqual(actual, reason)
        }
    }

    func testRawQueryAcceptsMissingTitleAndDoesNotOverrideExplicitPause() {
        let text = #"{"payload":{"PID":"42","bundleIdentifier":"com.apple.WebKit.GPU","isPlaying":false,"playbackRate":1}}"#
        guard case let .snapshot(snapshot) = MediaPlaybackProcessTransport.decode(Data(text.utf8)) else {
            return XCTFail("Expected player state")
        }
        XCTAssertEqual(snapshot.processID, 42)
        XCTAssertNil(snapshot.title)
        XCTAssertEqual(snapshot.isPlaying, false)
    }

    func testProcessDrainsBothPipesBeforeCompletion() async {
        let result = await Task.detached {
            MediaHelperProcess.run(arguments: ["-e", "print 'x' x 200000; print STDERR 'y' x 200000;"])
        }.value
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.output.count, 200_000)
    }

    func testDefaultProcessTimeoutIsOneSecond() async {
        let started = ProcessInfo.processInfo.systemUptime
        let result = await Task.detached {
            MediaHelperProcess.run(arguments: ["-e", "sleep 10"])
        }.value
        XCTAssertEqual(result.failure, "helper_timeout")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2.0)
    }

    func testQueryTimeoutHonorsAdapterDeadlineWithoutExtendingCommands() {
        XCTAssertEqual(MediaPlaybackProcessTransport.queryTimeoutSeconds, 2.5)
        XCTAssertEqual(MediaPlaybackProcessTransport.commandTimeoutSeconds, 1.0)
    }

    func testProcessTimeoutTerminatesHelper() async {
        let result = await Task.detached {
            MediaHelperProcess.run(arguments: ["-e", "sleep 10;"], timeout: 0.1)
        }.value
        XCTAssertEqual(result.failure, "helper_timeout")
    }

    func testProcessOutputIsBounded() async {
        let result = await Task.detached {
            MediaHelperProcess.run(arguments: ["-e", "print 'x' x 5000000;"])
        }.value
        XCTAssertEqual(result.failure, "output_limit")
        XCTAssertTrue(result.output.isEmpty)
    }

    // MARK: - Ducking

    func testDuckFadesOutputVolumeWithoutMediaCommandsAndRestoresOnStop() async {
        let transport = FakeMediaPlaybackTransport([self.state(true)])
        let volume = FakeSystemAudioVolumeController(current: self.levels([0.8, 0.4]))
        let service = self.service(transport, volume: volume)
        service.recordingStarted(sessionID: 1, suppression: .duck(level: 0.25))
        await service.waitUntilSettled()
        XCTAssertEqual(volume.captureCount, 1)
        self.assertLevels(volume.current, [0.2, 0.1])
        XCTAssertEqual(volume.applied.count, MediaPlaybackService.duckRampSteps)
        let queries = await transport.queryCount
        XCTAssertEqual(queries, 0)

        service.recordingStopped(sessionID: 1)
        await service.waitUntilSettled()
        self.assertLevels(volume.current, [0.8, 0.4])
        XCTAssertEqual(volume.applied.count, 2 * MediaPlaybackService.duckRampSteps)

        service.sessionFinished(sessionID: 1)
        await service.waitUntilSettled()
        XCTAssertEqual(volume.applied.count, 2 * MediaPlaybackService.duckRampSteps)
        let commands = await transport.commands
        XCTAssertTrue(commands.isEmpty)
    }

    func testDuckFadeMovesMonotonicallyTowardTarget() async {
        let volume = FakeSystemAudioVolumeController(current: self.levels([1.0]))
        let service = self.service(FakeMediaPlaybackTransport([]), volume: volume)
        service.recordingStarted(sessionID: 1, suppression: .duck(level: 0.2))
        await service.waitUntilSettled()
        let written = volume.applied.map { $0.channels[0].volume }
        XCTAssertEqual(written.last ?? -1, 0.2, accuracy: 0.0001)
        XCTAssertEqual(written, written.sorted(by: >))
        XCTAssertEqual(Set(written).count, written.count)
    }

    func testDuckLeavesUserAdjustedVolumeAlone() async {
        let volume = FakeSystemAudioVolumeController(current: self.levels([0.8, 0.4]))
        let service = self.service(FakeMediaPlaybackTransport([]), volume: volume)
        service.recordingStarted(sessionID: 1, suppression: .duck(level: 0.25))
        await service.waitUntilSettled()
        let writesAfterDuck = volume.applied.count

        volume.current = self.levels([0.6, 0.3])
        service.recordingStopped(sessionID: 1)
        service.sessionFinished(sessionID: 1)
        await service.waitUntilSettled()
        self.assertLevels(volume.current, [0.6, 0.3])
        XCTAssertEqual(volume.applied.count, writesAfterDuck)
    }

    func testDuckRespectsUserMute() async {
        let volume = FakeSystemAudioVolumeController(current: self.levels([0.8, 0.4]))
        let service = self.service(FakeMediaPlaybackTransport([]), volume: volume)
        service.recordingStarted(sessionID: 1, suppression: .duck(level: 0.25))
        await service.waitUntilSettled()
        let writesAfterDuck = volume.applied.count

        volume.current = self.levels([0, 0])
        service.recordingStopped(sessionID: 1)
        await service.waitUntilSettled()
        self.assertLevels(volume.current, [0, 0])
        XCTAssertEqual(volume.applied.count, writesAfterDuck)
    }

    func testDuckFallsBackToPauseWhenOutputVolumeIsUnavailable() async {
        let transport = FakeMediaPlaybackTransport([self.state(true), self.state(false), self.state(false), self.state(true)])
        let volume = FakeSystemAudioVolumeController(current: nil)
        let service = self.service(transport, volume: volume)
        service.recordingStarted(sessionID: 1, suppression: .duck(level: 0.25))
        await service.waitUntilSettled()
        service.recordingStopped(sessionID: 1)
        service.sessionFinished(sessionID: 1)
        await service.waitUntilSettled()
        let commands = await transport.commands
        XCTAssertEqual(commands, [.pause, .play])
        XCTAssertTrue(volume.applied.isEmpty)
    }

    func testFailedDuckIsUndoneAndFallsBackToPause() async {
        let transport = FakeMediaPlaybackTransport([self.state(true), self.state(false)])
        let volume = FakeSystemAudioVolumeController(current: self.levels([0.8, 0.4]))
        volume.applyOutcomes = Array(repeating: .failed, count: MediaPlaybackService.duckRampSteps)
        let service = self.service(transport, volume: volume)
        service.recordingStarted(sessionID: 1, suppression: .duck(level: 0.25))
        await service.waitUntilSettled()
        self.assertLevels(volume.current, [0.8, 0.4])
        let commands = await transport.commands
        XCTAssertEqual(commands, [.pause])
        let writesAfterFallback = volume.applied.count

        service.recordingStopped(sessionID: 1)
        await service.waitUntilSettled()
        XCTAssertEqual(volume.applied.count, writesAfterFallback)
    }

    func testSecondRecordingDuringUnrestoredDuckKeepsOriginalVolume() async {
        let volume = FakeSystemAudioVolumeController(current: self.levels([0.8, 0.4]))
        let service = self.service(FakeMediaPlaybackTransport([]), volume: volume)
        service.recordingStarted(sessionID: 1, suppression: .duck(level: 0.25))
        await service.waitUntilSettled()
        service.recordingStarted(sessionID: 2, suppression: .duck(level: 0.25))
        await service.waitUntilSettled()
        XCTAssertEqual(volume.captureCount, 1)
        self.assertLevels(volume.current, [0.2, 0.1])

        service.recordingStopped(sessionID: 2)
        await service.waitUntilSettled()
        self.assertLevels(volume.current, [0.8, 0.4])
    }

    func testSessionFinishedWithoutStopRestoresDuck() async {
        let volume = FakeSystemAudioVolumeController(current: self.levels([0.8, 0.4]))
        let service = self.service(FakeMediaPlaybackTransport([]), volume: volume)
        service.recordingStarted(sessionID: 1, suppression: .duck(level: 0.25))
        await service.waitUntilSettled()
        service.sessionFinished(sessionID: 1)
        await service.waitUntilSettled()
        self.assertLevels(volume.current, [0.8, 0.4])
    }

    func testShutdownRestoresDuckedVolumeAndRejectsNewStarts() async {
        let volume = FakeSystemAudioVolumeController(current: self.levels([0.8, 0.4]))
        let service = self.service(FakeMediaPlaybackTransport([]), volume: volume)
        service.recordingStarted(sessionID: 1, suppression: .duck(level: 0.25))
        await service.waitUntilSettled()
        await service.shutdown()
        self.assertLevels(volume.current, [0.8, 0.4])
        service.recordingStarted(sessionID: 2, suppression: .duck(level: 0.25))
        await service.waitUntilSettled()
        XCTAssertEqual(volume.captureCount, 1)
    }

    func testDisabledSuppressionDoesNotTouchVolume() async {
        let transport = FakeMediaPlaybackTransport([self.state(true)])
        let volume = FakeSystemAudioVolumeController(current: self.levels([0.8, 0.4]))
        let service = self.service(transport, volume: volume)
        service.recordingStarted(sessionID: 1, suppression: .none)
        await service.waitUntilSettled()
        service.recordingStopped(sessionID: 1)
        service.sessionFinished(sessionID: 1)
        await service.waitUntilSettled()
        XCTAssertEqual(volume.captureCount, 0)
        let queries = await transport.queryCount
        XCTAssertEqual(queries, 0)
    }

    func testLegacyEnabledFlagStillPauses() async {
        let transport = FakeMediaPlaybackTransport([self.state(true), self.state(false)])
        let volume = FakeSystemAudioVolumeController(current: self.levels([0.8, 0.4]))
        let service = self.service(transport, volume: volume)
        service.recordingStarted(sessionID: 1, enabled: true)
        await service.waitUntilSettled()
        let commands = await transport.commands
        XCTAssertEqual(commands, [.pause])
        XCTAssertEqual(volume.captureCount, 0)
    }

    private func service(
        _ transport: FakeMediaPlaybackTransport,
        volume: FakeSystemAudioVolumeController
    ) -> MediaPlaybackService {
        MediaPlaybackService(transport: transport, volumeController: volume, settle: {}, rampStep: {}, now: { 0 })
    }

    private func levels(_ volumes: [Float]) -> OutputVolumeSnapshot {
        OutputVolumeSnapshot(
            deviceID: 42,
            channels: volumes.enumerated().map { index, volume in
                .init(
                    selector: kAudioDevicePropertyVolumeScalar,
                    element: AudioObjectPropertyElement(index + 1),
                    volume: volume
                )
            }
        )
    }

    private func assertLevels(
        _ snapshot: OutputVolumeSnapshot?,
        _ expected: [Float],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = snapshot?.channels.map(\.volume) ?? []
        XCTAssertEqual(actual.count, expected.count, "channel count", file: file, line: line)
        for (value, target) in zip(actual, expected) {
            XCTAssertEqual(value, target, accuracy: 0.0001, file: file, line: line)
        }
    }

    private func service(_ transport: FakeMediaPlaybackTransport) -> MediaPlaybackService {
        MediaPlaybackService(transport: transport, settle: {}, now: { 0 })
    }

    private func state(_ playing: Bool?, pid: Int32 = 1, title: String = "Netflix") -> MediaPlaybackQueryResult {
        .snapshot(MediaPlaybackSnapshot(bundleIdentifier: "com.apple.WebKit.GPU", processID: pid, title: title, isPlaying: playing))
    }
}

private actor FakeMediaPlaybackTransport: MediaPlaybackTransport {
    private var results: [MediaPlaybackQueryResult]
    private var heldQueryIndex: Int?
    private var heldCommandIndex: Int?
    private var queryContinuation: CheckedContinuation<MediaPlaybackQueryResult, Never>?
    private var commandContinuation: CheckedContinuation<MediaPlaybackCommandResult, Never>?
    private var queryWaiter: (Int, CheckedContinuation<Void, Never>)?
    private var commandWaiter: (Int, CheckedContinuation<Void, Never>)?
    private var inFlight = 0
    private(set) var maximumInFlight = 0
    private(set) var queryCount = 0
    private(set) var commands: [MediaPlaybackCommand] = []

    init(_ results: [MediaPlaybackQueryResult]) { self.results = results }

    func query() async -> MediaPlaybackQueryResult {
        self.inFlight += 1
        self.maximumInFlight = max(self.maximumInFlight, self.inFlight)
        defer { self.inFlight -= 1 }
        self.queryCount += 1
        if let (count, continuation) = self.queryWaiter, self.queryCount >= count {
            self.queryWaiter = nil
            continuation.resume()
        }
        if self.queryCount == self.heldQueryIndex {
            return await withCheckedContinuation { self.queryContinuation = $0 }
        }
        return self.results.isEmpty ? .unavailable("exhausted") : self.results.removeFirst()
    }

    func send(_ command: MediaPlaybackCommand) async -> MediaPlaybackCommandResult {
        self.inFlight += 1
        self.maximumInFlight = max(self.maximumInFlight, self.inFlight)
        defer { self.inFlight -= 1 }
        self.commands.append(command)
        if let (count, continuation) = self.commandWaiter, self.commands.count >= count {
            self.commandWaiter = nil
            continuation.resume()
        }
        if self.commands.count == self.heldCommandIndex {
            return await withCheckedContinuation { self.commandContinuation = $0 }
        }
        return .helperCompleted
    }

    func holdQuery(_ index: Int) { self.heldQueryIndex = index }
    func holdCommand(_ index: Int) { self.heldCommandIndex = index }
    func releaseQuery(_ result: MediaPlaybackQueryResult) {
        self.queryContinuation?.resume(returning: result)
        self.queryContinuation = nil
    }

    func releaseCommand(_ result: MediaPlaybackCommandResult) {
        self.commandContinuation?.resume(returning: result)
        self.commandContinuation = nil
    }

    func waitForQuery(_ count: Int) async {
        guard self.queryCount < count else { return }
        await withCheckedContinuation { self.queryWaiter = (count, $0) }
    }

    func waitForCommand(_ count: Int) async {
        guard self.commands.count < count else { return }
        await withCheckedContinuation { self.commandWaiter = (count, $0) }
    }
}

/// Simulates an output device: `current` is what capture and reread return, and every
/// successful apply moves it. Queue `applyOutcomes` to make writes fail.
private final nonisolated class FakeSystemAudioVolumeController: SystemAudioVolumeControlling {
    var current: OutputVolumeSnapshot?
    var applyOutcomes: [SystemAudioVolumeController.ApplyOutcome] = []
    private(set) var captureCount = 0
    private(set) var applied: [OutputVolumeSnapshot] = []
    private(set) var virtualMainLevels: [Float] = []

    init(current: OutputVolumeSnapshot?) {
        self.current = current
    }

    func captureOutputVolume() -> OutputVolumeSnapshot? {
        self.captureCount += 1
        return self.current
    }

    func apply(_ snapshot: OutputVolumeSnapshot) -> SystemAudioVolumeController.ApplyOutcome {
        self.applied.append(snapshot)
        let outcome = self.applyOutcomes.isEmpty ? .applied : self.applyOutcomes.removeFirst()
        if outcome == .applied {
            self.current = snapshot
        }
        return outcome
    }

    func applyVirtualMainVolume(_ snapshot: OutputVolumeSnapshot) -> Bool {
        self.virtualMainLevels.append(snapshot.averageLevel)
        self.current = snapshot
        return true
    }

    func reread(_ snapshot: OutputVolumeSnapshot) -> OutputVolumeSnapshot? {
        self.current
    }
}

private final nonisolated class MediaTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0

    var value: TimeInterval {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.time
    }

    func advance(_ seconds: TimeInterval) {
        self.lock.lock()
        self.time += seconds
        self.lock.unlock()
    }
}
