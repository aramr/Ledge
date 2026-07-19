import Darwin
import Foundation

extension Process {
    /// `terminate()` sends SIGTERM, which a child process can ignore. Bound
    /// the grace period and escalate so a media/helper command can never hold
    /// the app indefinitely during shutdown or polling.
    func terminateAndForceIfNeeded(gracePeriod: TimeInterval = 0.25) {
        guard isRunning else { return }
        terminate()

        let deadline = Date.now.addingTimeInterval(gracePeriod)
        while isRunning, Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if isRunning {
            Darwin.kill(processIdentifier, SIGKILL)
        }
    }
}

struct ScriptMediaSnapshot: Decodable, Sendable {
    let available: Bool
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    let elapsed: Double?
    let rate: Double?
    let isPlaying: Bool?
    let playbackState: Int?
    let app: String?
    let bundleIdentifier: String?
    let contentIdentifier: String?
    let externalContentIdentifier: String?
    let artworkIdentifier: String?
    let artwork: String?
    let artworkURL: String?
    let supportedCommands: [Int]?

    var effectivePlaybackRate: Double {
        if let isPlaying {
            guard isPlaying else { return 0 }
            return max(rate ?? 1, 0.01)
        }
        return max(rate ?? 0, 0)
    }

    var capabilities: Set<MediaCommand> {
        guard let supportedCommands, !supportedCommands.isEmpty else {
            return Set(MediaCommand.allCases)
        }

        return Set(supportedCommands.compactMap { command in
            switch command {
            case 0: .play
            case 1: .pause
            case 2: .togglePlayPause
            case 4: .next
            case 5: .previous
            case 17: .skipForward
            case 18: .skipBackward
            default: nil
            }
        })
    }
}

