import Foundation
import Observation

enum IslandPhase: Equatable {
    case idle
    case compact
    case expanded
}

@MainActor
@Observable
final class IslandModel {
    static let canvasSize = CGSize(width: 820, height: 420)
    static let homeExpandedSurfaceSize = CGSize(width: 760, height: 202)

    let settings: AppSettings
    var snapshot: MediaSessionSnapshot = .empty
    var spotifyFallbackSnapshot: MediaSessionSnapshot = .empty
    var audioLevels = Array(repeating: 0.0, count: 5)
    var hasLiveAudioLevels = false
    var frontmostBundleIdentifier: String?
    var isEnabled = true
    var isPreviewing = false
    var preventsAutomaticCollapse = false
    var isExpanded = false {
        didSet {
            if oldValue != isExpanded { onWaveformVisibilityChange?() }
        }
    }
    var usesPhysicalNotch = true
    var renderedNotchSize = CGSize(width: 184, height: 32)
    var selectedTab: IslandTab = .home {
        didSet {
            if oldValue != selectedTab { onWaveformVisibilityChange?() }
        }
    }
    var isCalendarDetailPresented = false {
        didSet {
            if oldValue != isCalendarDetailPresented { onWaveformVisibilityChange?() }
        }
    }
    var calendarAccessState: CalendarAccessState = .unknown
    var selectedCalendarDate = Calendar.current.startOfDay(for: .now)
    var displayedCalendarMonth = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
    var calendarEvents: [CalendarEventItem] = []
    var clipboardEntries: [ClipboardEntry] = []
    var selectedClipboardEntryIDs: Set<UUID> = []
    var copiedClipboardEntryID: UUID?
    var timerSelectedMinutes = 10.0
    var timerRemaining: TimeInterval = 10 * 60
    var timerEndDate: Date?
    var isTimerPaused = false
    var isTimerStartTransitioning = false
    var codexUsageSnapshot: CodexUsageSnapshot?
    var isCodexUsageRefreshing = false
    var codexUsageErrorMessage: String?
    var codexConnectionState: AgentConnectionState = .checking
    var claudeUsageSnapshot: ClaudeUsageSnapshot?
    var isClaudeUsageRefreshing = false
    var claudeUsageErrorMessage: String?
    var claudeConnectionState: AgentConnectionState = .checking
    var claudeCodeBridgeStatus: ClaudeCodeBridgeStatus = .checking
    var claudeDesktopConnectionState: ClaudeDesktopConnectionState = .checking
    var isClaudeIntegrationEnabled = false
    var selectedAgentProvider: AgentProvider = .codex
    var bluetoothConnectionEvent: BluetoothConnectionEvent?
    var isOnboardingGreetingPresented = false

    @ObservationIgnored var onCommand: ((MediaCommand) -> Void)?
    @ObservationIgnored var onSpotifyCommand: ((MediaCommand) -> Void)?
    @ObservationIgnored var onWaveformVisibilityChange: (() -> Void)?
    @ObservationIgnored var onCalendarAccessRequest: (() -> Void)?
    @ObservationIgnored var onCalendarSelectionChange: ((Date, Date) -> Void)?
    @ObservationIgnored var onClipboardCopy: (([ClipboardEntry]) -> Void)?
    @ObservationIgnored var onClipboardPreview: (([ClipboardEntry]) -> Void)?
    @ObservationIgnored var onClipboardDelete: ((Set<UUID>) -> Void)?
    @ObservationIgnored var onClipboardClearTextHistory: (() -> Void)?
    @ObservationIgnored var onTimerFinished: (() -> Void)?
    @ObservationIgnored var onCodexUsageRefresh: (() -> Void)?
    @ObservationIgnored var onCodexSetup: (() -> Void)?
    @ObservationIgnored var onClaudeUsageRefresh: (() -> Void)?
    @ObservationIgnored var onClaudeSetup: (() -> Void)?
    @ObservationIgnored var onClaudeConnect: (() -> Void)?
    @ObservationIgnored var onClaudeDisconnect: (() -> Void)?
    @ObservationIgnored var onClaudeCodeBridgeConnect: (() -> Void)?
    @ObservationIgnored var onClaudeCodeBridgeDisconnect: (() -> Void)?
    @ObservationIgnored var onOpenSettings: (() -> Void)?
    @ObservationIgnored var onOpenOnboarding: (() -> Void)?
    @ObservationIgnored var onTabSelectionChange: ((IslandTab) -> Void)?
    @ObservationIgnored var onAgenticServicesRequest: (() -> Void)?
    @ObservationIgnored var onRuntimeSettingsChange: (() -> Void)?
    @ObservationIgnored private var collapseTask: Task<Void, Never>?
    @ObservationIgnored private var clipboardCopyConfirmationTask: Task<Void, Never>?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var timerStartTransitionTask: Task<Void, Never>?
    @ObservationIgnored private var bluetoothNotificationTask: Task<Void, Never>?

