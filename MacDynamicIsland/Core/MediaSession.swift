import AppKit
import Foundation

enum MediaCommand: String, CaseIterable, Hashable, Sendable {
    case play
    case pause
    case togglePlayPause
    case previous
    case next
    case skipBackward
    case skipForward
}

enum MediaArtworkTransition {
    static func resolvedArtwork(
        exactArtwork: NSImage?,
        previousSnapshot: MediaSessionSnapshot,
        nextSourceBundleIdentifier: String?,
        hasPendingRemoteArtwork: Bool
    ) -> NSImage? {
        if let exactArtwork {
            return exactArtwork
        }
        guard hasPendingRemoteArtwork,
              previousSnapshot.sourceBundleIdentifier == nextSourceBundleIdentifier else {
            return nil
        }
        return previousSnapshot.artwork
    }
}

struct MediaSessionSnapshot {
    var identifier: String
    var title: String
    var artist: String
    var album: String
    var sourceName: String
    var sourceBundleIdentifier: String?
    var duration: TimeInterval?
    var elapsedTime: TimeInterval
    var playbackRate: Double
    var updatedAt: Date
    var artwork: NSImage?
    var sourceIcon: NSImage?
    var capabilities: Set<MediaCommand>

    var isPlaying: Bool { playbackRate > 0 }

    func estimatedElapsedTime(at date: Date = .now) -> TimeInterval {
        let advanced = isPlaying ? date.timeIntervalSince(updatedAt) * playbackRate : 0
        let estimate = elapsedTime + advanced
        guard let duration, duration > 0 else { return max(0, estimate) }
        return min(max(0, estimate), duration)
    }

    func applyingOptimisticPlaybackCommand(
        _ command: MediaCommand,
        at date: Date = .now
    ) -> MediaSessionSnapshot {
        var updated = self
        let elapsed = estimatedElapsedTime(at: date)

        switch command {
        case .play:
            updated.elapsedTime = elapsed
            updated.playbackRate = max(playbackRate, 1)
        case .pause:
            updated.elapsedTime = elapsed
            updated.playbackRate = 0
        case .togglePlayPause:
            updated.elapsedTime = elapsed
            updated.playbackRate = isPlaying ? 0 : max(playbackRate, 1)
        case .skipBackward:
            updated.elapsedTime = max(0, elapsed - 15)
        case .skipForward:
            updated.elapsedTime = min(duration ?? .greatestFiniteMagnitude, elapsed + 15)
        case .previous, .next:
            // Keep current metadata and artwork until the player reports the
            // destination track instead of inventing an intermediate state.
            return self
        }

        updated.updatedAt = date
        return updated
    }

    static let empty = MediaSessionSnapshot(
        identifier: "empty",
        title: "",
        artist: "",
        album: "",
        sourceName: "",
        sourceBundleIdentifier: nil,
        duration: nil,
        elapsedTime: 0,
        playbackRate: 0,
        updatedAt: .now,
        artwork: nil,
        sourceIcon: nil,
        capabilities: []
    )
}

@MainActor
protocol MediaSessionProviding: AnyObject {
    var snapshot: MediaSessionSnapshot { get }
    var onSnapshotChange: ((MediaSessionSnapshot) -> Void)? { get set }

    func start()
    func stop()
    func send(_ command: MediaCommand)
}
