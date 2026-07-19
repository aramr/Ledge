import AppKit
import Foundation

@MainActor
final class PreviewMediaSessionProvider: MediaSessionProviding {
    private(set) var snapshot = MediaSessionSnapshot(
        identifier: "preview-strawberry-milkshakes",
        title: "Strawberry Milkshakes",
        artist: "Arlo",
        album: "Summer Sessions",
        sourceName: "Music",
        sourceBundleIdentifier: "com.apple.Music",
        duration: 198,
        elapsedTime: 22,
        playbackRate: 1,
        updatedAt: .now,
        artwork: nil,
        sourceIcon: NSImage(systemSymbolName: "music.note.list", accessibilityDescription: "Music"),
        capabilities: Set(MediaCommand.allCases)
    )

    var onSnapshotChange: ((MediaSessionSnapshot) -> Void)?

    func start() {
        snapshot.updatedAt = .now
        onSnapshotChange?(snapshot)
    }

    func stop() {}

    func send(_ command: MediaCommand) {
        switch command {
        case .play:
            snapshot.playbackRate = 1
        case .pause:
            snapshot.elapsedTime = snapshot.estimatedElapsedTime()
            snapshot.playbackRate = 0
        case .togglePlayPause:
            snapshot.elapsedTime = snapshot.estimatedElapsedTime()
            snapshot.playbackRate = snapshot.isPlaying ? 0 : 1
        case .previous:
            snapshot.elapsedTime = 0
        case .next:
            snapshot.elapsedTime = 0
            snapshot.title = snapshot.title == "Strawberry Milkshakes" ? "Midnight Coast" : "Strawberry Milkshakes"
        case .skipBackward:
            snapshot.elapsedTime = max(0, snapshot.estimatedElapsedTime() - 15)
        case .skipForward:
            snapshot.elapsedTime = min(snapshot.duration ?? .greatestFiniteMagnitude, snapshot.estimatedElapsedTime() + 15)
        }
        snapshot.updatedAt = .now
        onSnapshotChange?(snapshot)
    }
}