    init(settings: AppSettings = AppSettings()) {
        self.settings = settings
        settings.onChange = { [weak self] in
            guard let self else { return }
            reconcileSettings()
            onRuntimeSettingsChange?()
        }
        reconcileSettings()
    }

    var visibleTabs: [IslandTab] {
        settings.visibleTabs
    }

    var enabledAgentProviders: [AgentProvider] {
        settings.enabledAgentProviders
    }

    var hasPrimaryMediaSnapshot: Bool {
        snapshot.identifier != MediaSessionSnapshot.empty.identifier
            && !snapshot.title.isEmpty
    }

    var hasMediaSession: Bool {
        guard hasPrimaryMediaSnapshot else { return false }
        if !isPreviewing,
           let source = snapshot.sourceBundleIdentifier,
           source == frontmostBundleIdentifier {
            return false
        }

        return true
    }

    var hasActiveMedia: Bool {
        if usesSpotifyFallback {
            return spotifyFallbackSnapshot.isPlaying
        }
        return hasMediaSession && snapshot.isPlaying
    }

    var hasSpotifyFallback: Bool {
        spotifyFallbackSnapshot.identifier != MediaSessionSnapshot.empty.identifier
            && !spotifyFallbackSnapshot.title.isEmpty
    }

    var hasEligibleSpotifyFallback: Bool {
        guard hasSpotifyFallback else { return false }
        guard !isPreviewing else { return false }
        guard let source = spotifyFallbackSnapshot.sourceBundleIdentifier else { return true }
        return source != frontmostBundleIdentifier
    }

    var usesSpotifyFallback: Bool {
        guard hasEligibleSpotifyFallback else { return false }

        // The fallback mirrors Spotify independently so it can survive a
        // browser taking over MediaRemote. It must not override Spotify's own
        // primary session while the mirror is one polling interval behind.
        if hasMediaSession, Self.isSpotify(snapshot) {
            return false
        }

        // When Spotify and a browser are both in the background, Spotify is
        // the more useful compact-island target. It has dedicated controls and
        // remains independently addressable even if the browser owns the
        // system-wide MediaRemote session.
        if spotifyFallbackSnapshot.isPlaying {
            return true
        }

        return !hasMediaSession || !snapshot.isPlaying
    }

    var compactMediaSnapshot: MediaSessionSnapshot {
        usesSpotifyFallback ? spotifyFallbackSnapshot : snapshot
    }

    var homeMediaUsesSpotifyFallback: Bool {
        // When compact media exists, Home follows the same priority decision.
        if hasActiveMedia {
            return usesSpotifyFallback
        }

        // Expanded Home may show the sole foreground player even though that
        // player is intentionally suppressed from the compact island.
        if hasPrimaryMediaSnapshot,
           snapshot.isPlaying || Self.isSpotify(snapshot) {
            return false
        }

        // With no active player, prefer Spotify's last-known track over a
        // paused browser or other stale system Now Playing session.
        return hasSpotifyFallback
    }

