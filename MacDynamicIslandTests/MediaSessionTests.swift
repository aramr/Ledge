import XCTest
@testable import Ledge

final class MediaSessionTests: XCTestCase {
    func testArtworkDownloadsRequireCredentialFreeHTTPSURLs() {
        XCTAssertTrue(
            SystemMediaSessionProvider.isAllowedRemoteArtworkURL(
                URL(string: "https://i.ytimg.com/vi/example/hqdefault.jpg")!
            )
        )
        XCTAssertFalse(
            SystemMediaSessionProvider.isAllowedRemoteArtworkURL(
                URL(string: "http://example.com/art.jpg")!
            )
        )
        XCTAssertFalse(
            SystemMediaSessionProvider.isAllowedRemoteArtworkURL(
                URL(string: "https://user:password@example.com/art.jpg")!
            )
        )
    }

    func testEstimatedElapsedTimeAdvancesWhilePlaying() {
        var snapshot = MediaSessionSnapshot.empty
        snapshot.elapsedTime = 10
        snapshot.duration = 60
        snapshot.playbackRate = 1
        snapshot.updatedAt = Date(timeIntervalSinceReferenceDate: 100)

        let value = snapshot.estimatedElapsedTime(at: Date(timeIntervalSinceReferenceDate: 105))

        XCTAssertEqual(value, 15, accuracy: 0.001)
    }

    func testEstimatedElapsedTimeDoesNotExceedDuration() {
        var snapshot = MediaSessionSnapshot.empty
        snapshot.elapsedTime = 58
        snapshot.duration = 60
        snapshot.playbackRate = 1
        snapshot.updatedAt = Date(timeIntervalSinceReferenceDate: 100)

        let value = snapshot.estimatedElapsedTime(at: Date(timeIntervalSinceReferenceDate: 110))

        XCTAssertEqual(value, 60, accuracy: 0.001)
    }

    func testOptimisticPauseFreezesElapsedTimeAndUpdatesStateImmediately() {
        var snapshot = MediaSessionSnapshot.empty
        snapshot.elapsedTime = 10
        snapshot.duration = 60
        snapshot.playbackRate = 1
        snapshot.updatedAt = Date(timeIntervalSinceReferenceDate: 100)

        let paused = snapshot.applyingOptimisticPlaybackCommand(
            .pause,
            at: Date(timeIntervalSinceReferenceDate: 105)
        )

        XCTAssertFalse(paused.isPlaying)
        XCTAssertEqual(paused.elapsedTime, 15, accuracy: 0.001)
        XCTAssertEqual(
            paused.estimatedElapsedTime(at: Date(timeIntervalSinceReferenceDate: 106)),
            15,
            accuracy: 0.001
        )
    }

    func testOptimisticPlayResumesFromPausedElapsedTime() {
        var snapshot = MediaSessionSnapshot.empty
        snapshot.elapsedTime = 15
        snapshot.duration = 60
        snapshot.playbackRate = 0
        snapshot.updatedAt = Date(timeIntervalSinceReferenceDate: 100)

        let playing = snapshot.applyingOptimisticPlaybackCommand(
            .play,
            at: Date(timeIntervalSinceReferenceDate: 105)
        )

        XCTAssertTrue(playing.isPlaying)
        XCTAssertEqual(
            playing.estimatedElapsedTime(at: Date(timeIntervalSinceReferenceDate: 106)),
            16,
            accuracy: 0.001
        )
    }

    func testPendingArtworkKeepsPreviousCoverUntilExactCoverArrives() {
        let previousArtwork = NSImage(size: CGSize(width: 16, height: 16))
        var previous = MediaSessionSnapshot.empty
        previous.sourceBundleIdentifier = "com.spotify.client"
        previous.artwork = previousArtwork

        let bridged = MediaArtworkTransition.resolvedArtwork(
            exactArtwork: nil,
            previousSnapshot: previous,
            nextSourceBundleIdentifier: "com.spotify.client",
            hasPendingRemoteArtwork: true
        )

        XCTAssertTrue(bridged === previousArtwork)
    }

    func testArtworkDoesNotLeakAcrossMediaSources() {
        let previousArtwork = NSImage(size: CGSize(width: 16, height: 16))
        var previous = MediaSessionSnapshot.empty
        previous.sourceBundleIdentifier = "com.spotify.client"
        previous.artwork = previousArtwork

        let bridged = MediaArtworkTransition.resolvedArtwork(
            exactArtwork: nil,
            previousSnapshot: previous,
            nextSourceBundleIdentifier: "com.apple.Safari",
            hasPendingRemoteArtwork: true
        )

        XCTAssertNil(bridged)
    }

    func testScriptSnapshotUsesPlayingStateWhenSpotifyOmitsPlaybackRate() throws {
        let data = Data(#"{"available":true,"isPlaying":true}"#.utf8)
        let response = try JSONDecoder().decode(ScriptMediaSnapshot.self, from: data)

        XCTAssertEqual(response.effectivePlaybackRate, 1)
    }

    func testScriptSnapshotPlayingStateOverridesStaleRate() throws {
        let data = Data(#"{"available":true,"isPlaying":false,"rate":1}"#.utf8)
        let response = try JSONDecoder().decode(ScriptMediaSnapshot.self, from: data)

        XCTAssertEqual(response.effectivePlaybackRate, 0)
    }

    func testScriptSnapshotMapsSupportedTransportCommands() throws {
        let data = Data(#"{"available":true,"supportedCommands":[0,1,2,4,17,18]}"#.utf8)
        let response = try JSONDecoder().decode(ScriptMediaSnapshot.self, from: data)

        XCTAssertEqual(
            response.capabilities,
            [.play, .pause, .togglePlayPause, .next, .skipForward, .skipBackward]
        )
        XCTAssertFalse(response.capabilities.contains(.previous))
    }

    func testAudioProcessMatcherIncludesSpotifyAndBrowserHelpers() {
        XCTAssertTrue(
            AudioProcessFamilyMatcher.matches(
                "com.spotify.client.helper",
                target: "com.spotify.client"
            )
        )
        XCTAssertTrue(
            AudioProcessFamilyMatcher.matches(
                "com.apple.WebKit.GPU",
                target: "com.apple.Safari"
            )
        )
        XCTAssertTrue(
            AudioProcessFamilyMatcher.matches(
                "com.google.Chrome.helper.renderer",
                target: "com.google.Chrome"
            )
        )
        XCTAssertFalse(
            AudioProcessFamilyMatcher.matches(
                "com.apple.Music",
                target: "com.spotify.client"
            )
        )
    }

    func testAudioBandAnalyzerReturnsSilenceForSilentSamples() {
        let levels = AudioBandAnalyzer.levels(
            for: Array(repeating: 0, count: 512),
            sampleRate: 48_000
        )

        XCTAssertEqual(levels, Array(repeating: 0, count: 5))
    }

    func testAudioBandAnalyzerRespondsToRealSignal() {
        let sampleRate = 48_000.0
        let samples = (0..<1_024).map { index in
            0.5 * sin(2 * Double.pi * 900 * Double(index) / sampleRate)
        }

        let levels = AudioBandAnalyzer.levels(for: samples, sampleRate: sampleRate)

        XCTAssertEqual(levels.count, 5)
        XCTAssertGreaterThan(levels[2], 0.5)
        XCTAssertGreaterThan(levels[2], levels[0])
    }
}
