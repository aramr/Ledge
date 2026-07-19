import Foundation

enum ClaudeCodeBridgeConnectionState: Equatable, Sendable {
    case checking
    case notInstalled
    case disconnected
    case working
    case connectedWaiting
    case connected
    case needsRepair
    case conflict
    case failed
}

struct ClaudeCodeBridgeStatus: Equatable, Sendable {
    let state: ClaudeCodeBridgeConnectionState
    let version: String?
    let message: String?

    static let checking = ClaudeCodeBridgeStatus(
        state: .checking,
        version: nil,
        message: nil
    )

    var isConnected: Bool {
        state == .connected || state == .connectedWaiting || state == .needsRepair
    }

    var isBusy: Bool {
        state == .working || state == .checking
    }
}

struct ClaudeStatusLineUsageCache: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let usedPercent: Double
    let resetDate: Date?
    let updatedAt: Date
    let claudeVersion: String?

    var snapshot: ClaudeUsageSnapshot {
        ClaudeUsageSnapshot(
            usedPercent: min(max(usedPercent, 0), 100),
            resetDate: resetDate,
            updatedAt: updatedAt,
            windowDurationMinutes: 7 * 24 * 60,
            planType: "Claude Code"
        )
    }

    func isUsable(at now: Date = .now) -> Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              updatedAt <= now.addingTimeInterval(5 * 60) else {
            return false
        }

        if let resetDate {
            return resetDate >= now.addingTimeInterval(-5 * 60)
                && updatedAt >= now.addingTimeInterval(-8 * 24 * 60 * 60)
        }

        return updatedAt >= now.addingTimeInterval(-7 * 24 * 60 * 60)
    }
}

enum ClaudeStatusLinePayloadParser {
    static func parse(
        _ data: Data,
        updatedAt: Date = .now
    ) -> ClaudeStatusLineUsageCache? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rateLimits = root["rate_limits"] as? [String: Any],
              let weeklyWindow = weeklyWindow(in: rateLimits),
              let usedPercent = number(
                weeklyWindow["used_percentage"] ?? weeklyWindow["utilization"]
              ) else {
            return nil
        }

        return ClaudeStatusLineUsageCache(
            schemaVersion: ClaudeStatusLineUsageCache.currentSchemaVersion,
            usedPercent: min(max(usedPercent, 0), 100),
            resetDate: date(weeklyWindow["resets_at"] ?? weeklyWindow["resetsAt"]),
            updatedAt: updatedAt,
            claudeVersion: root["version"] as? String
        )
    }

    private static func weeklyWindow(in rateLimits: [String: Any]) -> [String: Any]? {
        if let combined = rateLimits["seven_day"] as? [String: Any] {
            return combined
        }

        return rateLimits
            .filter { $0.key.hasPrefix("seven_day_") }
            .compactMap { $0.value as? [String: Any] }
            .max { left, right in
                (number(left["used_percentage"] ?? left["utilization"]) ?? 0)
                    < (number(right["used_percentage"] ?? right["utilization"]) ?? 0)
            }
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: number.doubleValue
        case let string as String: Double(string)
        default: nil
        }
    }

    private static func date(_ value: Any?) -> Date? {
        if let number = number(value) {
            let seconds = number > 10_000_000_000 ? number / 1_000 : number
            return Date(timeIntervalSince1970: seconds)
        }

        guard let string = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: string) { return parsed }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: string)
    }
}

enum ClaudeUsagePaths {
    static var supportDirectory: URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Ledge/ClaudeUsage", isDirectory: true)
        migrateLegacySupportFilesIfNeeded(to: directory)
        secureSupportFiles(in: directory)
        return directory
    }

    static var bridgeConfigurationURL: URL {
        supportDirectory.appendingPathComponent("status-line-bridge.json")
    }

    static var statusLineCacheURL: URL {
        supportDirectory.appendingPathComponent("status-line-usage.json")
    }

    static var claudeSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    static var desktopHistoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
    }

    /// Keep an existing Claude bridge repairable after the product rename.
    /// The legacy directory is retained so an older build can still roll back
    /// its status-line configuration safely.
    private static func migrateLegacySupportFilesIfNeeded(to directory: URL) {
        let fileManager = FileManager.default
        let legacyDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/MacDynamicIsland/ClaudeUsage",
                isDirectory: true
            )
        guard fileManager.fileExists(atPath: legacyDirectory.path) else { return }

        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        for fileName in ["status-line-bridge.json", "status-line-usage.json"] {
            let sourceURL = legacyDirectory.appendingPathComponent(fileName)
            let destinationURL = directory.appendingPathComponent(fileName)
            guard fileManager.fileExists(atPath: sourceURL.path),
                  !fileManager.fileExists(atPath: destinationURL.path) else {
                continue
            }
            try? fileManager.copyItem(at: sourceURL, to: destinationURL)
        }
    }

    private static func secureSupportFiles(in directory: URL) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        for fileName in ["status-line-bridge.json", "status-line-usage.json"] {
            let url = directory.appendingPathComponent(fileName)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            try? fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        }
    }
}

