import AVFoundation
import CoreAudio
import Foundation
import OSLog

/// Captures outgoing audio from the current media process and turns it into
/// five compact frequency-band levels. No audio leaves memory or is persisted.
@MainActor
final class SystemAudioWaveformProvider {
    var onLevelsChange: (([Double], Bool) -> Void)?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Ledge",
        category: "SystemAudioWaveform"
    )
    private var desiredBundleIdentifier: String?
    private var meter: ProcessAudioMeter?
    private var startTask: Task<Void, Never>?

    func update(for snapshot: MediaSessionSnapshot, shouldCapture: Bool) {
        guard shouldCapture,
              snapshot.isPlaying,
              let bundleIdentifier = snapshot.sourceBundleIdentifier,
              !bundleIdentifier.isEmpty else {
            stop()
            return
        }

        guard desiredBundleIdentifier != bundleIdentifier || meter == nil else { return }

        stop(resetDesiredSource: false)
        desiredBundleIdentifier = bundleIdentifier
        onLevelsChange?(Self.silentLevels, false)
        scheduleStart(for: bundleIdentifier)
    }

    func stop() {
        stop(resetDesiredSource: true)
    }

    /// Prompt for System Audio Recording after onboarding without retaining or
    /// processing any audio. Creating and immediately destroying a private tap
    /// exercises the same macOS permission path used by the live meter.
    func requestAccess() async {
        guard meter == nil, startTask == nil else { return }
        let status = await Task.detached(priority: .userInitiated) {
            Self.performPermissionProbe()
        }.value
        if status != noErr {
            logger.debug("System Audio Recording permission probe returned \(status)")
        }
    }

    nonisolated private static func performPermissionProbe() -> OSStatus {
        let description = CATapDescription(
            stereoGlobalTapButExcludeProcesses: []
        )
        description.name = "Ledge Permission Request"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        if status == noErr, tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        return status
    }

    private func stop(resetDesiredSource: Bool) {
        startTask?.cancel()
        startTask = nil
        meter?.stop()
        meter = nil
        if resetDesiredSource {
            desiredBundleIdentifier = nil
        }
        onLevelsChange?(Self.silentLevels, false)
    }

    private func scheduleStart(for bundleIdentifier: String) {
        startTask?.cancel()
        startTask = Task { [weak self] in
            guard let self else { return }

            // Audio helper processes can appear shortly after the now-playing
            // session. Retry while this source remains active instead of
            // permanently falling back to the decorative animation.
            while !Task.isCancelled,
                  desiredBundleIdentifier == bundleIdentifier,
                  meter == nil {
                do {
                    let newMeter = try ProcessAudioMeter(
                        bundleIdentifier: bundleIdentifier
                    ) { [weak self] levels in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  self.desiredBundleIdentifier == bundleIdentifier,
                                  self.meter != nil else {
                                return
                            }
                            self.onLevelsChange?(levels, true)
                        }
                    }
                    try newMeter.start()

                    guard !Task.isCancelled,
                          desiredBundleIdentifier == bundleIdentifier else {
                        newMeter.stop()
                        return
                    }
                    meter = newMeter
                    logger.info("Live audio waveform started for \(bundleIdentifier, privacy: .public)")
                    return
                } catch AudioWaveformError.noAudioProcess {
                    logger.debug(
                        "Waiting for an audio helper process for \(bundleIdentifier, privacy: .public)"
                    )
                } catch {
                    // Permission denial and device failures should not create a
                    // prompt/retry loop. The decorative bars remain available;
                    // a future source change or app launch makes a fresh attempt.
                    logger.error(
                        "Audio waveform unavailable for \(bundleIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                    return
                }

                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
            }
        }
    }

    private static let silentLevels = Array(repeating: 0.0, count: 5)
}

private final class ProcessAudioMeter: @unchecked Sendable {
    private let bundleIdentifier: String
    private let callbackQueue = DispatchQueue(
        label: "com.aramrahimi.Ledge.audio-meter",
        qos: .userInteractive
    )
    private let analyzer: AudioBandAnalyzer

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var deviceIOProcID: AudioDeviceIOProcID?
    private var format: AVAudioFormat?
    private var isStarted = false

    init(
        bundleIdentifier: String,
        onLevels: @escaping @Sendable ([Double]) -> Void
    ) throws {
        self.bundleIdentifier = bundleIdentifier
        analyzer = AudioBandAnalyzer(onLevels: onLevels)
        try prepare()
    }

