import Foundation

enum CodexUsagePayloadParser {
    static func parse(_ data: Data, updatedAt: Date = .now) -> CodexUsageSnapshot? {
        let lines = data.split(separator: 0x0A)

        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  requestID(in: object) == 1,
                  let result = object["result"] as? [String: Any],
                  let limits = codexLimits(in: result),
                  let window = weeklyWindow(in: limits),
                  let usedPercent = number(window["usedPercent"]),
                  let resetTimestamp = number(window["resetsAt"]),
                  let duration = number(window["windowDurationMins"]) else {
                continue
            }

            return CodexUsageSnapshot(
                usedPercent: min(max(usedPercent, 0), 100),
                resetDate: Date(timeIntervalSince1970: resetTimestamp),
                updatedAt: updatedAt,
                windowDurationMinutes: Int(duration),
                planType: limits["planType"] as? String
            )
        }

        return nil
    }

    private static func requestID(in object: [String: Any]) -> Int? {
        if let value = object["id"] as? Int { return value }
        return (object["id"] as? NSNumber)?.intValue
    }

    private static func codexLimits(in result: [String: Any]) -> [String: Any]? {
        if let buckets = result["rateLimitsByLimitId"] as? [String: Any],
           let codex = buckets["codex"] as? [String: Any] {
            return codex
        }
        return result["rateLimits"] as? [String: Any]
    }

    private static func weeklyWindow(in limits: [String: Any]) -> [String: Any]? {
        let windows = ["primary", "secondary"].compactMap { limits[$0] as? [String: Any] }
        if let exactWeek = windows.first(where: {
            number($0["windowDurationMins"]).map(Int.init) == 7 * 24 * 60
        }) {
            return exactWeek
        }

        return windows.max { left, right in
            (number(left["windowDurationMins"]) ?? 0)
                < (number(right["windowDurationMins"]) ?? 0)
        }
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            number.doubleValue
        case let string as String:
            Double(string)
        default:
            nil
        }
    }
}

private enum CodexUsageClientError: Error, Sendable {
    case executableMissing
    case launchFailed(String)
    case noUsageResponse(String)

    var userMessage: String {
        switch self {
        case .executableMissing:
            "Codex could not be found on this Mac."
        case .launchFailed:
            "Codex usage could not be requested."
        case .noUsageResponse:
            "Sign in to Codex to view your usage."
        }
    }

    var connectionState: AgentConnectionState {
        switch self {
        case .executableMissing: .notInstalled
        case .noUsageResponse: .signInRequired
        case .launchFailed: .unavailable
        }
    }
}

private struct CodexUsageClient: Sendable {
    let executableURL: URL?

    init(executableURL: URL? = nil) {
        self.executableURL = executableURL ?? Self.resolveExecutableURL()
    }

    var isAvailable: Bool { executableURL != nil }

    func fetch() async -> Result<CodexUsageSnapshot, CodexUsageClientError> {
        guard let executableURL else { return .failure(.executableMissing) }

        return await Task.detached(priority: .utility) {
            Self.performFetch(executableURL: executableURL)
        }.value
    }

