import AppKit
import Foundation

@MainActor
final class SpotifyFallbackService {
    static let persistedTrackDefaultsKey = "spotifyFallbackTrack.v2"

    private struct PendingPlaybackIntent {
        let isPlaying: Bool
        let expiresAt: Date
    }

    private struct CachedTrack: Codable {
        let identifier: String
        let title: String
        let artist: String
        let album: String
        let duration: TimeInterval?
        let elapsedTime: TimeInterval
        let artworkURL: String?
    }

    private let client = NowPlayingScriptClient()
    private let legacyDefaultsKey = "spotifyFallbackTrack.v1"
    private let defaults: UserDefaults
    private var pollingTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var pendingArtworkIdentifier: String?
    private var cachedTrack: CachedTrack?
    private var artworkCache: [String: NSImage] = [:]
    private var artworkCacheOrder: [String] = []
    private var pendingPlaybackIntent: PendingPlaybackIntent?

    private(set) var snapshot: MediaSessionSnapshot = .empty
    var onSnapshotChange: ((MediaSessionSnapshot) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func start() {
        guard pollingTask == nil else { return }
        defaults.removeObject(forKey: legacyDefaultsKey)
        restorePersistedSnapshot()
        if let cachedTrack {
            loadArtworkIfNeeded(
                urlString: cachedTrack.artworkURL,
                identifier: cachedTrack.identifier
            )
        }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stop() {
        persistCachedTrack()
        pollingTask?.cancel()
        pollingTask = nil
        artworkTask?.cancel()
        artworkTask = nil
        pendingArtworkIdentifier = nil
        cachedTrack = nil
        artworkCache.removeAll()
        artworkCacheOrder.removeAll()
        pendingPlaybackIntent = nil
        publish(.empty)
    }

    func send(_ command: MediaCommand) {
        let spotifyURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client")
        let isRunning = !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.spotify.client"
        ).isEmpty

        applyOptimisticState(for: command)

        if !isRunning, let spotifyURL {
            NSWorkspace.shared.openApplication(
                at: spotifyURL,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, _ in }
        }

        Task {
            if !isRunning {
                await waitForSpotifyLaunch()
            }
            await client.send(command, sourceBundleIdentifier: "com.spotify.client")
            try? await Task.sleep(for: .milliseconds(350))
            await refresh()
        }
    }

    private func refresh() async {
        guard let response = await client.fetchSpotifySnapshot(),
              response.available,
              let title = response.title,
              !title.isEmpty else {
            publishCachedSnapshot()
            return
        }

        let artworkURL = response.artworkURL.flatMap { value -> String? in
            guard let url = URL(string: value),
                  SystemMediaSessionProvider.isAllowedRemoteArtworkURL(url) else {
                return nil
            }
            return value
        }
        let track = CachedTrack(
            identifier: response.contentIdentifier ?? "spotify:\(title):\(response.artist ?? "")",
            title: title,
            artist: response.artist ?? "Spotify",
            album: response.album ?? "",
            duration: response.duration,
            elapsedTime: response.elapsed ?? 0,
            artworkURL: artworkURL
        )
        let shouldPersist = cachedTrack?.identifier != track.identifier
            || cachedTrack?.artworkURL != track.artworkURL
        if cachedTrack?.identifier != track.identifier {
            artworkTask?.cancel()
            artworkTask = nil
            pendingArtworkIdentifier = nil
        }
        cachedTrack = track
        if shouldPersist {
            persistCachedTrack()
        }

        let exactArtwork = artworkCache[track.identifier]
        let artwork = MediaArtworkTransition.resolvedArtwork(
            exactArtwork: exactArtwork,
            previousSnapshot: snapshot,
            nextSourceBundleIdentifier: "com.spotify.client",
            hasPendingRemoteArtwork: track.artworkURL != nil
        )

        var next = makeSnapshot(
            from: track,
            playbackRate: response.effectivePlaybackRate,
            artwork: artwork
        )
        reconcilePendingPlaybackIntent(in: &next)
        publish(next)
        loadArtworkIfNeeded(urlString: track.artworkURL, identifier: track.identifier)
    }

    private func publishCachedSnapshot() {
        guard let cachedTrack else { return }
        var next = makeSnapshot(
            from: cachedTrack,
            playbackRate: 0,
            artwork: artworkCache[cachedTrack.identifier] ?? snapshot.artwork
        )
        reconcilePendingPlaybackIntent(in: &next)
        publish(next)
    }

    func restorePersistedSnapshot() {
        guard cachedTrack == nil,
              let data = defaults.data(forKey: Self.persistedTrackDefaultsKey),
              let restored = try? JSONDecoder().decode(CachedTrack.self, from: data),
              !restored.title.isEmpty else {
            return
        }
        cachedTrack = restored
        publishCachedSnapshot()
    }

    private func persistCachedTrack() {
        guard let cachedTrack,
              let data = try? JSONEncoder().encode(cachedTrack) else { return }
        defaults.set(data, forKey: Self.persistedTrackDefaultsKey)
    }

    private func waitForSpotifyLaunch() async {
        for _ in 0..<40 {
            let isRunning = !NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.spotify.client"
            ).isEmpty
            if isRunning {
                // Give Spotify a moment after process registration to finish
                // installing its Apple Events playback handlers.
                try? await Task.sleep(for: .milliseconds(300))
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func applyOptimisticState(for command: MediaCommand) {
        let wasPlaying = snapshot.isPlaying
        let updated = snapshot.applyingOptimisticPlaybackCommand(command)
        let expectedState: Bool? = switch command {
        case .play: true
        case .pause: false
        case .togglePlayPause: !wasPlaying
        case .previous, .next, .skipBackward, .skipForward: nil
        }
        if let expectedState {
            pendingPlaybackIntent = PendingPlaybackIntent(
                isPlaying: expectedState,
                expiresAt: .now.addingTimeInterval(2)
            )
        }
        publish(updated)
    }

    private func reconcilePendingPlaybackIntent(in reported: inout MediaSessionSnapshot) {
        guard let intent = pendingPlaybackIntent else { return }
        guard Date.now < intent.expiresAt else {
            pendingPlaybackIntent = nil
            return
        }
        if reported.isPlaying == intent.isPlaying {
            pendingPlaybackIntent = nil
            return
        }

        reported.elapsedTime = snapshot.estimatedElapsedTime()
        reported.playbackRate = intent.isPlaying ? max(snapshot.playbackRate, 1) : 0
        reported.updatedAt = .now
    }

    private func makeSnapshot(
        from track: CachedTrack,
        playbackRate: Double,
        artwork: NSImage?
    ) -> MediaSessionSnapshot {
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client")
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        return MediaSessionSnapshot(
            identifier: "spotify-fallback:\(track.identifier)",
            title: track.title,
            artist: track.artist,
            album: track.album,
            sourceName: "Spotify",
            sourceBundleIdentifier: "com.spotify.client",
            duration: track.duration,
            elapsedTime: track.elapsedTime,
            playbackRate: playbackRate,
            updatedAt: .now,
            artwork: artwork,
            sourceIcon: icon,
            capabilities: [.play, .pause, .togglePlayPause, .previous, .next]
        )
    }

    private func loadArtworkIfNeeded(urlString: String?, identifier: String) {
        guard artworkCache[identifier] == nil,
              artworkTask == nil,
              let urlString,
              let url = URL(string: urlString),
              SystemMediaSessionProvider.isAllowedRemoteArtworkURL(url) else { return }

        pendingArtworkIdentifier = identifier
        artworkTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if pendingArtworkIdentifier == identifier {
                    pendingArtworkIdentifier = nil
                    artworkTask = nil
                }
            }
            do {
                let data = try await ArtworkNetwork.download(url)
                guard
                      let image = NSImage(data: data),
                      cachedTrack?.identifier == identifier else { return }
                cacheArtwork(image, for: identifier)
                guard let cachedTrack, cachedTrack.identifier == identifier else { return }
                publish(makeSnapshot(
                    from: cachedTrack,
                    playbackRate: snapshot.playbackRate,
                    artwork: image
                ))
            } catch {
                // Artwork is optional; cached metadata remains useful offline.
            }
        }
    }

    private func cacheArtwork(_ image: NSImage, for identifier: String) {
        artworkCache[identifier] = image
        artworkCacheOrder.removeAll(where: { $0 == identifier })
        artworkCacheOrder.append(identifier)

        while artworkCacheOrder.count > 24 {
            artworkCache[artworkCacheOrder.removeFirst()] = nil
        }
    }

    private func publish(_ next: MediaSessionSnapshot) {
        snapshot = next
        onSnapshotChange?(next)
    }
}