    func start() throws {
        guard !isStarted,
              aggregateDeviceID != kAudioObjectUnknown,
              let format else {
            return
        }

        var ioProcID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID,
            aggregateDeviceID,
            callbackQueue
        ) { [analyzer, format] _, inputData, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                bufferListNoCopy: inputData,
                deallocator: nil
            ) else {
                return
            }
            analyzer.process(buffer)
        }
        guard status == noErr, let ioProcID else {
            throw AudioWaveformError.coreAudio("create audio I/O callback", status)
        }

        deviceIOProcID = ioProcID
        status = AudioDeviceStart(aggregateDeviceID, ioProcID)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            deviceIOProcID = nil
            throw AudioWaveformError.coreAudio("start audio tap", status)
        }
        isStarted = true
    }

    func stop() {
        if aggregateDeviceID != kAudioObjectUnknown, let deviceIOProcID {
            AudioDeviceStop(aggregateDeviceID, deviceIOProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, deviceIOProcID)
            self.deviceIOProcID = nil
        }
        isStarted = false

        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }

        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        format = nil
    }

    deinit {
        stop()
    }

    private func prepare() throws {
        let processIDs = try CoreAudioProcessLookup.processObjectIDs(
            matching: bundleIdentifier
        )
        guard !processIDs.isEmpty else {
            throw AudioWaveformError.noAudioProcess(bundleIdentifier)
        }

        let tapDescription = CATapDescription(
            stereoMixdownOfProcesses: processIDs
        )
        tapDescription.name = "Ledge – \(bundleIdentifier)"
        tapDescription.uuid = UUID()
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var createdTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(tapDescription, &createdTapID)
        guard status == noErr else {
            throw AudioWaveformError.coreAudio("create process tap", status)
        }
        tapID = createdTapID

        do {
            var streamDescription: AudioStreamBasicDescription = try CoreAudioProperty.read(
                objectID: tapID,
                selector: kAudioTapPropertyFormat,
                defaultValue: AudioStreamBasicDescription()
            )
            guard let audioFormat = AVAudioFormat(
                streamDescription: &streamDescription
            ) else {
                throw AudioWaveformError.invalidAudioFormat
            }
            format = audioFormat

            let outputDeviceID: AudioObjectID = try CoreAudioProperty.read(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                defaultValue: kAudioObjectUnknown
            )
            guard outputDeviceID != kAudioObjectUnknown else {
                throw AudioWaveformError.missingOutputDevice
            }
            let outputDeviceUID = try CoreAudioProperty.readString(
                objectID: outputDeviceID,
                selector: kAudioDevicePropertyDeviceUID
            )

            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Ledge Audio Meter",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: outputDeviceUID]
                ],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapDriftCompensationKey: true,
                        kAudioSubTapUIDKey: tapDescription.uuid.uuidString
                    ]
                ]
            ]

            var createdAggregateID = AudioObjectID(kAudioObjectUnknown)
            status = AudioHardwareCreateAggregateDevice(
                aggregateDescription as CFDictionary,
                &createdAggregateID
            )
            guard status == noErr else {
                throw AudioWaveformError.coreAudio("create aggregate tap device", status)
            }
            aggregateDeviceID = createdAggregateID
        } catch {
            stop()
            throw error
        }
    }
}

private enum CoreAudioProcessLookup {
    static func processObjectIDs(matching targetBundleIdentifier: String) throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr else {
            throw AudioWaveformError.coreAudio("read audio process list size", status)
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var processIDs = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        status = processIDs.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                bytes.baseAddress!
            )
        }
        guard status == noErr else {
            throw AudioWaveformError.coreAudio("read audio process list", status)
        }

        return processIDs.filter { processID in
            guard let processBundleIdentifier = try? CoreAudioProperty.readString(
                objectID: processID,
                selector: kAudioProcessPropertyBundleID
            ) else {
                return false
            }
            return AudioProcessFamilyMatcher.matches(
                processBundleIdentifier,
                target: targetBundleIdentifier
            )
        }
    }
}

enum AudioProcessFamilyMatcher {
    static func matches(_ candidate: String, target: String) -> Bool {
        let candidate = candidate.lowercased()
        let target = target.lowercased()

        if target.contains("spotify") {
            return candidate.contains("spotify")
        }
        if target == "com.apple.safari" || target.hasPrefix("com.apple.webkit") {
            return candidate == "com.apple.safari" || candidate.hasPrefix("com.apple.webkit")
        }

        let browserFamilies = [
            "com.google.chrome",
            "com.microsoft.edgemac",
            "com.brave.browser",
            "org.chromium.chromium",
            "org.mozilla.firefox"
        ]
        if let family = browserFamilies.first(where: { target.hasPrefix($0) }) {
            return candidate.hasPrefix(family)
        }

        return candidate == target || candidate.hasPrefix(target + ".")
    }
}

private enum CoreAudioProperty {
    static func read<T>(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        defaultValue: T
    ) throws -> T {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<T>.size)
        var value = defaultValue
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &dataSize,
                pointer
            )
        }
        guard status == noErr else {
            throw AudioWaveformError.coreAudio("read Core Audio property", status)
        }
        return value
    }

    static func readString(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> String {
        let value: CFString = try read(
            objectID: objectID,
            selector: selector,
            defaultValue: "" as CFString
        )
        return value as String
    }
}