    var homeMediaSnapshot: MediaSessionSnapshot {
        homeMediaUsesSpotifyFallback ? spotifyFallbackSnapshot : snapshot
    }

    var hasHomeMedia: Bool {
        hasPrimaryMediaSnapshot || hasSpotifyFallback
    }

    var isTimerActive: Bool {
        timerEndDate != nil || isTimerPaused
    }

    var isTimerRunning: Bool {
        timerEndDate != nil && !isTimerPaused
    }

    var isShowingBluetoothConnection: Bool {
        bluetoothConnectionEvent != nil
    }

    var isShowingCompactMedia: Bool {
        phase == .compact
            && !isOnboardingGreetingPresented
            && !isShowingBluetoothConnection
            && !isTimerActive
            && hasActiveMedia
    }

    var shouldCaptureLiveWaveform: Bool {
        guard homeMediaSnapshot.isPlaying else { return false }
        if isShowingCompactMedia { return true }
        return phase == .expanded
            && selectedTab == .home
            && !isCalendarDetailPresented
            && hasHomeMedia
    }

    var showsSpotifyCompactProgress: Bool {
        let selectedSnapshot = compactMediaSnapshot
        guard isShowingCompactMedia,
              let duration = selectedSnapshot.duration,
              duration > 0 else {
            return false
        }

        return Self.isSpotify(selectedSnapshot)
    }

    private static func isSpotify(_ snapshot: MediaSessionSnapshot) -> Bool {
        let bundleIdentifier = snapshot.sourceBundleIdentifier?.lowercased()
        return bundleIdentifier?.contains("spotify") == true
            || snapshot.sourceName.caseInsensitiveCompare("Spotify") == .orderedSame
    }

    var phase: IslandPhase {
        if isOnboardingGreetingPresented { return .compact }
        if isExpanded { return .expanded }
        return isShowingBluetoothConnection || isTimerActive || hasActiveMedia ? .compact : .idle
    }

    var mediaCompactSurfaceSize: CGSize {
        CGSize(
            width: max(270, renderedNotchSize.width + 112),
            height: max(44, renderedNotchSize.height + 12)
        )
    }

    var timerCompactSurfaceSize: CGSize {
        CGSize(
            // Four extra points per side keep the widest 120-minute countdown
            // clear of the physical notch without noticeably enlarging the
            // compact timer silhouette.
            width: max(348, renderedNotchSize.width + 172),
            height: max(44, renderedNotchSize.height + 12)
        )
    }

    var bluetoothCompactSurfaceSize: CGSize {
        CGSize(
            width: max(364, renderedNotchSize.width + 180),
            height: max(72, renderedNotchSize.height + 40)
        )
    }

    var onboardingCompactSurfaceSize: CGSize {
        CGSize(
            width: max(312, renderedNotchSize.width + 128),
            height: max(132, renderedNotchSize.height + 100)
        )
    }

    var compactSurfaceSize: CGSize {
        if isOnboardingGreetingPresented { return onboardingCompactSurfaceSize }
        if isShowingBluetoothConnection { return bluetoothCompactSurfaceSize }
        return isTimerActive ? timerCompactSurfaceSize : mediaCompactSurfaceSize
    }

    // Expanded content uses this geometry even while it is hidden. Keeping its
    // layout independent from `phase` prevents every leading-aligned control
    // from travelling left as the centered silhouette grows from compact size.
    var expandedSurfaceSize: CGSize {
        if isCalendarDetailPresented {
            return CGSize(width: 760, height: 390)
        }

        switch selectedTab {
        case .home:
            return Self.homeExpandedSurfaceSize
        case .clipboard:
            return Self.homeExpandedSurfaceSize
        case .timer:
            return isTimerActive
                ? CGSize(width: 680, height: 132)
                : Self.homeExpandedSurfaceSize
        case .agentic:
            return Self.homeExpandedSurfaceSize
        }
    }