    private static func performFetch(
        executableURL: URL
    ) -> Result<CodexUsageSnapshot, CodexUsageClientError> {
        let process = Process()
        let inputPipe = Pipe()
        let outputCapture = BoundedPipeCapture(maximumBytes: 5_000_000)
        let errorCapture = BoundedPipeCapture(maximumBytes: 64_000)

        process.executableURL = executableURL
        process.arguments = ["app-server"]
        process.standardInput = inputPipe
        process.standardOutput = outputCapture.pipe
        process.standardError = errorCapture.pipe
        outputCapture.start()
        errorCapture.start()

        do {
            try process.run()
            outputCapture.closeParentWriter()
            errorCapture.closeParentWriter()
        } catch {
            outputCapture.closeParentWriter()
            errorCapture.closeParentWriter()
            return .failure(.launchFailed(error.localizedDescription))
        }

        let request = """
        {"method":"initialize","id":0,"params":{"clientInfo":{"name":"ledge","title":"Ledge","version":"0.1.0"}}}
        {"method":"initialized","params":{}}
        {"method":"account/rateLimits/read","id":1}

        """

        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: Data(request.utf8))
        } catch {
            process.terminateAndForceIfNeeded()
            return .failure(.launchFailed(error.localizedDescription))
        }

        // The request is asynchronous inside app-server. Keep stdin open long
        // enough for the account response, then close it so this lightweight
        // polling process exits cleanly without retaining another Codex host.
        Thread.sleep(forTimeInterval: 1.5)
        try? inputPipe.fileHandleForWriting.close()

        let deadline = Date.now.addingTimeInterval(3)
        while process.isRunning, Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminateAndForceIfNeeded()
        }
        process.waitUntilExit()

        let output = outputCapture.finish()
        if !output.didExceedLimit,
           let snapshot = CodexUsagePayloadParser.parse(output.data) {
            return .success(snapshot)
        }

        let errorOutput = errorCapture.finish()
        let detail = String(data: errorOutput.data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .failure(.noUsageResponse(detail))
    }

    private static func resolveExecutableURL() -> URL? {
        var candidates = [String]()

        let home = FileManager.default.homeDirectoryForCurrentUser
        candidates.append(contentsOf: [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            home.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex").path,
            home.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex").path,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            home.appendingPathComponent(".local/bin/codex").path
        ])

        return candidates.lazy
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
            .map(URL.init(fileURLWithPath:))
            .first
    }
}

final class BoundedPipeCapture: @unchecked Sendable {
    let pipe = Pipe()

    private let maximumBytes: Int
    private let lock = NSLock()
    private let completion = DispatchGroup()
    private var storage = Data()
    private var didExceedLimit = false
    private var hasStarted = false

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        completion.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { completion.leave() }
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                guard !chunk.isEmpty else { return }
                append(chunk)
            }
        }
    }

    func closeParentWriter() {
        try? pipe.fileHandleForWriting.close()
    }

    func finish() -> (data: Data, didExceedLimit: Bool) {
        if completion.wait(timeout: .now() + 1) == .timedOut {
            try? pipe.fileHandleForReading.close()
            _ = completion.wait(timeout: .now() + 1)
        }

        lock.lock()
        defer { lock.unlock() }
        return (storage, didExceedLimit)
    }

    private func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }

        let remaining = max(0, maximumBytes - storage.count)
        if chunk.count > remaining {
            storage.append(chunk.prefix(remaining))
            didExceedLimit = true
        } else {
            storage.append(chunk)
        }
    }
}

@MainActor
final class CodexUsageService {
    private let client: CodexUsageClient
    private let legacyDefaultsKey = "codexUsageSnapshot.v1"
    private var pollingTask: Task<Void, Never>?
    private var manualRefreshTask: Task<Void, Never>?

    private(set) var snapshot: CodexUsageSnapshot?
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?
    private(set) var connectionState: AgentConnectionState

    var onStateChange: ((CodexUsageSnapshot?, Bool, String?, AgentConnectionState) -> Void)?

    init(executableURL: URL? = nil) {
        client = CodexUsageClient(executableURL: executableURL)
        connectionState = client.isAvailable ? .checking : .notInstalled
        // Usage metadata is private and does not need to survive a launch.
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
    }

    func start() {
        guard pollingTask == nil else { return }
        publish()

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        manualRefreshTask?.cancel()
        manualRefreshTask = nil
        isRefreshing = false
        snapshot = nil
        errorMessage = nil
        connectionState = client.isAvailable ? .checking : .notInstalled
        publish()
    }

    func refreshNow() {
        guard !isRefreshing else { return }
        manualRefreshTask?.cancel()
        manualRefreshTask = Task { [weak self] in
            await self?.refresh()
            self?.manualRefreshTask = nil
        }
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        errorMessage = nil
        publish()

        switch await client.fetch() {
        case .success(let next):
            snapshot = next
            errorMessage = nil
            connectionState = .connected
        case .failure(let error):
            errorMessage = error.userMessage
            connectionState = error.connectionState
        }

        isRefreshing = false
        publish()
    }

    private func publish() {
        onStateChange?(snapshot, isRefreshing, errorMessage, connectionState)
    }
}