struct ClaudeCodeBridgeConfiguration: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let settingsPath: String
    let installedCommand: String
    let hadOriginalStatusLine: Bool
    let originalStatusLineData: Data?
    let installedAt: Date

    var originalCommand: String? {
        guard hadOriginalStatusLine,
              let originalStatusLineData,
              let object = try? JSONSerialization.jsonObject(with: originalStatusLineData),
              let statusLine = object as? [String: Any],
              statusLine["type"] as? String == "command",
              let command = statusLine["command"] as? String,
              !command.contains(ClaudeStatusLineBridgeRunner.argument) else {
            return nil
        }
        return command
    }
}

enum ClaudeCodeSettingsEditor {
    struct Installation: Sendable {
        let settingsData: Data
        let hadOriginalStatusLine: Bool
        let originalStatusLineData: Data?
    }

    enum EditingError: Error {
        case invalidSettings
        case invalidBackup
    }

    static func install(
        in settingsData: Data?,
        command: String,
        preserving backup: ClaudeCodeBridgeConfiguration? = nil
    ) throws -> Installation {
        var root = try settingsRoot(from: settingsData)

        let hadOriginal: Bool
        let originalData: Data?
        if let backup {
            hadOriginal = backup.hadOriginalStatusLine
            originalData = backup.originalStatusLineData
        } else {
            hadOriginal = root.keys.contains("statusLine")
            originalData = try root["statusLine"].map(serializedFragment)
        }

        var refreshInterval = 5
        if let sourceData = originalData,
           let original = try? JSONSerialization.jsonObject(with: sourceData) as? [String: Any],
           let storedInterval = original["refreshInterval"] as? NSNumber {
            refreshInterval = max(1, storedInterval.intValue)
        }

        root["statusLine"] = [
            "type": "command",
            "command": command,
            "refreshInterval": refreshInterval
        ]

        return Installation(
            settingsData: try serializedRoot(root),
            hadOriginalStatusLine: hadOriginal,
            originalStatusLineData: originalData
        )
    }

    static func restore(
        in settingsData: Data?,
        from backup: ClaudeCodeBridgeConfiguration
    ) throws -> Data {
        var root = try settingsRoot(from: settingsData)
        if backup.hadOriginalStatusLine {
            guard let originalData = backup.originalStatusLineData else {
                throw EditingError.invalidBackup
            }
            root["statusLine"] = try JSONSerialization.jsonObject(
                with: originalData,
                options: [.fragmentsAllowed]
            )
        } else {
            root.removeValue(forKey: "statusLine")
        }
        return try serializedRoot(root)
    }

    static func statusLineCommand(in settingsData: Data?) -> String? {
        guard let root = try? settingsRoot(from: settingsData),
              let statusLine = root["statusLine"] as? [String: Any],
              statusLine["type"] as? String == "command" else {
            return nil
        }
        return statusLine["command"] as? String
    }

    static func statusLineMatchesBackup(
        in settingsData: Data?,
        backup: ClaudeCodeBridgeConfiguration
    ) -> Bool {
        guard let root = try? settingsRoot(from: settingsData) else { return false }
        if !backup.hadOriginalStatusLine {
            return !root.keys.contains("statusLine")
        }
        guard let originalData = backup.originalStatusLineData,
              let original = try? JSONSerialization.jsonObject(
                with: originalData,
                options: [.fragmentsAllowed]
              ),
              let current = root["statusLine"] else {
            return false
        }
        return (current as AnyObject).isEqual(original)
    }

    private static func settingsRoot(from data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EditingError.invalidSettings
        }
        return root
    }

    private static func serializedFragment(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
    }

    private static func serializedRoot(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
}

private enum ClaudeCodeBridgeManagerError: Error {
    case claudeCodeMissing
    case invalidSettings
    case configurationConflict
    case missingExecutable
    case writeFailed

