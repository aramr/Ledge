import Foundation

enum ClaudeDesktopUsageHistoryParser {
    private static let weeklyKeys = ["sd", "so", "sn", "oa", "cw", "om", "op"]

    static func parse(
        _ data: Data,
        now: Date = .now,
        maximumAge: TimeInterval = 30 * 60
    ) -> ClaudeUsageSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = root["samples"] as? [[String: Any]] else {
            return nil
        }

        for sample in samples.reversed() {
            guard let timestamp = number(sample["t"]),
                  let utilization = sample["u"] as? [String: Any],
                  let usedPercent = weeklyUtilization(in: utilization) else {
                continue
            }

            let updatedAt = Date(
                timeIntervalSince1970: timestamp > 10_000_000_000
                    ? timestamp / 1_000
                    : timestamp
            )
            let age = now.timeIntervalSince(updatedAt)
            guard age >= -5 * 60, age <= maximumAge else { continue }

            return ClaudeUsageSnapshot(
                usedPercent: min(max(usedPercent, 0), 100),
                resetDate: nil,
                updatedAt: updatedAt,
                windowDurationMinutes: 7 * 24 * 60,
                planType: "Desktop"
            )
        }

        return nil
    }

    private static func weeklyUtilization(in utilization: [String: Any]) -> Double? {
        if let combined = number(utilization["sd"]) {
            return combined
        }

        return weeklyKeys.dropFirst()
            .compactMap { number(utilization[$0]) }
            .max()
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: number.doubleValue
        case let string as String: Double(string)
        default: nil
        }
    }
}

enum ClaudeDesktopConnectionState: Equatable, Sendable {
    case checking
    case notInstalled
    case installed
    case available
}

enum ClaudeConnectionRecommendation: Equatable, Sendable {
    case useDesktop
    case useExistingBridge
    case connectClaudeCode
    case openDesktop
    case installClaude
}

enum ClaudeConnectionPlanner {
    static func recommendation(
        hasFreshDesktopUsage: Bool,
        isBridgeActive: Bool,
        isClaudeCodeInstalled: Bool,
        isClaudeDesktopInstalled: Bool
    ) -> ClaudeConnectionRecommendation {
        if hasFreshDesktopUsage { return .useDesktop }
        if isBridgeActive { return .useExistingBridge }
        if isClaudeCodeInstalled { return .connectClaudeCode }
        if isClaudeDesktopInstalled { return .openDesktop }
        return .installClaude
    }
}

private enum ClaudeUsageClientError: Error, Sendable {
    case notInstalled
    case bridgeNotConnected
    case waitingForStatusLine
    case desktopHistoryUnavailable

    var userMessage: String {
        switch self {
        case .notInstalled:
            "Install Claude Code or Claude Desktop to show Claude usage."
        case .bridgeNotConnected:
            "Claude Code is available but is not connected to Ledge."
        case .waitingForStatusLine:
            "Complete a response in a trusted Claude Code workspace. If Claude asks whether you trust the folder, approve it first."
        case .desktopHistoryUnavailable:
            "Open Claude Desktop and complete sign-in, then check again."
        }
    }

    var connectionState: AgentConnectionState {
        switch self {
        case .notInstalled: .notInstalled
        case .bridgeNotConnected, .desktopHistoryUnavailable: .signInRequired
        case .waitingForStatusLine: .connected
        }
    }
}

private struct ClaudeUsageClient: Sendable {
    func fetch(now: Date = .now) -> Result<ClaudeUsageSnapshot, ClaudeUsageClientError> {
        if ClaudeCodeBridgeManager.isBridgeActivelyConfigured(),
           let data = try? Data(contentsOf: ClaudeUsagePaths.statusLineCacheURL),
           let cache = try? JSONDecoder().decode(ClaudeStatusLineUsageCache.self, from: data),
           cache.isUsable(at: now) {
            return .success(cache.snapshot)
        }

        if let snapshot = desktopSnapshot(now: now) {
            return .success(snapshot)
        }

        if ClaudeCodeBridgeManager.isBridgeActivelyConfigured() {
            return .failure(.waitingForStatusLine)
        }
        if ClaudeCodeBridgeManager.isClaudeCodeInstalled() {
            return .failure(.bridgeNotConnected)
        }
        if Self.isClaudeDesktopInstalled() {
            return .failure(.desktopHistoryUnavailable)
        }
        return .failure(.notInstalled)
    }

    func desktopSnapshot(now: Date = .now) -> ClaudeUsageSnapshot? {
        guard let data = try? Data(contentsOf: ClaudeUsagePaths.desktopHistoryURL) else {
            return nil
        }
        return ClaudeDesktopUsageHistoryParser.parse(data, now: now)
    }

    static func isClaudeDesktopInstalled() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            "/Applications/Claude.app",
            home.appendingPathComponent("Applications/Claude.app").path
        ].contains { FileManager.default.fileExists(atPath: $0) }
    }
}

