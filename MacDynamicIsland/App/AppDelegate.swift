import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.persistent()
    private lazy var model = IslandModel(settings: settings)
    private let focusMonitor = FocusMonitor()
    private let systemProvider = SystemMediaSessionProvider()
    private let waveformProvider = SystemAudioWaveformProvider()
    private let previewProvider = PreviewMediaSessionProvider()
    private let spotifyFallbackService = SpotifyFallbackService()
    private let calendarService = CalendarService()
    private let clipboardService = ClipboardHistoryService()
    private let clipboardQuickLookService = ClipboardQuickLookService()
    private let bluetoothConnectionService = BluetoothConnectionService()
    private let timerAlarmService = TimerAlarmService()
    private let codexUsageService = CodexUsageService()
    private let claudeUsageService = ClaudeUsageService()
    private let launchAtLoginService = LaunchAtLoginService()

    private var activeProvider: (any MediaSessionProviding)?
    private var panelController: IslandPanelController?
    private var settingsWindowController: SettingsWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private var statusItem: NSStatusItem?
    private var enabledMenuItem: NSMenuItem?
    private var runtimeServicesStarted = false
    private var agentServicesStarted = false
    private var requestedPreviewOnLaunch = false
    private var isAgenticPreviewLaunch = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The test bundle uses the application as its host. Avoid starting
        // polling services or permission-sensitive integrations in that host;
        // the tests exercise the models and providers directly.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            configureModel()
            return
        }

        configureStatusItem()
        configureModel()

        panelController = IslandPanelController(model: model)
        configureContentServices()
        isAgenticPreviewLaunch = ProcessInfo.processInfo.arguments.contains("--agentic-preview")
        requestedPreviewOnLaunch = ProcessInfo.processInfo.arguments.contains("--preview")
            || ProcessInfo.processInfo.environment["LEDGE_PREVIEW"] == "1"
            || ProcessInfo.processInfo.environment["MAC_DYNAMIC_ISLAND_PREVIEW"] == "1"

        let isFeaturePreview = isAgenticPreviewLaunch
            || ProcessInfo.processInfo.arguments.contains("--bluetooth-preview")
        let shouldPresentOnboarding = ProcessInfo.processInfo.arguments.contains("--onboarding")
            || (settings.needsOnboarding && !isFeaturePreview)
        if shouldPresentOnboarding {
            showOnboarding()
        } else {
            startRuntimeServices()
        }

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--bluetooth-preview") {
            model.showBluetoothConnection(
                BluetoothConnectionEvent(
                    deviceIdentifier: "preview-airpods-pro",
                    deviceName: "AirPods Pro",
                    kind: .airPodsPro
                ),
                displayDuration: nil
            )
        }

        if isAgenticPreviewLaunch {
            model.selectedTab = .agentic
            model.preventsAutomaticCollapse = true
            model.setPointerInside(true)
            if ProcessInfo.processInfo.arguments.contains("--claude-disconnected-preview") {
                model.selectedAgentProvider = .claude
                model.claudeConnectionState = .signInRequired
                model.isClaudeIntegrationEnabled = false
                model.claudeDesktopConnectionState = .installed
                model.claudeCodeBridgeStatus = ClaudeCodeBridgeStatus(
                    state: .disconnected,
                    version: "2.1.0 (Claude Code)",
                    message: nil
                )
            } else if ProcessInfo.processInfo.arguments.contains("--claude-preview") {
                model.selectedAgentProvider = .claude
                model.claudeConnectionState = .connected
                model.isClaudeIntegrationEnabled = true
                model.claudeDesktopConnectionState = .available
                model.claudeUsageSnapshot = ClaudeUsageSnapshot(
                    usedPercent: 31,
                    resetDate: .now.addingTimeInterval(3 * 24 * 60 * 60),
                    updatedAt: .now,
                    windowDurationMinutes: 10_080,
                    planType: "max"
                )
            } else {
                model.selectedAgentProvider = .codex
                model.codexConnectionState = .connected
                model.codexUsageSnapshot = CodexUsageSnapshot(
                    usedPercent: 24,
                    resetDate: .now.addingTimeInterval(4 * 24 * 60 * 60),
                    updatedAt: .now,
                    windowDurationMinutes: 10_080,
                    planType: "plus"
                )
            }
        }
        #endif

        if ProcessInfo.processInfo.arguments.contains("--settings") {
            showSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopRuntimeServices()
        timerAlarmService.stop()
        panelController?.stop()
    }

    private func configureModel() {
        focusMonitor.onChange = { [weak self] bundleIdentifier in
            guard let self else { return }
            model.frontmostBundleIdentifier = bundleIdentifier
            refreshWaveformCapture()
        }

        model.onCommand = { [weak self] command in
            guard let self else { return }
            if model.homeMediaUsesSpotifyFallback {
                spotifyFallbackService.send(command)
            } else {
                activeProvider?.send(command)
            }
        }

        model.onSpotifyCommand = { [weak self] command in
            self?.spotifyFallbackService.send(command)
        }

        model.onWaveformVisibilityChange = { [weak self] in
            self?.refreshWaveformCapture()
        }

        waveformProvider.onLevelsChange = { [weak model] levels, isLive in
            model?.audioLevels = levels
            model?.hasLiveAudioLevels = isLive
        }

        model.onOpenSettings = { [weak self] in
            self?.showSettings()
        }

        model.onOpenOnboarding = { [weak self] in
            self?.showOnboarding()
        }

        model.onAgenticServicesRequest = { [weak self] in
            self?.startAgentServices()
        }

        model.onRuntimeSettingsChange = { [weak self] in
            self?.applyRuntimeSettings()
        }

        model.onCodexSetup = { [weak self] in
            self?.openCodexSetup()
        }

        model.onClaudeSetup = { [weak self] in
            self?.openClaudeSetup()
        }

        model.onClaudeConnect = { [weak self] in
            self?.connectClaude()
        }

        model.onClaudeDisconnect = { [weak claudeUsageService] in
            claudeUsageService?.disconnectClaude()
        }

        model.onClaudeCodeBridgeConnect = { [weak claudeUsageService] in
            claudeUsageService?.connectClaudeCodeBridge()
        }

        model.onClaudeCodeBridgeDisconnect = { [weak claudeUsageService] in
            claudeUsageService?.disconnectClaudeCodeBridge()
        }
    }

    private func configureContentServices() {
        spotifyFallbackService.onSnapshotChange = { [weak self] snapshot in
            guard let self else { return }
            model.spotifyFallbackSnapshot = snapshot
            refreshWaveformCapture()
        }
        model.spotifyFallbackSnapshot = spotifyFallbackService.snapshot

        calendarService.onAccessStateChange = { [weak model] state in
            model?.calendarAccessState = state
        }
        calendarService.onEventsChange = { [weak model] events in
            model?.calendarEvents = events
        }
        model.onCalendarAccessRequest = { [weak calendarService] in
            calendarService?.requestAccess()
        }
        model.onCalendarSelectionChange = { [weak calendarService] date, month in
            calendarService?.updateSelection(date: date, displayedMonth: month)
        }

        clipboardService.onEntriesChange = { [weak model] entries in
            model?.clipboardEntries = entries
        }
        model.clipboardEntries = clipboardService.entries
        model.onClipboardCopy = { [weak clipboardService] entries in
            clipboardService?.copy(entries)
        }
        model.onClipboardPreview = { [weak clipboardQuickLookService] entries in
            clipboardQuickLookService?.preview(entries)
        }
        model.onClipboardDelete = { [weak clipboardService] ids in
            clipboardService?.deleteTextEntries(withIDs: ids)
        }
        model.onClipboardClearTextHistory = { [weak clipboardService] in
            clipboardService?.clearTextHistory()
        }
        model.onTabSelectionChange = { [weak clipboardService] tab in
            if tab == .clipboard {
                // Clipboard history is deliberately opt-in for each app run.
                // Do not inspect the pasteboard until the user opens the
                // clipboard feature.
                clipboardService?.start()
                clipboardService?.enableScreenshotDiscovery()
            }
        }

        model.onTimerFinished = { [weak timerAlarmService] in
            timerAlarmService?.play()
        }

        bluetoothConnectionService.onDeviceConnected = { [weak model] event in
            model?.showBluetoothConnection(event)
        }

        codexUsageService.onStateChange = { [weak model] snapshot, isRefreshing, errorMessage, connectionState in
            model?.codexUsageSnapshot = snapshot
            model?.isCodexUsageRefreshing = isRefreshing
            model?.codexUsageErrorMessage = errorMessage
            model?.codexConnectionState = connectionState
        }
        model.codexUsageSnapshot = codexUsageService.snapshot
        model.isCodexUsageRefreshing = codexUsageService.isRefreshing
        model.codexUsageErrorMessage = codexUsageService.errorMessage
        model.codexConnectionState = codexUsageService.connectionState
        model.onCodexUsageRefresh = { [weak codexUsageService] in
            codexUsageService?.refreshNow()
        }

        claudeUsageService.onStateChange = { [weak model] snapshot, isRefreshing, errorMessage, connectionState in
            model?.claudeUsageSnapshot = snapshot
            model?.isClaudeUsageRefreshing = isRefreshing
            model?.claudeUsageErrorMessage = errorMessage
            model?.claudeConnectionState = connectionState
        }
        model.claudeUsageSnapshot = claudeUsageService.snapshot
        model.isClaudeUsageRefreshing = claudeUsageService.isRefreshing
        model.claudeUsageErrorMessage = claudeUsageService.errorMessage
        model.claudeConnectionState = claudeUsageService.connectionState
        model.onClaudeUsageRefresh = { [weak claudeUsageService] in
            claudeUsageService?.refreshNow()
        }
        claudeUsageService.onBridgeStatusChange = { [weak model] status in
            model?.claudeCodeBridgeStatus = status
        }
        model.claudeCodeBridgeStatus = claudeUsageService.bridgeStatus
        claudeUsageService.onIntegrationChange = { [weak model] isEnabled, desktopState in
            model?.isClaudeIntegrationEnabled = isEnabled
            model?.claudeDesktopConnectionState = desktopState
        }
        model.isClaudeIntegrationEnabled = claudeUsageService.isIntegrationEnabled
        model.claudeDesktopConnectionState = claudeUsageService.desktopConnectionState
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "rectangle.topthird.inset.filled",
            accessibilityDescription: "Ledge"
        )

        let menu = NSMenu()
        let enabled = NSMenuItem(title: "Enable Ledge", action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.target = self
        enabled.state = .on
        menu.addItem(enabled)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Ledge", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
        enabledMenuItem = enabled
    }

    private func selectProvider(preview: Bool) {
        activeProvider?.stop()
        activeProvider?.onSnapshotChange = nil

        let provider: any MediaSessionProviding = preview ? previewProvider : systemProvider
        activeProvider = provider
        model.isPreviewing = preview
        model.isExpanded = false

        provider.onSnapshotChange = { [weak self] snapshot in
            guard let self else { return }
            model.snapshot = snapshot
            refreshWaveformCapture()
        }
        model.snapshot = provider.snapshot
        provider.start()
        refreshWaveformCapture()
    }

    @objc private func toggleEnabled() {
        model.isEnabled.toggle()
        if model.isEnabled {
            startRuntimeServices()
        } else {
            model.isExpanded = false
            stopRuntimeServices()
        }
        refreshWaveformCapture()
        enabledMenuItem?.state = model.isEnabled ? .on : .off
    }

    @objc private func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                model: model,
                launchAtLoginService: launchAtLoginService
            )
        }
        launchAtLoginService.refreshStatus()
        settingsWindowController?.present()
    }

    @objc private func showOnboarding() {
        model.isOnboardingGreetingPresented = true
        launchAtLoginService.refreshStatus()

        if onboardingWindowController == nil {
            onboardingWindowController = OnboardingWindowController(
                launchesAtLoginByDefault: settings.needsOnboarding
                    || launchAtLoginService.isEnabled,
                onFinish: { [weak self] launchesAtLogin in
                    self?.finishOnboarding(launchesAtLogin: launchesAtLogin)
                },
                onDismiss: { [weak self] in
                    guard let self else { return }
                    if !settings.needsOnboarding {
                        model.isOnboardingGreetingPresented = false
                    }
                    onboardingWindowController = nil
                }
            )
        }
        onboardingWindowController?.present()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func openCodexSetup() {
        if model.codexConnectionState == .signInRequired,
           let applicationURL = codexApplicationURL() {
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            )
            return
        }

        guard let url = URL(string: "https://openai.com/codex/") else { return }
        NSWorkspace.shared.open(url)
    }

    private func codexApplicationURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [
            "/Applications/ChatGPT.app",
            "/Applications/Codex.app",
            home.appendingPathComponent("Applications/ChatGPT.app").path,
            home.appendingPathComponent("Applications/Codex.app").path
        ]
        return paths.lazy
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map(URL.init(fileURLWithPath:))
            .first
    }

    private func openClaudeSetup() {
        guard let url = URL(string: "https://code.claude.com/docs/en/setup") else { return }
        NSWorkspace.shared.open(url)
    }

    private func connectClaude() {
        switch claudeUsageService.connectionRecommendation {
        case .useDesktop, .useExistingBridge:
            claudeUsageService.enableUsingAvailableSource()
        case .connectClaudeCode:
            presentClaudeCodeConnectionConsent()
        case .openDesktop:
            claudeUsageService.enableAndWaitForDesktop()
            openClaudeDesktop()
        case .installClaude:
            openClaudeSetup()
        }
    }

    private func presentClaudeCodeConnectionConsent() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Connect Claude?"
        alert.informativeText = "Claude Code was found on this Mac. Connecting updates ~/.claude/settings.json to run Ledge's local status-line bridge. Any existing status line continues to render and is restored when Claude is disconnected. The app saves quota metadata only, plus a private restore copy of the previous status-line setting."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            claudeUsageService.connectClaudeCodeBridge()
        }
    }

    private func openClaudeDesktop() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [
            "/Applications/Claude.app",
            home.appendingPathComponent("Applications/Claude.app").path
        ]
        guard let path = paths.first(where: FileManager.default.fileExists(atPath:)),
              FileManager.default.fileExists(atPath: path) else {
            return
        }
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: path),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    private func refreshWaveformCapture() {
        waveformProvider.update(
            for: model.homeMediaSnapshot,
            shouldCapture: settings.usesLiveAudioWaveform
                && model.isEnabled
                && !model.isPreviewing
                && model.shouldCaptureLiveWaveform
        )
    }

    private func applyRuntimeSettings() {
        refreshWaveformCapture()
        guard runtimeServicesStarted, !isAgenticPreviewLaunch else { return }

        if settings.showsBluetoothConnectionNotifications {
            bluetoothConnectionService.start()
        } else {
            bluetoothConnectionService.stop()
            model.dismissBluetoothConnection()
        }
    }

    private func startAgentServices() {
        guard model.isEnabled,
              runtimeServicesStarted,
              !agentServicesStarted,
              !isAgenticPreviewLaunch else { return }
        agentServicesStarted = true
        codexUsageService.start()
        claudeUsageService.start()
    }

    private func startRuntimeServices() {
        guard model.isEnabled, !runtimeServicesStarted else { return }
        runtimeServicesStarted = true

        focusMonitor.start()
        if !isAgenticPreviewLaunch {
            calendarService.start()
            spotifyFallbackService.start()
            if settings.showsBluetoothConnectionNotifications {
                bluetoothConnectionService.start()
            }
            selectProvider(preview: requestedPreviewOnLaunch)
            requestedPreviewOnLaunch = false
        }
    }

    private func stopRuntimeServices() {
        runtimeServicesStarted = false
        agentServicesStarted = false

        focusMonitor.stop()
        waveformProvider.stop()
        spotifyFallbackService.stop()
        calendarService.stop()
        clipboardService.stop()
        bluetoothConnectionService.stop()
        codexUsageService.stop()
        claudeUsageService.stop()
        activeProvider?.stop()
        activeProvider?.onSnapshotChange = nil
        activeProvider = nil

        requestedPreviewOnLaunch = false
        model.isPreviewing = false
        model.snapshot = .empty
        model.spotifyFallbackSnapshot = .empty
        model.calendarEvents = []
        model.clipboardEntries = []
        model.selectedClipboardEntryIDs = []
        model.codexUsageSnapshot = nil
        model.claudeUsageSnapshot = nil
        model.dismissBluetoothConnection()
    }

    private func finishOnboarding(launchesAtLogin: Bool) {
        settings.completeOnboarding()
        launchAtLoginService.setEnabled(launchesAtLogin)
        model.isOnboardingGreetingPresented = false
        onboardingWindowController?.close()

        // Let the welcome window close and the notch retract before any
        // feature-specific system prompt is allowed to appear.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(280))
            guard let self else { return }
            if settings.usesLiveAudioWaveform {
                await waveformProvider.requestAccess()
            }
            startRuntimeServices()
        }
    }
}

@MainActor
private final class TimerAlarmService {
    private var playbackTask: Task<Void, Never>?
    private var activeSounds: [NSSound] = []

    func play() {
        stop()

        playbackTask = Task { [weak self] in
            // macOS does not include the iOS Timer sound as a public system
            // asset. Layering its bright and low alert tones creates a more
            // assertive alarm pattern while using supported system sounds.
            for _ in 0..<8 {
                guard let self, !Task.isCancelled else { return }
                activeSounds = ["Ping", "Basso"].compactMap { name in
                    guard let sound = NSSound(named: NSSound.Name(name)) else { return nil }
                    sound.volume = name == "Ping" ? 1 : 0.72
                    sound.play()
                    return sound
                }

                do {
                    try await Task.sleep(for: .milliseconds(1_650))
                } catch {
                    return
                }
            }

            self?.activeSounds = []
            self?.playbackTask = nil
        }
    }

    func stop() {
        playbackTask?.cancel()
        playbackTask = nil
        activeSounds.forEach { $0.stop() }
        activeSounds = []
    }
}