    var message: String {
        switch self {
        case .claudeCodeMissing:
            "Claude Code is not installed. Install it before connecting the bridge."
        case .invalidSettings:
            "Claude Code's settings file is not valid JSON, so it was left unchanged."
        case .configurationConflict:
            "Claude's status-line setting changed after the bridge was connected. It was left untouched."
        case .missingExecutable:
            "The app executable could not be found."
        case .writeFailed:
            "The Claude Code bridge could not be saved."
        }
    }
}

struct ClaudeCodeBridgeManager: Sendable {
    func inspect() async -> ClaudeCodeBridgeStatus {
        await Task.detached(priority: .utility) {
            Self.inspectSynchronously()
        }.value
    }

    func install(appExecutableURL: URL?) async -> ClaudeCodeBridgeStatus {
        await Task.detached(priority: .userInitiated) {
            Self.installSynchronously(appExecutableURL: appExecutableURL)
        }.value
    }

    func disconnect() async -> ClaudeCodeBridgeStatus {
        await Task.detached(priority: .userInitiated) {
            Self.disconnectSynchronously()
        }.value
    }

    func forgetInactiveConfiguration() async -> ClaudeCodeBridgeStatus {
        await Task.detached(priority: .userInitiated) {
            guard !Self.isBridgeActivelyConfigured() else {
                return Self.inspectSynchronously()
            }
            try? FileManager.default.removeItem(at: ClaudeUsagePaths.bridgeConfigurationURL)
            try? FileManager.default.removeItem(at: ClaudeUsagePaths.statusLineCacheURL)
            return Self.inspectSynchronously()
        }.value
    }

    static func isClaudeCodeInstalled() -> Bool {
        claudeExecutableURL() != nil
    }

    static func isBridgeActivelyConfigured() -> Bool {
        guard let configuration = loadConfiguration(),
              let settingsData = try? Data(contentsOf: ClaudeUsagePaths.claudeSettingsURL) else {
            return false
        }
        return ClaudeCodeSettingsEditor.statusLineCommand(in: settingsData)
            == configuration.installedCommand
    }

    private static func inspectSynchronously() -> ClaudeCodeBridgeStatus {
        let executable = claudeExecutableURL()
        let version = executable.flatMap(claudeVersion)
        let configuration = loadConfiguration()
        let settingsData = try? Data(contentsOf: ClaudeUsagePaths.claudeSettingsURL)
        let currentCommand = ClaudeCodeSettingsEditor.statusLineCommand(in: settingsData)

        if let configuration {
            guard currentCommand == configuration.installedCommand else {
                return ClaudeCodeBridgeStatus(
                    state: .conflict,
                    version: version,
                    message: ClaudeCodeBridgeManagerError.configurationConflict.message
                )
            }

            let expectedCommand = bridgeCommand(for: Bundle.main.executableURL)
            if let expectedCommand, expectedCommand != configuration.installedCommand {
                return ClaudeCodeBridgeStatus(
                    state: .needsRepair,
                    version: version,
                    message: "Reconnect the bridge to update the app's location."
                )
            }

            let hasUsage: Bool
            if let data = try? Data(contentsOf: ClaudeUsagePaths.statusLineCacheURL),
               let cache = try? JSONDecoder().decode(ClaudeStatusLineUsageCache.self, from: data) {
                hasUsage = cache.isUsable()
            } else {
                hasUsage = false
            }
            return ClaudeCodeBridgeStatus(
                state: hasUsage ? .connected : .connectedWaiting,
                version: version,
                message: hasUsage
                    ? nil
                    : "Complete a response in a trusted Claude Code workspace. If Claude asks whether you trust the folder, approve it first."
            )
        }

        if let currentCommand, currentCommand.contains(ClaudeStatusLineBridgeRunner.argument) {
            return ClaudeCodeBridgeStatus(
                state: .conflict,
                version: version,
                message: "A bridge command exists without its restore record. Claude settings were left unchanged."
            )
        }

        return ClaudeCodeBridgeStatus(
            state: executable == nil ? .notInstalled : .disconnected,
            version: version,
            message: nil
        )
    }