@MainActor
final class ClaudeUsageService {
    private static let minimumUserRefreshDuration = Duration.milliseconds(450)

    private enum Key {
        static let snapshot = "claudeUsageSnapshot.v2"
        static let integrationEnabled = "claudeIntegrationEnabled.v1"
    }

    private let client = ClaudeUsageClient()
    private let bridgeManager = ClaudeCodeBridgeManager()
    private let defaults: UserDefaults
    private var pollingTask: Task<Void, Never>?
    private var manualRefreshTask: Task<Void, Never>?
    private var bridgeOperationTask: Task<Void, Never>?

    private(set) var snapshot: ClaudeUsageSnapshot?
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?
    private(set) var connectionState: AgentConnectionState = .checking
    private(set) var bridgeStatus: ClaudeCodeBridgeStatus = .checking
    private(set) var desktopConnectionState: ClaudeDesktopConnectionState = .checking
    private(set) var isIntegrationEnabled: Bool

    var onStateChange: ((ClaudeUsageSnapshot?, Bool, String?, AgentConnectionState) -> Void)?
    var onBridgeStatusChange: ((ClaudeCodeBridgeStatus) -> Void)?
    var onIntegrationChange: ((Bool, ClaudeDesktopConnectionState) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Remove quota snapshots written by earlier prototypes. Connection
        // preferences remain, but usage values are now session-only.
        defaults.removeObject(forKey: Key.snapshot)
        let bridgeWasAlreadyConnected = ClaudeCodeBridgeManager.isBridgeActivelyConfigured()
        isIntegrationEnabled = defaults.bool(forKey: Key.integrationEnabled)
            || bridgeWasAlreadyConnected
        if bridgeWasAlreadyConnected {
            defaults.set(true, forKey: Key.integrationEnabled)
        }
    }

    var connectionRecommendation: ClaudeConnectionRecommendation {
        let freshDesktopUsage = client.desktopSnapshot() != nil
        if freshDesktopUsage {
            desktopConnectionState = .available
            publishIntegration()
        }
        return ClaudeConnectionPlanner.recommendation(
            hasFreshDesktopUsage: freshDesktopUsage,
            isBridgeActive: ClaudeCodeBridgeManager.isBridgeActivelyConfigured(),
            isClaudeCodeInstalled: ClaudeCodeBridgeManager.isClaudeCodeInstalled(),
            isClaudeDesktopInstalled: ClaudeUsageClient.isClaudeDesktopInstalled()
        )
    }

    func start() {
        guard pollingTask == nil else { return }
        refreshDesktopInstallationState()
        if !isIntegrationEnabled {
            updateDisconnectedState()
        }
        publish()
        publishBridgeStatus()
        publishIntegration()

        pollingTask = Task { [weak self] in
            guard let self else { return }
            await refreshBridgeStatus()
            if isIntegrationEnabled {
                await refresh(showActivity: false)
            }

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    return
                }
                guard isIntegrationEnabled else { continue }
                await refresh(showActivity: false)
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        manualRefreshTask?.cancel()
        manualRefreshTask = nil
        bridgeOperationTask?.cancel()
        bridgeOperationTask = nil
        isRefreshing = false
        snapshot = nil
        errorMessage = nil
        connectionState = isIntegrationEnabled ? .checking : .signInRequired
        bridgeStatus = .checking
        desktopConnectionState = .checking
        publish()
        publishBridgeStatus()
        publishIntegration()
    }

    func refreshNow() {
        guard isIntegrationEnabled,
              !isRefreshing,
              manualRefreshTask == nil else {
            if !isIntegrationEnabled {
                refreshDesktopInstallationState()
                updateDisconnectedState()
                publish()
                publishIntegration()
            }
            return
        }
        manualRefreshTask = Task { [weak self] in
            guard let self else { return }
            await performUserInitiatedRefresh()
            manualRefreshTask = nil
        }
    }

    func enableUsingAvailableSource() {
        setIntegrationEnabled(true)
        manualRefreshTask?.cancel()
        manualRefreshTask = Task { [weak self] in
            guard let self else { return }
            await performUserInitiatedRefresh()
            manualRefreshTask = nil
        }
    }

    func enableAndWaitForDesktop() {
        setIntegrationEnabled(true)
        connectionState = .signInRequired
        errorMessage = ClaudeUsageClientError.desktopHistoryUnavailable.userMessage
        publish()
    }

    func connectClaudeCodeBridge() {
        guard bridgeOperationTask == nil else { return }
        setIntegrationEnabled(true)
        bridgeStatus = ClaudeCodeBridgeStatus(
            state: .working,
            version: bridgeStatus.version,
            message: "Connecting Claude Code…"
        )
        publishBridgeStatus()

        bridgeOperationTask = Task { [weak self] in
            guard let self else { return }
            bridgeStatus = await bridgeManager.install(appExecutableURL: Bundle.main.executableURL)
            publishBridgeStatus()
            await refresh(showActivity: false)
            bridgeOperationTask = nil
        }
    }