final class AudioBandAnalyzer: @unchecked Sendable {
    private let onLevels: @Sendable ([Double]) -> Void
    private var smoothedLevels = Array(repeating: 0.0, count: 5)
    private var lastAnalysisTime = CFAbsoluteTimeGetCurrent()
    private var lastPublishTime = 0.0

    private static let frequencies: [[Double]] = [
        [70, 110],
        [180, 300],
        [550, 900],
        [1_600, 2_800],
        [5_000, 8_500]
    ]

    init(onLevels: @escaping @Sendable ([Double]) -> Void) {
        self.onLevels = onLevels
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let samples = monoSamples(from: buffer), samples.values.count >= 32 else { return }

        let now = CFAbsoluteTimeGetCurrent()
        let delta = min(max(now - lastAnalysisTime, 0.001), 0.2)
        lastAnalysisTime = now
        let levels = Self.levels(
            for: samples.values,
            sampleRate: buffer.format.sampleRate / Double(samples.decimation)
        )

        for index in smoothedLevels.indices {
            let target = levels[index]
            let timeConstant = target > smoothedLevels[index] ? 0.035 : 0.22
            let smoothing = 1 - exp(-delta / timeConstant)
            smoothedLevels[index] += (target - smoothedLevels[index]) * smoothing
        }

        guard now - lastPublishTime >= 1.0 / 30.0 else { return }
        lastPublishTime = now
        onLevels(smoothedLevels)
    }

    private func monoSamples(
        from buffer: AVAudioPCMBuffer
    ) -> (values: [Double], decimation: Int)? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return nil }

        let decimation = max(1, frameCount / 1_024)
        var result = [Double]()
        result.reserveCapacity((frameCount + decimation - 1) / decimation)

        for frame in stride(from: 0, to: frameCount, by: decimation) {
            var sum: Float = 0
            if buffer.format.isInterleaved {
                let base = channelData[0]
                for channel in 0..<channelCount {
                    sum += base[frame * channelCount + channel]
                }
            } else {
                for channel in 0..<channelCount {
                    sum += channelData[channel][frame]
                }
            }
            result.append(Double(sum / Float(channelCount)))
        }
        return (result, decimation)
    }

    static func levels(for samples: [Double], sampleRate: Double) -> [Double] {
        guard !samples.isEmpty, sampleRate > 0 else {
            return Array(repeating: 0, count: 5)
        }

        let squareSum = samples.reduce(0) { $0 + $1 * $1 }
        let rms = sqrt(squareSum / Double(samples.count))
        let rmsDecibels = 20 * log10(max(rms, 0.000_001))
        guard rmsDecibels > -68 else {
            return Array(repeating: 0, count: 5)
        }

        let energyScale = min(max((rmsDecibels + 58) / 48, 0), 1)
        return frequencies.map { probes in
            let magnitudes = probes.compactMap { frequency -> Double? in
                guard frequency < sampleRate * 0.48 else { return nil }
                return goertzelMagnitude(
                    samples: samples,
                    sampleRate: sampleRate,
                    frequency: frequency
                )
            }
            guard !magnitudes.isEmpty else { return 0 }

            let magnitude = magnitudes.reduce(0, +) / Double(magnitudes.count)
            let decibels = 20 * log10(max(magnitude, 0.000_001))
            let bandLevel = min(max((decibels + 62) / 52, 0), 1)
            return min(max(bandLevel * (0.22 + energyScale * 1.05), 0), 1)
        }
    }

    private static func goertzelMagnitude(
        samples: [Double],
        sampleRate: Double,
        frequency: Double
    ) -> Double {
        let coefficient = 2 * cos(2 * .pi * frequency / sampleRate)
        var previous = 0.0
        var previousPrevious = 0.0
        let denominator = Double(max(samples.count - 1, 1))

        for (index, sample) in samples.enumerated() {
            let window = 0.5 - 0.5 * cos(2 * .pi * Double(index) / denominator)
            let current = sample * window + coefficient * previous - previousPrevious
            previousPrevious = previous
            previous = current
        }

        let power = previousPrevious * previousPrevious
            + previous * previous
            - coefficient * previous * previousPrevious
        return 2 * sqrt(max(power, 0)) / Double(samples.count)
    }
}

private enum AudioWaveformError: LocalizedError {
    case noAudioProcess(String)
    case invalidAudioFormat
    case missingOutputDevice
    case coreAudio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case let .noAudioProcess(bundleIdentifier):
            "No active audio process found for \(bundleIdentifier)."
        case .invalidAudioFormat:
            "The process tap returned an unsupported audio format."
        case .missingOutputDevice:
            "The default system audio output is unavailable."
        case let .coreAudio(operation, status):
            "Could not \(operation) (Core Audio error \(status))."
        }
    }
}