    private static func installSynchronously(appExecutableURL: URL?) -> ClaudeCodeBridgeStatus {
        guard claudeExecutableURL() != nil else {
            return failureStatus(.claudeCodeMissing)
        }
        guard let command = bridgeCommand(for: appExecutableURL) else {
            return failureStatus(.missingExecutable)
        }

        let fileManager = FileManager.default
        let settingsURL = ClaudeUsagePaths.claudeSettingsURL
        let existingConfiguration = loadConfiguration()
        let settingsData = try? Data(contentsOf: settingsURL)

        if let existingConfiguration {
            let currentCommand = ClaudeCodeSettingsEditor.statusLineCommand(in: settingsData)
            let isInterruptedInstallation = ClaudeCodeSettingsEditor.statusLineMatchesBackup(
                in: settingsData,
                backup: existingConfiguration
            )
            if currentCommand != existingConfiguration.installedCommand,
               !isInterruptedInstallation {
                return failureStatus(.configurationConflict)
            }
        }

        do {
            let installation = try ClaudeCodeSettingsEditor.install(
                in: settingsData,
                command: command,
                preserving: existingConfiguration
            )
            let configuration = ClaudeCodeBridgeConfiguration(
                schemaVersion: ClaudeCodeBridgeConfiguration.currentSchemaVersion,
                settingsPath: settingsURL.path,
                installedCommand: command,
                hadOriginalStatusLine: installation.hadOriginalStatusLine,
                originalStatusLineData: installation.originalStatusLineData,
                installedAt: existingConfiguration?.installedAt ?? .now
            )

            try fileManager.createDirectory(
                at: ClaudeUsagePaths.supportDirectory,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: settingsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try writePrivate(
                JSONEncoder().encode(configuration),
                to: ClaudeUsagePaths.bridgeConfigurationURL
            )
            do {
                try installation.settingsData.write(to: settingsURL, options: .atomic)
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: settingsURL.path
                )
            } catch {
                if existingConfiguration == nil {
                    try? fileManager.removeItem(at: ClaudeUsagePaths.bridgeConfigurationURL)
                }
                throw error
            }
        } catch ClaudeCodeSettingsEditor.EditingError.invalidSettings {
            return failureStatus(.invalidSettings)
        } catch {
            return failureStatus(.writeFailed)
        }

        return inspectSynchronously()
    }

    private static func disconnectSynchronously() -> ClaudeCodeBridgeStatus {
        guard let configuration = loadConfiguration() else {
            return inspectSynchronously()
        }

        let settingsURL = URL(fileURLWithPath: configuration.settingsPath)
        let settingsData = try? Data(contentsOf: settingsURL)
        guard ClaudeCodeSettingsEditor.statusLineCommand(in: settingsData) == configuration.installedCommand else {
            return failureStatus(.configurationConflict, state: .conflict)
        }

        do {
            let restored = try ClaudeCodeSettingsEditor.restore(
                in: settingsData,
                from: configuration
            )
            try restored.write(to: settingsURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: settingsURL.path
            )
            try? FileManager.default.removeItem(at: ClaudeUsagePaths.bridgeConfigurationURL)
            try? FileManager.default.removeItem(at: ClaudeUsagePaths.statusLineCacheURL)
        } catch ClaudeCodeSettingsEditor.EditingError.invalidSettings {
            return failureStatus(.invalidSettings)
        } catch {
            return failureStatus(.writeFailed)
        }

        return inspectSynchronously()
    }

    private static func loadConfiguration() -> ClaudeCodeBridgeConfiguration? {
        guard let data = try? Data(contentsOf: ClaudeUsagePaths.bridgeConfigurationURL),
              let configuration = try? JSONDecoder().decode(ClaudeCodeBridgeConfiguration.self, from: data),
              configuration.schemaVersion == ClaudeCodeBridgeConfiguration.currentSchemaVersion,
              URL(fileURLWithPath: configuration.settingsPath).standardizedFileURL
                == ClaudeUsagePaths.claudeSettingsURL.standardizedFileURL else {
            return nil
        }
        return configuration
    }

    private static func bridgeCommand(for executableURL: URL?) -> String? {
        guard let path = executableURL?.path, !path.isEmpty else { return nil }
        return shellQuote(path) + " " + ClaudeStatusLineBridgeRunner.argument
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func claudeExecutableURL() -> URL? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        return executableCandidates(homeDirectory: home).lazy
            .filter { fileManager.isExecutableFile(atPath: $0.path) }
            .first
    }

    /// Claude's native installer places its self-updating executable in the
    /// user's home directory. Prefer it over package-manager copies, which can
    /// remain installed at an older version and do not match the CLI the user
    /// gets from their normal shell.
    static func executableCandidates(homeDirectory: URL) -> [URL] {
        [
            homeDirectory.appendingPathComponent(".local/bin/claude"),
            homeDirectory.appendingPathComponent(".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude")
        ]
    }

