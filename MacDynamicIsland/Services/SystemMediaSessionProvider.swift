import AppKit
import Foundation

enum ArtworkNetwork {
    static let maximumBytes = 20_000_000

    private static let redirectDelegate = ArtworkRedirectDelegate()
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        return URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
    }()

    nonisolated static func isAllowedURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty,
              url.user == nil,
              url.password == nil else {
            return false
        }
        return true
    }

    static func download(_ url: URL) async throws -> Data {
        guard isAllowedURL(url) else { throw URLError(.unsupportedURL) }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              let finalURL = httpResponse.url,
              isAllowedURL(finalURL),
              (200..<300).contains(httpResponse.statusCode),
              httpResponse.expectedContentLength <= Int64(maximumBytes) else {
            throw URLError(.badServerResponse)
        }

        var data = Data()
        data.reserveCapacity(
            min(max(Int(httpResponse.expectedContentLength), 0), maximumBytes)
        )
        for try await byte in bytes {
            guard data.count < maximumBytes else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            data.append(byte)
        }
        return data
    }
}

private final class ArtworkRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, ArtworkNetwork.isAllowedURL(url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

@MainActor
final class SystemMediaSessionProvider: MediaSessionProviding {
    private struct PendingPlaybackIntent {
        let isPlaying: Bool
        let expiresAt: Date
    }

    private let scriptClient = NowPlayingScriptClient()
    private var pollingTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var mediaLossTask: Task<Void, Never>?
    private var spotifyObserver: NSObjectProtocol?
    private var pendingArtworkURL: URL?
    private var artworkCache: [URL: NSImage] = [:]
    private var artworkCacheOrder: [URL] = []
    private var sourceIconCache: [String: NSImage] = [:]
    private var pendingPlaybackIntent: PendingPlaybackIntent?

    private(set) var snapshot: MediaSessionSnapshot = .empty
    var onSnapshotChange: ((MediaSessionSnapshot) -> Void)?

    func start() {
        guard pollingTask == nil else { return }

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }

        spotifyObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        artworkTask?.cancel()
        artworkTask = nil
        mediaLossTask?.cancel()
        mediaLossTask = nil
        pendingArtworkURL = nil
        pendingPlaybackIntent = nil
        if let spotifyObserver {
            DistributedNotificationCenter.default().removeObserver(spotifyObserver)
        }
        spotifyObserver = nil
        publish(.empty)
    }

    func send(_ command: MediaCommand) {
        let sourceBundleIdentifier = snapshot.sourceBundleIdentifier
        applyOptimisticState(for: command)
        Task {
            await scriptClient.send(command, sourceBundleIdentifier: sourceBundleIdentifier)

            // Spotify notifications normally refresh immediately. These checks
            // also confirm browser commands after MediaRemote has propagated
            // the new YouTube playback state.
            for delay in [100, 300, 700] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled else { return }
                await refresh()
            }
        }
    }

    private func refresh() async {
        guard let response = await scriptClient.fetchSnapshot(), response.available else {
            scheduleMediaLoss()
            return
        }

        cancelMediaLoss()

        let bundleIdentifier = Self.normalizedBundleIdentifier(response.bundleIdentifier)
        let identifier = Self.identifier(for: response)
        let sourceIcon = sourceIcon(bundleIdentifier: bundleIdentifier)
        let remoteArtworkURL = Self.artworkURL(for: response)
        let embeddedArtwork = Self.decodedArtwork(from: response.artwork)
        let artwork = resolvedArtwork(
            identifier: identifier,
            remoteURL: remoteArtworkURL,
            sourceBundleIdentifier: bundleIdentifier,
            embeddedArtwork: embeddedArtwork
        )
        let rate = response.effectivePlaybackRate
        let title = response.title ?? "Unknown media"

        var nextSnapshot = MediaSessionSnapshot(
            identifier: identifier,
            title: title,
            artist: response.artist ?? response.app ?? "Unknown source",
            album: response.album ?? "",
            sourceName: response.app ?? "Media",
            sourceBundleIdentifier: bundleIdentifier,
            duration: response.duration,
            elapsedTime: response.elapsed ?? 0,
            playbackRate: rate,
            updatedAt: .now,
            artwork: artwork,
            sourceIcon: sourceIcon,
            capabilities: response.capabilities
        )
        reconcilePendingPlaybackIntent(in: &nextSnapshot)
        publish(nextSnapshot)

        if embeddedArtwork == nil,
           let remoteArtworkURL,
           artworkCache[remoteArtworkURL] == nil {
            scheduleArtworkLoad(from: remoteArtworkURL, for: identifier)
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

        // MediaRemote can return the old state while a command propagates.
        // Preserve the immediate local result but still accept new metadata.
        reported.elapsedTime = snapshot.estimatedElapsedTime()
        reported.playbackRate = intent.isPlaying ? max(snapshot.playbackRate, 1) : 0
        reported.updatedAt = .now
    }

    private func scheduleMediaLoss() {
        // MediaRemote occasionally returns no player for one poll while a
        // browser command or route change is propagating. Retain the last
        // valid snapshot long enough to bridge that gap so the island does not
        // flash back to its idle state in the middle of an animation.
        guard mediaLossTask == nil else { return }

        mediaLossTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }

            guard !Task.isCancelled, let self else { return }
            mediaLossTask = nil
            publish(.empty)
        }
    }

    private func cancelMediaLoss() {
        mediaLossTask?.cancel()
        mediaLossTask = nil
    }

    private func publish(_ newSnapshot: MediaSessionSnapshot) {
        if snapshot.identifier == newSnapshot.identifier,
           snapshot.title == newSnapshot.title,
           snapshot.artist == newSnapshot.artist,
           snapshot.album == newSnapshot.album,
           snapshot.sourceName == newSnapshot.sourceName,
           snapshot.sourceBundleIdentifier == newSnapshot.sourceBundleIdentifier,
           snapshot.playbackRate == newSnapshot.playbackRate,
           snapshot.duration == newSnapshot.duration,
           snapshot.capabilities == newSnapshot.capabilities,
           snapshot.artwork === newSnapshot.artwork,
           abs(snapshot.estimatedElapsedTime() - newSnapshot.elapsedTime) < 2.5 {
            return
        }

        snapshot = newSnapshot
        onSnapshotChange?(newSnapshot)
    }

    private func resolvedArtwork(
        identifier: String,
        remoteURL: URL?,
        sourceBundleIdentifier: String?,
        embeddedArtwork: NSImage?
    ) -> NSImage? {
        if snapshot.identifier == identifier, let artwork = snapshot.artwork {
            return artwork
        }

        if let remoteURL, let cached = artworkCache[remoteURL] {
            return cached
        }

        // A new Spotify track commonly exposes its cover URL before the image
        // download finishes. Bridge that short gap with the previous cover so
        // the application icon never flashes between real artworks.
        return MediaArtworkTransition.resolvedArtwork(
            exactArtwork: embeddedArtwork,
            previousSnapshot: snapshot,
            nextSourceBundleIdentifier: sourceBundleIdentifier,
            hasPendingRemoteArtwork: remoteURL != nil
        )
    }

    private static func decodedArtwork(from encoded: String?) -> NSImage? {
        encoded
            .flatMap { value in
                guard value.utf8.count <= 26_700_000 else { return nil }
                return Data(base64Encoded: value)
            }
            .flatMap { NSImage(data: $0) }
    }

    private func scheduleArtworkLoad(from url: URL, for identifier: String) {
        guard pendingArtworkURL != url else { return }

        artworkTask?.cancel()
        pendingArtworkURL = url
        artworkTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if pendingArtworkURL == url {
                    pendingArtworkURL = nil
                }
            }

            do {
                let data: Data
                if url.isFileURL {
                    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    guard values.isRegularFile == true,
                          let fileSize = values.fileSize,
                          fileSize <= ArtworkNetwork.maximumBytes else {
                        throw URLError(.dataLengthExceedsMaximum)
                    }
                    data = try Data(contentsOf: url, options: .mappedIfSafe)
                } else {
                    data = try await ArtworkNetwork.download(url)
                }

                guard !Task.isCancelled,
                      data.count <= ArtworkNetwork.maximumBytes,
                      let image = NSImage(data: data) else {
                    return
                }

                cacheArtwork(image, for: url)
                guard snapshot.identifier == identifier else { return }

                var updatedSnapshot = snapshot
                updatedSnapshot.artwork = image
                publish(updatedSnapshot)
            } catch {
                // Missing remote artwork should not invalidate otherwise usable
                // playback metadata or controls.
            }
        }
    }

    private func cacheArtwork(_ image: NSImage, for url: URL) {
        artworkCache[url] = image
        artworkCacheOrder.removeAll(where: { $0 == url })
        artworkCacheOrder.append(url)

        while artworkCacheOrder.count > 24 {
            let expiredURL = artworkCacheOrder.removeFirst()
            artworkCache[expiredURL] = nil
        }
    }

    private func sourceIcon(bundleIdentifier: String?) -> NSImage? {
        guard let bundleIdentifier else { return nil }
        if let cached = sourceIconCache[bundleIdentifier] {
            return cached
        }

        guard let icon = Self.applicationIcon(bundleIdentifier: bundleIdentifier) else {
            return nil
        }
        sourceIconCache[bundleIdentifier] = icon
        return icon
    }

    private static func applicationIcon(bundleIdentifier: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private static func normalizedBundleIdentifier(_ bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier else { return nil }

        if bundleIdentifier.hasPrefix("com.apple.WebKit.") {
            return "com.apple.Safari"
        }

        let browserHelpers: [(prefix: String, application: String)] = [
            ("com.google.Chrome.helper", "com.google.Chrome"),
            ("com.microsoft.edgemac.helper", "com.microsoft.edgemac"),
            ("com.brave.Browser.helper", "com.brave.Browser"),
            ("org.chromium.Chromium.helper", "org.chromium.Chromium")
        ]
        return browserHelpers.first(where: { bundleIdentifier.hasPrefix($0.prefix) })?.application
            ?? bundleIdentifier
    }

    private static func identifier(for response: ScriptMediaSnapshot) -> String {
        let mediaIdentifier = response.contentIdentifier
            ?? response.externalContentIdentifier
            ?? response.artworkIdentifier
        return [
            response.bundleIdentifier ?? "unknown",
            mediaIdentifier ?? response.title ?? "unknown",
            response.artist ?? "",
            response.album ?? ""
        ].joined(separator: ":")
    }

    private static func artworkURL(for response: ScriptMediaSnapshot) -> URL? {
        if let rawArtworkURL = response.artworkURL {
            let expandedURL = rawArtworkURL
                .replacingOccurrences(of: "{w}", with: "600")
                .replacingOccurrences(of: "{h}", with: "600")
                .replacingOccurrences(of: "{f}", with: "jpg")
            if let url = URL(string: expandedURL) {
                return url
            }
        }

        // Some browser sessions expose the page URL but omit artwork. This is
        // a safe YouTube-only fallback and never guesses from an arbitrary ID.
        for identifier in [response.externalContentIdentifier, response.contentIdentifier].compactMap({ $0 }) {
            guard let videoID = youtubeVideoID(from: identifier) else { continue }
            return URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")
        }

        return nil
    }

    nonisolated static func isAllowedRemoteArtworkURL(_ url: URL) -> Bool {
        ArtworkNetwork.isAllowedURL(url)
    }

    private static func youtubeVideoID(from value: String) -> String? {
        guard let url = URL(string: value),
              let host = url.host?.lowercased() else {
            return nil
        }

        if host == "youtu.be" {
            return url.pathComponents.dropFirst().first
        }

        guard host == "youtube.com" || host.hasSuffix(".youtube.com") else {
            return nil
        }

        if url.path == "/watch" {
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "v" })?
                .value
        }

        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 2,
              ["shorts", "embed", "live"].contains(components[0]) else {
            return nil
        }
        return components[1]
    }
}