actor NowPlayingScriptClient {
    func fetchSnapshot() -> ScriptMediaSnapshot? {
        guard let output = run(script: Self.metadataScript) else { return nil }
        return try? JSONDecoder().decode(ScriptMediaSnapshot.self, from: output)
    }

    func fetchSpotifySnapshot() -> ScriptMediaSnapshot? {
        guard let output = run(script: Self.spotifyMetadataScript) else { return nil }
        return try? JSONDecoder().decode(ScriptMediaSnapshot.self, from: output)
    }

    func send(_ command: MediaCommand, sourceBundleIdentifier: String?) {
        let rawCommand: Int
        switch command {
        case .play: rawCommand = 0
        case .pause: rawCommand = 1
        case .togglePlayPause: rawCommand = 2
        case .next: rawCommand = 4
        case .previous: rawCommand = 5
        case .skipForward: rawCommand = 17
        case .skipBackward: rawCommand = 18
        }

        let spotifyCommand: String
        let spotifyMethod: String? = switch command {
        case .play: "play"
        case .pause: "pause"
        case .togglePlayPause: "playpause"
        case .next: "nextTrack"
        case .previous: "previousTrack"
        case .skipBackward, .skipForward: nil
        }
        if sourceBundleIdentifier == "com.spotify.client", let spotifyMethod {
            spotifyCommand = """
            try {
                const spotify = Application("Spotify");
                if (spotify.running()) {
                    spotify.\(spotifyMethod)();
                    handled = true;
                }
            }
            catch (_) {}
            """
        } else {
            spotifyCommand = ""
        }

        let script = """
        ObjC.import("Foundation");
        let handled = false;
        \(spotifyCommand)
        if (!handled) {
            const framework = $.NSBundle.bundleWithPath("/System/Library/PrivateFrameworks/MediaRemote.framework/");
            framework.load;
            const Request = $.NSClassFromString("MRNowPlayingRequest");
            const playerPath = Request.localNowPlayingPlayerPath;
            const request = playerPath
                ? Request.alloc.initWithPlayerPath(playerPath)
                : Request.alloc.init;
            let options = $.NSDictionary.dictionary;
            if (\(rawCommand) === 17 || \(rawCommand) === 18) {
                options = $.NSDictionary.dictionaryWithObjectForKey(
                    $.NSNumber.numberWithDouble(15),
                    "kMRMediaRemoteOptionSkipInterval"
                );
            }

            // MediaRemote silently drops browser commands when completion is
            // nil. Keep a real block and the host process alive long enough for
            // WebKit/Chromium to receive the player-targeted request.
            const completion = ObjC.block("v@", function(_) {});
            request.sendCommandOptionsQueueCompletion(
                \(rawCommand),
                options,
                $.NSOperationQueue.mainQueue.underlyingQueue,
                completion
            );
            delay(0.35);
        }
        """
        _ = run(script: script)
    }

    private func run(script: String) -> Data? {
        let process = Process()
        let outputCapture = BoundedPipeCapture(maximumBytes: 10_000_000)

        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script]
        process.standardOutput = outputCapture.pipe
        process.standardError = FileHandle.nullDevice
        outputCapture.start()

        do {
            try process.run()
            outputCapture.closeParentWriter()
            let timeout = DispatchWorkItem { [weak process] in
                guard let process, process.isRunning else { return }
                process.terminateAndForceIfNeeded()
            }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + 4,
                execute: timeout
            )
            // Drain stdout while the process runs. Waiting first can deadlock
            // when encoded artwork fills an OS pipe buffer.
            process.waitUntilExit()
            timeout.cancel()
            let output = outputCapture.finish()
            guard process.terminationStatus == 0,
                  !output.didExceedLimit else { return nil }
            return output.data
        } catch {
            outputCapture.closeParentWriter()
            process.terminateAndForceIfNeeded()
            return nil
        }
    }

    private static let metadataScript = """
    ObjC.import("Foundation");

    const framework = $.NSBundle.bundleWithPath("/System/Library/PrivateFrameworks/MediaRemote.framework/");
    framework.load;

    const Request = $.NSClassFromString("MRNowPlayingRequest");
    const item = Request.localNowPlayingItem;

    if (!item) {
        JSON.stringify({ available: false });
    } else {
        const info = item.nowPlayingInfo;
        const metadata = item.metadata;
        const path = Request.localNowPlayingPlayerPath;
        const keys = info ? ObjC.deepUnwrap(info.allKeys) : [];

        function value(key) {
            if (!keys.includes(key)) return null;
            try { return ObjC.unwrap(info.objectForKey(key)); }
            catch (_) { return null; }
        }

        function scalar(object) {
            if (object === null || object === undefined) return null;
            try { return ObjC.unwrap(object); }
            catch (_) {
                try { return object.js; }
                catch (_) { return null; }
            }
        }

        function urlString(object) {
            if (!object) return null;
            const unwrapped = scalar(object);
            if (typeof unwrapped === "string") return unwrapped;
            try { return object.absoluteString.js; }
            catch (_) { return null; }
        }

        function limitedText(value, maximumLength) {
            if (value === null || value === undefined) return null;
            try { return String(value).slice(0, maximumLength); }
            catch (_) { return null; }
        }

        let artwork = null;
        if (keys.includes("kMRMediaRemoteNowPlayingInfoArtworkData")) {
            try {
                const data = info.objectForKey("kMRMediaRemoteNowPlayingInfoArtworkData");
                if (Number(data.length) <= 20000000) {
                    artwork = data.base64EncodedStringWithOptions(0).js;
                }
            } catch (_) {}
        }

        if (!artwork && item.artwork) {
            try {
                const data = item.artwork.imageData;
                if (Number(data.length) <= 20000000) {
                    artwork = data.base64EncodedStringWithOptions(0).js;
                }
            } catch (_) {}
        }

        let artworkURL = urlString(value("kMRMediaRemoteNowPlayingInfoArtworkURL"));
        if (!artworkURL && metadata) {
            try { artworkURL = urlString(metadata.artworkURL); } catch (_) {}
            if (!artworkURL) {
                try { artworkURL = urlString(metadata.artworkFileURL); } catch (_) {}
            }
        }

        if (!artworkURL && item.remoteArtworks) {
            try {
                const remoteArtwork = item.remoteArtworks.firstObject;
                artworkURL = remoteArtwork ? scalar(remoteArtwork.artworkURLString) : null;
            } catch (_) {}
        }

        let calculatedPosition = metadata
            ? scalar(metadata.calculatedPlaybackPosition)
            : value("kMRMediaRemoteNowPlayingInfoElapsedTime");

        let title = value("kMRMediaRemoteNowPlayingInfoTitle");
        let artist = value("kMRMediaRemoteNowPlayingInfoArtist");
        let album = value("kMRMediaRemoteNowPlayingInfoAlbum");
        let duration = value("kMRMediaRemoteNowPlayingInfoDuration");
        let playbackRate = value("kMRMediaRemoteNowPlayingInfoPlaybackRate");
        let isPlaying = scalar(Request.localIsPlaying);
        const bundleIdentifier = path && path.client
            ? scalar(path.client.bundleIdentifier)
            : null;

        if (playbackRate === null && metadata) {
            try {
                if (scalar(metadata.hasPlaybackRate)) {
                    playbackRate = scalar(metadata.playbackRate);
                }
            } catch (_) {}
        }

        // Spotify omits playback rate and artwork bytes from its MediaRemote
        // dictionary. Its native scripting interface fills those gaps without
        // requiring a Spotify Web API account or OAuth token.
        if (bundleIdentifier === "com.spotify.client") {
            try {
                const spotify = Application("Spotify");
                if (spotify.running()) {
                    const track = spotify.currentTrack();
                    const spotifyState = String(spotify.playerState());
                    title = track.name();
                    artist = track.artist();
                    album = track.album();
                    duration = Number(track.duration()) / 1000;
                    calculatedPosition = Number(spotify.playerPosition());
                    artworkURL = track.artworkUrl();
                    isPlaying = spotifyState === "playing";
                    playbackRate = isPlaying ? 1 : 0;
                }
            } catch (_) {}
        }

        let supportedCommands = [];
        try {
            const commands = Request.localSupportedCommands;
            for (let index = 0; index < commands.count; index++) {
                const command = commands.objectAtIndex(index);
                if (scalar(command.enabled)) {
                    supportedCommands.push(Number(scalar(command.command)));
                }
            }
        } catch (_) {}

        JSON.stringify({
            available: true,
            title: limitedText(title, 512),
            artist: limitedText(artist, 512),
            album: limitedText(album, 512),
            duration: duration,
            elapsed: calculatedPosition,
            rate: playbackRate,
            isPlaying: isPlaying,
            playbackState: scalar(Request.localPlaybackState),
            app: limitedText(path && path.client ? scalar(path.client.displayName) : null, 256),
            bundleIdentifier: limitedText(bundleIdentifier, 512),
            contentIdentifier: limitedText(value("kMRMediaRemoteNowPlayingInfoContentItemIdentifier"), 4096),
            externalContentIdentifier: limitedText(value("kMRMediaRemoteNowPlayingInfoExternalContentIdentifier"), 4096),
            artworkIdentifier: limitedText(value("kMRMediaRemoteNowPlayingInfoArtworkIdentifier"), 4096),
            artwork: artwork,
            artworkURL: limitedText(artworkURL, 8192),
            supportedCommands: supportedCommands.slice(0, 64)
        });
    }
    """

    private static let spotifyMetadataScript = """
    const spotify = Application("Spotify");
    function limitedText(value, maximumLength) {
        if (value === null || value === undefined) return null;
        try { return String(value).slice(0, maximumLength); }
        catch (_) { return null; }
    }
    if (!spotify.running()) {
        JSON.stringify({ available: false });
    } else {
        try {
            const track = spotify.currentTrack();
            const state = String(spotify.playerState());
            JSON.stringify({
                available: true,
                title: limitedText(track.name(), 512),
                artist: limitedText(track.artist(), 512),
                album: limitedText(track.album(), 512),
                duration: Number(track.duration()) / 1000,
                elapsed: Number(spotify.playerPosition()),
                rate: state === "playing" ? 1 : 0,
                isPlaying: state === "playing",
                app: "Spotify",
                bundleIdentifier: "com.spotify.client",
                contentIdentifier: limitedText(track.spotifyUrl(), 4096),
                artworkIdentifier: limitedText(track.spotifyUrl(), 4096),
                artworkURL: limitedText(track.artworkUrl(), 8192),
                supportedCommands: [0, 1, 2, 4, 5]
            });
        } catch (_) {
            JSON.stringify({ available: false });
        }
    }
    """
}