    private static func claudeVersion(at executableURL: URL) -> String? {
        let process = Process()
        let outputCapture = BoundedPipeCapture(maximumBytes: 64_000)
        process.executableURL = executableURL
        process.arguments = ["--version"]
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
                deadline: .now() + 3,
                execute: timeout
            )
            process.waitUntilExit()
            timeout.cancel()
            let output = outputCapture.finish()
            guard process.terminationStatus == 0,
                  !output.didExceedLimit else { return nil }
            return String(data: output.data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            outputCapture.closeParentWriter()
            process.terminateAndForceIfNeeded()
            return nil
        }
    }

    private static func failureStatus(
        _ error: ClaudeCodeBridgeManagerError,
        state: ClaudeCodeBridgeConnectionState = .failed
    ) -> ClaudeCodeBridgeStatus {
        ClaudeCodeBridgeStatus(
            state: state,
            version: claudeExecutableURL().flatMap(claudeVersion),
            message: error.message
        )
    }

    private static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

enum ClaudeStatusLineBridgeRunner {
    static let argument = "--claude-status-line-bridge"
    static let maximumInputBytes = 2_000_000

    static var isBridgeInvocation: Bool {
        ProcessInfo.processInfo.arguments.contains(argument)
    }

    @discardableResult
    static func run() -> Int32 {
        guard let input = BoundedInputReader.read(
            from: .standardInput,
            maximumBytes: maximumInputBytes
        ) else {
            return 0
        }
        let existing = loadCache()
        let activityDate = transcriptModificationDate(in: input) ?? .now

        if var parsed = ClaudeStatusLinePayloadParser.parse(input, updatedAt: activityDate) {
            if let existing,
               existing.usedPercent == parsed.usedPercent,
               existing.resetDate == parsed.resetDate,
               activityDate <= existing.updatedAt {
                parsed = ClaudeStatusLineUsageCache(
                    schemaVersion: parsed.schemaVersion,
                    usedPercent: parsed.usedPercent,
                    resetDate: parsed.resetDate,
                    updatedAt: existing.updatedAt,
                    claudeVersion: parsed.claudeVersion ?? existing.claudeVersion
                )
            }
            persist(parsed)
        }

        proxyOriginalStatusLine(input: input)
        return 0
    }

    private static func loadCache() -> ClaudeStatusLineUsageCache? {
        guard let data = try? Data(contentsOf: ClaudeUsagePaths.statusLineCacheURL) else {
            return nil
        }
        return try? JSONDecoder().decode(ClaudeStatusLineUsageCache.self, from: data)
    }

    private static func persist(_ cache: ClaudeStatusLineUsageCache) {
        do {
            try FileManager.default.createDirectory(
                at: ClaudeUsagePaths.supportDirectory,
                withIntermediateDirectories: true
            )
            let url = ClaudeUsagePaths.statusLineCacheURL
            try JSONEncoder().encode(cache).write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            // Status-line integrations must never interrupt Claude Code's UI.
        }
    }

    private static func transcriptModificationDate(in input: Data) -> Date? {
        guard let root = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              let path = root["transcript_path"] as? String,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attributes[.modificationDate] as? Date,
              date <= Date.now.addingTimeInterval(5 * 60) else {
            return nil
        }
        return date
    }

    private static func proxyOriginalStatusLine(input: Data) {
        guard let configurationData = try? Data(contentsOf: ClaudeUsagePaths.bridgeConfigurationURL),
              let configuration = try? JSONDecoder().decode(
                ClaudeCodeBridgeConfiguration.self,
                from: configurationData
              ),
              let command = configuration.originalCommand else {
            return
        }

        let process = Process()
        let stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.standardInput = stdin
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
            let timeout = DispatchWorkItem { [weak process] in
                guard let process, process.isRunning else { return }
                process.terminateAndForceIfNeeded()
            }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + 5,
                execute: timeout
            )
            process.waitUntilExit()
            timeout.cancel()
        } catch {
            process.terminateAndForceIfNeeded()
        }
    }
}

enum BoundedInputReader {
    static func read(from handle: FileHandle, maximumBytes: Int) -> Data? {
        guard maximumBytes >= 0 else { return nil }
        var result = Data()

        while result.count <= maximumBytes {
            let remaining = maximumBytes + 1 - result.count
            let readSize = min(64 * 1_024, remaining)
            let chunk: Data
            do {
                guard let next = try handle.read(upToCount: readSize) else { return result }
                chunk = next
            } catch {
                return nil
            }

            guard !chunk.isEmpty else { return result }
            result.append(chunk)
        }

        return nil
    }
}