    func repairClaudeCodeBridge() {
        connectClaudeCodeBridge()
    }

    func disconnectClaudeCodeBridge() {
        disconnectClaude()
    }

    func disconnectClaude() {
        guard bridgeOperationTask == nil else { return }

        if bridgeStatus.state == .conflict,
           !ClaudeCodeBridgeManager.isBridgeActivelyConfigured() {
            bridgeOperationTask = Task { [weak self] in
                guard let self else { return }
                bridgeStatus = await bridgeManager.forgetInactiveConfiguration()
                publishBridgeStatus()
                disableIntegration()
                bridgeOperationTask = nil
            }
            return
        }

        if bridgeStatus.isConnected || ClaudeCodeBridgeManager.isBridgeActivelyConfigured() {
            bridgeStatus = ClaudeCodeBridgeStatus(
                state: .working,
                version: bridgeStatus.version,
                message: "Restoring Claude Code settings…"
            )
            publishBridgeStatus()
            bridgeOperationTask = Task { [weak self] in
                guard let self else { return }
                bridgeStatus = await bridgeManager.disconnect()
                publishBridgeStatus()
                if bridgeStatus.state != .conflict && bridgeStatus.state != .failed {
                    disableIntegration()
                }
                bridgeOperationTask = nil
            }
        } else {
            disableIntegration()
        }
    }

    private func disableIntegration() {
        setIntegrationEnabled(false)
        snapshot = nil
        errorMessage = nil
        defaults.removeObject(forKey: Key.snapshot)
        refreshDesktopInstallationState()
        updateDisconnectedState()
        publish()
    }

    private func setIntegrationEnabled(_ enabled: Bool) {
        isIntegrationEnabled = enabled
        defaults.set(enabled, forKey: Key.integrationEnabled)
        publishIntegration()
    }

    private func refresh(showActivity: Bool) async {
        guard isIntegrationEnabled, !isRefreshing else { return }
        if showActivity {
            isRefreshing = true
            errorMessage = nil
            publish()
        }

        apply(client.fetch())

        isRefreshing = false
        publish()
    }

    /// Claude usage is read from a local bridge cache, so a successful refresh
    /// can otherwise begin and end within one SwiftUI update cycle. Cover the
    /// bridge inspection too and keep feedback visible just long enough for a
    /// deliberate button press or provider selection to feel acknowledged.
    private func performUserInitiatedRefresh() async {
        guard isIntegrationEnabled, !isRefreshing else { return }

        let clock = ContinuousClock()
        let startedAt = clock.now
        isRefreshing = true
        errorMessage = nil
        publish()
        defer {
            isRefreshing = false
            publish()
        }

        await refreshBridgeStatus()
        guard !Task.isCancelled else { return }
        apply(client.fetch())

        let elapsed = startedAt.duration(to: clock.now)
        if elapsed < Self.minimumUserRefreshDuration {
            try? await Task.sleep(for: Self.minimumUserRefreshDuration - elapsed)
        }

        guard !Task.isCancelled else { return }
    }

    private func apply(
        _ result: Result<ClaudeUsageSnapshot, ClaudeUsageClientError>
    ) {
        switch result {
        case .success(let next):
            snapshot = next
            errorMessage = nil
            connectionState = .connected
            if next.planType == "Desktop" {
                desktopConnectionState = .available
                publishIntegration()
            }
            if next.planType == "Claude Code",
               bridgeStatus.state == .connectedWaiting {
                bridgeStatus = ClaudeCodeBridgeStatus(
                    state: .connected,
                    version: bridgeStatus.version,
                    message: nil
                )
                publishBridgeStatus()
            }
        case .failure(let error):
            errorMessage = error.userMessage
            connectionState = error.connectionState
        }
    }

    private func refreshBridgeStatus() async {
        guard bridgeOperationTask == nil else { return }
        bridgeStatus = await bridgeManager.inspect()
        publishBridgeStatus()
    }

    private func refreshDesktopInstallationState() {
        desktopConnectionState = ClaudeUsageClient.isClaudeDesktopInstalled()
            ? .installed
            : .notInstalled
    }

    private func updateDisconnectedState() {
        guard !isIntegrationEnabled else { return }
        snapshot = nil
        errorMessage = nil
        let hasAnyClaude = ClaudeCodeBridgeManager.isClaudeCodeInstalled()
            || ClaudeUsageClient.isClaudeDesktopInstalled()
        connectionState = hasAnyClaude ? .signInRequired : .notInstalled
    }

    private func publish() {
        onStateChange?(snapshot, isRefreshing, errorMessage, connectionState)
    }

    private func publishBridgeStatus() {
        onBridgeStatusChange?(bridgeStatus)
    }

    private func publishIntegration() {
        onIntegrationChange?(isIntegrationEnabled, desktopConnectionState)
    }
}