    var surfaceSize: CGSize {
        switch phase {
        case .idle:
            renderedNotchSize
        case .compact:
            compactSurfaceSize
        case .expanded:
            expandedSurfaceSize
        }
    }

    func setPointerInside(_ inside: Bool) {
        collapseTask?.cancel()

        if isOnboardingGreetingPresented {
            isExpanded = false
            return
        }

        if inside {
            guard isEnabled else { return }
            if isTimerActive {
                selectedTab = .timer
                isCalendarDetailPresented = false
            }
            isExpanded = true
            return
        }

        guard !preventsAutomaticCollapse else { return }

        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.collapse()
        }
    }

    func toggleExpanded() {
        if isOnboardingGreetingPresented {
            openOnboarding()
            return
        }
        collapseTask?.cancel()
        isExpanded.toggle()
    }

    func send(_ command: MediaCommand) {
        onCommand?(command)
    }

    func sendToSpotify(_ command: MediaCommand) {
        onSpotifyCommand?(command)
    }

    func selectTab(_ tab: IslandTab) {
        guard visibleTabs.contains(tab) else { return }
        isCalendarDetailPresented = false
        selectedTab = tab
        onTabSelectionChange?(tab)
        if tab == .agentic {
            requestAgenticServices()
            refreshSelectedAgentUsage()
        }
    }

    func refreshCodexUsage() {
        onCodexUsageRefresh?()
    }

    func refreshClaudeUsage() {
        onClaudeUsageRefresh?()
    }

    func refreshSelectedAgentUsage() {
        switch selectedAgentProvider {
        case .codex: refreshCodexUsage()
        case .claude: refreshClaudeUsage()
        }
    }

    func requestAgenticServices() {
        onAgenticServicesRequest?()
    }

    func selectAgentProvider(_ provider: AgentProvider) {
        guard enabledAgentProviders.contains(provider) else { return }
        selectedAgentProvider = provider
        refreshSelectedAgentUsage()
    }

    func setUpCodex() {
        onCodexSetup?()
    }

    func setUpClaude() {
        onClaudeSetup?()
    }

    func connectClaude() {
        onClaudeConnect?()
    }

    func disconnectClaude() {
        onClaudeDisconnect?()
    }

    func connectClaudeCodeBridge() {
        onClaudeCodeBridgeConnect?()
    }

    func disconnectClaudeCodeBridge() {
        onClaudeCodeBridgeDisconnect?()
    }

    func openSettings() {
        onOpenSettings?()
    }

    func openOnboarding() {
        onOpenOnboarding?()
    }

    func showBluetoothConnection(
        _ event: BluetoothConnectionEvent,
        displayDuration: TimeInterval? = 4
    ) {
        bluetoothNotificationTask?.cancel()
        bluetoothConnectionEvent = event

        guard let displayDuration else { return }
        bluetoothNotificationTask = Task { [weak self] in
            let milliseconds = Int64(max(0, displayDuration) * 1_000)
            try? await Task.sleep(for: .milliseconds(milliseconds))
            guard !Task.isCancelled,
                  self?.bluetoothConnectionEvent?.id == event.id else { return }
            self?.bluetoothConnectionEvent = nil
            self?.bluetoothNotificationTask = nil
        }
    }

    func dismissBluetoothConnection() {
        bluetoothNotificationTask?.cancel()
        bluetoothNotificationTask = nil
        bluetoothConnectionEvent = nil
    }

    func presentCalendarDetail() {
        selectedTab = .home
        isCalendarDetailPresented = true
    }

    func dismissCalendarDetail() {
        isCalendarDetailPresented = false
    }

    func requestCalendarAccess() {
        onCalendarAccessRequest?()
    }

    func selectCalendarDate(_ date: Date) {
        let calendar = Calendar.current
        selectedCalendarDate = calendar.startOfDay(for: date)
        displayedCalendarMonth = calendar.dateInterval(of: .month, for: date)?.start ?? date
        onCalendarSelectionChange?(selectedCalendarDate, displayedCalendarMonth)
    }

    func changeCalendarMonth(by offset: Int) {
        guard let month = Calendar.current.date(
            byAdding: .month,
            value: offset,
            to: displayedCalendarMonth
        ) else { return }

        displayedCalendarMonth = month
        selectedCalendarDate = month
        onCalendarSelectionChange?(selectedCalendarDate, displayedCalendarMonth)
    }

    func events(on date: Date) -> [CalendarEventItem] {
        calendarEvents.filter { Calendar.current.isDate($0.startDate, inSameDayAs: date) }
    }

    var screenshotClipboardEntries: [ClipboardEntry] {
        clipboardEntries.filter(\.isVisual)
    }

    var textClipboardEntries: [ClipboardEntry] {
        clipboardEntries.filter(\.isText)
    }

    var selectedClipboardEntries: [ClipboardEntry] {
        clipboardEntries.filter { selectedClipboardEntryIDs.contains($0.id) }
    }

    var selectedClipboardTextEntryIDs: Set<UUID> {
        Set(selectedClipboardEntries.filter(\.isText).map(\.id))
    }

    func selectClipboardEntry(_ entry: ClipboardEntry, extendingSelection: Bool = false) {
        if extendingSelection {
            if selectedClipboardEntryIDs.contains(entry.id) {
                selectedClipboardEntryIDs.remove(entry.id)
            } else {
                selectedClipboardEntryIDs.insert(entry.id)
            }
        } else {
            selectedClipboardEntryIDs = [entry.id]
        }
    }

    func copySelectedClipboardEntry() {
        let entries = selectedClipboardEntries
        guard !entries.isEmpty else { return }
        onClipboardCopy?(entries)
        if entries.count == 1, entries[0].isText {
            showClipboardCopyConfirmation(for: entries[0])
        }
    }

    func copyClipboardTextItem(at index: Int) {
        let entries = textClipboardEntries
        guard entries.indices.contains(index) else { return }
        let entry = entries[index]
        onClipboardCopy?([entry])
        showClipboardCopyConfirmation(for: entry)
    }

    func previewSelectedClipboardEntries() {
        let entries = selectedClipboardEntries
        guard !entries.isEmpty else { return }
        onClipboardPreview?(entries)
    }

    func deleteSelectedClipboardTextEntries() {
        let ids = selectedClipboardTextEntryIDs
        guard !ids.isEmpty else { return }

        clipboardEntries.removeAll { ids.contains($0.id) }
        selectedClipboardEntryIDs.subtract(ids)
        clearClipboardCopyConfirmation(ifIncludedIn: ids)
        onClipboardDelete?(ids)
    }

    func clearClipboardTextHistory() {
        guard !textClipboardEntries.isEmpty else { return }

        let ids = Set(textClipboardEntries.map(\.id))
        clipboardEntries.removeAll { $0.isText }
        selectedClipboardEntryIDs.subtract(ids)
        clearClipboardCopyConfirmation(ifIncludedIn: ids)
        onClipboardClearTextHistory?()
    }

    private func showClipboardCopyConfirmation(for entry: ClipboardEntry) {
        clipboardCopyConfirmationTask?.cancel()
        copiedClipboardEntryID = entry.id

        clipboardCopyConfirmationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, self?.copiedClipboardEntryID == entry.id else { return }
            self?.copiedClipboardEntryID = nil
            self?.clipboardCopyConfirmationTask = nil
        }
    }

    private func clearClipboardCopyConfirmation(ifIncludedIn ids: Set<UUID>) {
        guard let copiedClipboardEntryID, ids.contains(copiedClipboardEntryID) else { return }
        clipboardCopyConfirmationTask?.cancel()
        clipboardCopyConfirmationTask = nil
        self.copiedClipboardEntryID = nil
    }

    func setTimerMinutes(_ minutes: Double) {
        guard !isTimerActive else { return }
        timerSelectedMinutes = min(max(minutes.rounded(), 1), 120)
        timerRemaining = timerSelectedMinutes * 60
    }

    func startTimer() {
        guard !isTimerActive else { return }
        timerTask?.cancel()
        timerStartTransitionTask?.cancel()
        isTimerPaused = false
        timerRemaining = timerSelectedMinutes * 60
        timerEndDate = .now.addingTimeInterval(timerRemaining)

        if isExpanded {
            // Starting a timer is one direct expanded-to-compact transition.
            // Collapsing here avoids the old intermediate 680x132 layout and
            // the delayed pointer-driven second shrink.
            collapseTask?.cancel()
            isTimerStartTransitioning = true
            isExpanded = false
            isCalendarDetailPresented = false
            selectedClipboardEntryIDs = []

            timerStartTransitionTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(820))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.isTimerStartTransitioning = false
                self?.timerStartTransitionTask = nil
            }
        }

        startTimerTask()
    }

    func toggleTimerPause() {
        isTimerPaused ? resumeTimer() : pauseTimer()
    }

    func pauseTimer() {
        guard isTimerRunning, let timerEndDate else { return }
        timerRemaining = max(0, timerEndDate.timeIntervalSinceNow)
        // Set the paused flag first so compact priority is never dropped
        // between clearing the deadline and publishing the frozen state.
        isTimerPaused = true
        self.timerEndDate = nil
        timerTask?.cancel()
        timerTask = nil
    }

    func resumeTimer() {
        guard isTimerPaused, timerRemaining > 0 else { return }
        timerEndDate = .now.addingTimeInterval(timerRemaining)
        isTimerPaused = false
        startTimerTask()
    }

    private func startTimerTask() {
        timerTask?.cancel()

        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let endDate = self.timerEndDate else { return }
                let remaining = max(0, endDate.timeIntervalSinceNow)
                self.timerRemaining = remaining

                if remaining <= 0 {
                    self.timerEndDate = nil
                    self.isTimerPaused = false
                    self.timerTask = nil
                    if !self.isExpanded {
                        self.selectedTab = self.preferredDefaultTab
                    }
                    self.onTimerFinished?()
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func cancelTimer() {
        timerStartTransitionTask?.cancel()
        timerStartTransitionTask = nil
        isTimerStartTransitioning = false
        timerTask?.cancel()
        timerTask = nil
        timerEndDate = nil
        isTimerPaused = false
        timerRemaining = timerSelectedMinutes * 60
    }

    private func collapse() {
        isExpanded = false
        isCalendarDetailPresented = false
        // Keep the hidden expanded interface on Timer while its compact state
        // is visible. The next expansion can then reveal an already-final
        // layout instead of changing tabs during the notch morph.
        selectedTab = isTimerActive ? .timer : preferredDefaultTab
        selectedClipboardEntryIDs = []
        clipboardCopyConfirmationTask?.cancel()
        clipboardCopyConfirmationTask = nil
        copiedClipboardEntryID = nil
    }

    private var preferredDefaultTab: IslandTab {
        visibleTabs.contains(.home) ? .home : (visibleTabs.first ?? .home)
    }

    private func reconcileSettings() {
        if !visibleTabs.contains(selectedTab), !(isTimerActive && selectedTab == .timer) {
            selectedTab = preferredDefaultTab
            isCalendarDetailPresented = false
        }

        if !enabledAgentProviders.contains(selectedAgentProvider),
           let firstProvider = enabledAgentProviders.first {
            selectedAgentProvider = firstProvider
        }
    }
}
