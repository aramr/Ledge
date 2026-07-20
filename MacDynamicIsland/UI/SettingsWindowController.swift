import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    init(model: IslandModel, launchAtLoginService: LaunchAtLoginService) {
        let rootView = SettingsRootView(
            model: model,
            settings: model.settings,
            launchAtLoginService: launchAtLoginService
        )
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)

        window.title = "Ledge Settings"
        window.setContentSize(NSSize(width: 720, height: 500))
        window.minSize = NSSize(width: 680, height: 460)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.titlebarSeparatorStyle = .automatic
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.center()

        super.init(window: window)
        shouldCascadeWindows = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        guard let window else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case agentic
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .agentic: "Agentic"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "switch.2"
        case .agentic: "cpu"
        case .about: "info.circle"
        }
    }
}

private struct SettingsRootView: View {
    @Bindable var model: IslandModel
    @Bindable var settings: AppSettings
    @Bindable var launchAtLoginService: LaunchAtLoginService
    @State private var selection: SettingsSection?

    init(
        model: IslandModel,
        settings: AppSettings,
        launchAtLoginService: LaunchAtLoginService
    ) {
        self.model = model
        self.settings = settings
        self.launchAtLoginService = launchAtLoginService
        _selection = State(initialValue: model.selectedTab == .agentic ? .agentic : .general)
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 168, ideal: 184, max: 210)
            .navigationTitle("Settings")
        } detail: {
            Group {
                switch selection ?? .general {
                case .general:
                    GeneralSettingsView(
                        settings: settings,
                        launchAtLoginService: launchAtLoginService
                    )
                case .agentic:
                    AgenticSettingsView(model: model, settings: settings)
                case .about:
                    AboutSettingsView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 680, minHeight: 460)
    }
}

private struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 24, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                content()
            }
            .padding(28)
            .frame(maxWidth: 620, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct GeneralSettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var launchAtLoginService: LaunchAtLoginService

    var body: some View {
        SettingsPage(
            title: "General",
            subtitle: "Choose what appears in Ledge and arrange it around your workflow."
        ) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(
                        "Launch Ledge at login",
                        isOn: Binding(
                            get: { launchAtLoginService.isEnabled },
                            set: { launchAtLoginService.setEnabled($0) }
                        )
                    )
                    .toggleStyle(.switch)

                    if launchAtLoginService.requiresApproval {
                        Text("macOS needs your approval before Ledge can open automatically.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)

                        Button("Open Login Items Settings") {
                            launchAtLoginService.openSystemSettings()
                        }
                    } else if launchAtLoginService.isEnabled {
                        Text("Ledge opens automatically after you log in to your Mac.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Turn this on to open Ledge automatically after you log in.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }

                    if let errorMessage = launchAtLoginService.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.red)
                    }
                }
                .padding(8)
            } label: {
                Label("Startup", systemImage: "power")
                    .font(.headline)
            }

            GroupBox {
                VStack(spacing: 0) {
                    ForEach(Array(settings.tabOrder.enumerated()), id: \.element) { index, tab in
                        TabPreferenceRow(
                            tab: tab,
                            isVisible: settings.isTabVisible(tab),
                            canHide: settings.canHide(tab),
                            canMoveUp: index > 0,
                            canMoveDown: index < settings.tabOrder.count - 1,
                            onVisibilityChange: { settings.setTab(tab, isVisible: $0) },
                            onMoveUp: { settings.moveTab(tab, by: -1) },
                            onMoveDown: { settings.moveTab(tab, by: 1) }
                        )

                        if index < settings.tabOrder.count - 1 {
                            Divider().padding(.leading, 34)
                        }
                    }
                }
                .padding(.vertical, 4)
            } label: {
                Label("Ledge Tabs", systemImage: "square.grid.2x2")
                    .font(.headline)
            }

            Text("Use the arrows to set the tab order. At least one tab always remains available. Changes appear in Ledge immediately.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Live audio waveform", isOn: $settings.usesLiveAudioWaveform)
                        .toggleStyle(.switch)
                    Text("Analyzes the active media app's outgoing audio in memory. macOS asks for System Audio Recording permission when first needed.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)

                    Divider()

                    Toggle(
                        "Bluetooth connection alerts",
                        isOn: $settings.showsBluetoothConnectionNotifications
                    )
                    .toggleStyle(.switch)
                    Text("Observes paired accessories locally and briefly shows newly connected devices.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            } label: {
                Label("Optional System Integrations", systemImage: "hand.raised")
                    .font(.headline)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLoginService.refreshStatus()
        }
    }
}

private struct TabPreferenceRow: View {
    let tab: IslandTab
    let isVisible: Bool
    let canHide: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onVisibilityChange: (Bool) -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: tab.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Toggle(
                tab.title,
                isOn: Binding(
                    get: { isVisible },
                    set: { nextValue in onVisibilityChange(nextValue) }
                )
            )
            .toggleStyle(.switch)
            .disabled(isVisible && !canHide)

            Spacer()

            HStack(spacing: 2) {
                Button(action: onMoveUp) {
                    Image(systemName: "chevron.up")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .disabled(!canMoveUp)
                .help("Move " + tab.title + " earlier")

                Button(action: onMoveDown) {
                    Image(systemName: "chevron.down")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .disabled(!canMoveDown)
                .help("Move " + tab.title + " later")
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
    }
}

private struct AgenticSettingsView: View {
    @Bindable var model: IslandModel
    @Bindable var settings: AppSettings
    @State private var isManagingClaude = ProcessInfo.processInfo.arguments.contains(
        "--claude-manage-preview"
    )

    var body: some View {
        SettingsPage(
            title: "Agentic",
            subtitle: "Control which coding assistants appear and check their connection status."
        ) {
            VStack(spacing: 12) {
                AgentProviderSettingsRow(
                    provider: .codex,
                    isEnabled: settings.showsCodexProvider,
                    status: codexStatus,
                    detail: codexDetail,
                    statusColor: codexStatusColor,
                    actionTitle: codexActionTitle,
                    isActionDisabled: model.isCodexUsageRefreshing,
                    onToggle: { settings.setAgentProvider(.codex, isEnabled: $0) },
                    onAction: codexAction
                )

                AgentProviderSettingsRow(
                    provider: .claude,
                    isEnabled: settings.showsClaudeProvider,
                    status: claudeStatus,
                    detail: claudeDetail,
                    statusColor: claudeStatusColor,
                    actionTitle: claudeActionTitle,
                    isActionDisabled: model.isClaudeUsageRefreshing,
                    onToggle: { settings.setAgentProvider(.claude, isEnabled: $0) },
                    onAction: claudeAction
                )
            }

            Text("Provider visibility only controls what appears in the Agentic tab. Connecting Claude uses the least-invasive local source available and never reads provider credentials or Keychain tokens.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
        .sheet(isPresented: $isManagingClaude) {
            ClaudeConnectionManagementView(model: model)
        }
        .onAppear {
            model.requestAgenticServices()
        }
    }

    private var codexStatus: String {
        switch model.codexConnectionState {
        case .checking: "Checking…"
        case .connected: "Connected"
        case .notInstalled: "Not installed"
        case .signInRequired: "Sign in required"
        case .unavailable: "Unavailable"
        }
    }

    private var codexDetail: String {
        switch model.codexConnectionState {
        case .checking: "Looking for your local Codex account."
        case .connected: "Seven-day usage is available in Ledge."
        case .notInstalled: "Install Codex and sign in to show your usage."
        case .signInRequired: "Open Codex and complete sign-in, then refresh."
        case .unavailable: "Codex was found, but its usage service could not be reached."
        }
    }

    private var codexStatusColor: Color {
        switch model.codexConnectionState {
        case .connected: .green
        case .checking: .blue
        case .signInRequired: .orange
        case .notInstalled: .secondary
        case .unavailable: .red
        }
    }

    private var codexActionTitle: String? {
        switch model.codexConnectionState {
        case .checking: nil
        case .connected, .unavailable: "Refresh"
        case .notInstalled: "Get Codex"
        case .signInRequired: "Open Codex"
        }
    }

    private func codexAction() {
        switch model.codexConnectionState {
        case .connected, .unavailable:
            model.refreshCodexUsage()
        case .notInstalled, .signInRequired:
            model.setUpCodex()
        case .checking:
            break
        }
    }

    private var claudeStatus: String {
        guard model.isClaudeIntegrationEnabled else {
            return model.claudeConnectionState == .checking ? "Checking…" : "Not connected"
        }
        return switch model.claudeConnectionState {
        case .checking: "Checking…"
        case .connected: "Connected"
        case .notInstalled: "Setup required"
        case .signInRequired: "Waiting for Claude"
        case .unavailable: "Needs attention"
        }
    }

    private var claudeDetail: String {
        guard model.isClaudeIntegrationEnabled else {
            if model.claudeDesktopConnectionState != .notInstalled
                || model.claudeCodeBridgeStatus.state != .notInstalled {
                return "Claude was found on this Mac. Connect once to display its seven-day usage."
            }
            return "Connect Claude to display its seven-day usage in Ledge."
        }
        return switch model.claudeConnectionState {
        case .checking: "Looking for Claude Code and Claude Desktop usage."
        case .connected:
            model.claudeUsageSnapshot?.planType == "Claude Code"
                ? "Seven-day usage is arriving through Claude Code."
                : "Seven-day usage is available from Claude Desktop history."
        case .notInstalled: "Install Claude Code or Claude Desktop to finish setup."
        case .signInRequired: model.claudeUsageErrorMessage ?? "Waiting for Claude usage data."
        case .unavailable: "Claude was found, but local usage data is unavailable."
        }
    }

    private var claudeStatusColor: Color {
        guard model.isClaudeIntegrationEnabled else { return .secondary }
        return switch model.claudeConnectionState {
        case .connected: .green
        case .checking: .blue
        case .signInRequired: .orange
        case .notInstalled: .secondary
        case .unavailable: .red
        }
    }

    private var claudeActionTitle: String? {
        model.isClaudeIntegrationEnabled ? "Manage" : "Connect"
    }

    private func claudeAction() {
        if model.isClaudeIntegrationEnabled {
            isManagingClaude = true
        } else {
            model.connectClaude()
        }
    }
}

private struct ClaudeConnectionManagementView: View {
    @Bindable var model: IslandModel
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingBridgeConsent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                ProviderMark(provider: .claude)
                    .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Claude")
                        .font(.system(size: 20, weight: .semibold))
                    HStack(spacing: 6) {
                        Circle()
                            .fill(connectionColor)
                            .frame(width: 7, height: 7)
                        Text(connectionSummary)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            GroupBox("Local data sources") {
                VStack(spacing: 0) {
                    ClaudeSourceDiagnosticRow(
                        icon: "terminal.fill",
                        title: "Claude Code",
                        status: claudeCodeStatus,
                        detail: claudeCodeDetail,
                        color: claudeCodeColor,
                        actionTitle: claudeCodeActionTitle,
                        isActionDisabled: model.claudeCodeBridgeStatus.isBusy,
                        onAction: { isShowingBridgeConsent = true }
                    )

                    Divider().padding(.leading, 42)

                    ClaudeSourceDiagnosticRow(
                        icon: "macbook.and.iphone",
                        title: "Claude Desktop",
                        status: desktopStatus,
                        detail: desktopDetail,
                        color: desktopColor,
                        actionTitle: nil,
                        isActionDisabled: false,
                        onAction: {}
                    )
                }
                .padding(.vertical, 3)
            }

            Text("Claude Code is preferred after it begins reporting usage. Claude Desktop remains an automatic read-only fallback. No prompts, transcripts, credentials, or Keychain items are read.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)

            HStack {
                Button("Disconnect Claude", role: .destructive) {
                    model.disconnectClaude()
                    dismiss()
                }
                .disabled(model.claudeCodeBridgeStatus.isBusy)

                Spacer()

                Button {
                    model.refreshClaudeUsage()
                } label: {
                    Label("Check Now", systemImage: "arrow.clockwise")
                }
                .disabled(model.isClaudeUsageRefreshing)
            }
        }
        .padding(24)
        .frame(width: 540)
        .alert("Add Claude Code terminal support?", isPresented: $isShowingBridgeConsent) {
            Button("Cancel", role: .cancel) {}
            Button("Connect") { model.connectClaudeCodeBridge() }
        } message: {
            Text("This updates ~/.claude/settings.json to run Ledge's local status-line bridge. Any existing status line continues to render and is restored when Claude is disconnected. The usage cache contains quota metadata only, plus a private restore copy of the prior status-line setting.")
        }
    }

    private var connectionSummary: String {
        if let source = model.claudeUsageSnapshot?.planType {
            return "Connected via \(source == "Desktop" ? "Claude Desktop" : "Claude Code")"
        }
        if model.claudeCodeBridgeStatus.isConnected {
            return "Connected — waiting for a Claude Code response"
        }
        return "Connected — waiting for usage"
    }

    private var connectionColor: Color {
        model.claudeConnectionState == .connected ? .green : .orange
    }

    private var claudeCodeStatus: String {
        switch model.claudeCodeBridgeStatus.state {
        case .checking: "Checking"
        case .notInstalled: "Not installed"
        case .disconnected: "Available"
        case .working: "Updating"
        case .connectedWaiting: "Connected"
        case .connected: "Active"
        case .needsRepair: "Repair needed"
        case .conflict: "Settings changed"
        case .failed: "Unavailable"
        }
    }

    private var claudeCodeDetail: String {
        if let message = model.claudeCodeBridgeStatus.message { return message }
        if let version = model.claudeCodeBridgeStatus.version { return version }
        return switch model.claudeCodeBridgeStatus.state {
        case .notInstalled: "Optional for terminal and IDE sessions."
        case .disconnected: "Available for terminal and IDE sessions."
        case .connectedWaiting: "Waiting for the next completed response."
        case .connected: "Providing the current seven-day allowance."
        case .needsRepair: "Reconnect after the app moved."
        case .conflict: "Claude settings were left untouched."
        case .failed: "The previous operation did not complete."
        case .checking, .working: "Checking the local installation."
        }
    }

    private var claudeCodeColor: Color {
        switch model.claudeCodeBridgeStatus.state {
        case .connected, .connectedWaiting: .green
        case .checking, .working, .disconnected, .needsRepair: .blue
        case .notInstalled: .secondary
        case .conflict, .failed: .red
        }
    }

    private var claudeCodeActionTitle: String? {
        switch model.claudeCodeBridgeStatus.state {
        case .disconnected, .failed: "Add"
        case .needsRepair: "Repair"
        case .checking, .notInstalled, .working, .connectedWaiting, .connected, .conflict: nil
        }
    }

    private var desktopStatus: String {
        switch model.claudeDesktopConnectionState {
        case .checking: "Checking"
        case .notInstalled: "Not installed"
        case .installed: "Available"
        case .available: model.claudeUsageSnapshot?.planType == "Desktop" ? "Active" : "Fallback ready"
        }
    }

    private var desktopDetail: String {
        switch model.claudeDesktopConnectionState {
        case .checking: "Checking the local installation."
        case .notInstalled: "Optional read-only fallback."
        case .installed: "Open signed-in Claude Desktop to refresh its local usage."
        case .available: "Local credential-free usage history is available."
        }
    }

    private var desktopColor: Color {
        switch model.claudeDesktopConnectionState {
        case .checking: .blue
        case .notInstalled: .secondary
        case .installed: .blue
        case .available: .green
        }
    }
}

private struct ClaudeSourceDiagnosticRow: View {
    let icon: String
    let title: String
    let status: String
    let detail: String
    let color: Color
    let actionTitle: String?
    let isActionDisabled: Bool
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 12.5, weight: .semibold))
                    Circle().fill(color).frame(width: 5.5, height: 5.5)
                    Text(status)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text(detail)
                    .font(.system(size: 10.75))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if let actionTitle {
                Button(actionTitle, action: onAction)
                    .controlSize(.small)
                    .disabled(isActionDisabled)
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 58)
    }
}

private struct AgentProviderSettingsRow: View {
    let provider: AgentProvider
    let isEnabled: Bool
    let status: String
    let detail: String
    let statusColor: Color
    let actionTitle: String?
    let isActionDisabled: Bool
    let onToggle: (Bool) -> Void
    let onAction: () -> Void

    var body: some View {
        GroupBox {
            HStack(spacing: 14) {
                ProviderMark(provider: provider)
                    .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(provider.title)
                            .font(.system(size: 14, weight: .semibold))

                        Circle()
                            .fill(statusColor)
                            .frame(width: 6, height: 6)

                        Text(status)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                if let actionTitle {
                    Button(actionTitle, action: onAction)
                        .controlSize(.small)
                        .disabled(isActionDisabled)
                }

                Toggle(
                    provider.title,
                    isOn: Binding(
                        get: { isEnabled },
                        set: { nextValue in onToggle(nextValue) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
            }
            .padding(8)
        }
    }
}

private struct ProviderMark: View {
    let provider: AgentProvider

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.accentColor.opacity(provider == .codex ? 0.12 : 0.08))

            AgentProviderIcon(provider)
                .frame(width: 27, height: 27)
        }
        .accessibilityHidden(true)
    }
}

private struct AboutSettingsView: View {
    @Bindable var model: IslandModel
    @State private var isShowingPrivacyNotice = false

    var body: some View {
        SettingsPage(
            title: "About",
            subtitle: "Your essentials, always within reach."
        ) {
            HStack(spacing: 20) {
                AboutAppIcon()
                    .frame(width: 88, height: 88)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Ledge")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Version \(appVersion)")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    Text("Media, calendar, clipboard, timers, and agent usage—right above your workspace.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 3)
                }
            }

            GroupBox("App") {
                VStack(spacing: 0) {
                    AboutInfoRow(label: "Runs in", value: "Menu bar")
                    Divider()
                    AboutInfoRow(label: "Minimum macOS", value: "macOS 15")
                    Divider()
                    AboutInfoRow(label: "Privacy", value: "Local; no telemetry")
                }
            }

            HStack {
                Text("© 2026 Ledge")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("View Welcome Tour…") {
                    model.openOnboarding()
                }
                Button("Privacy…") {
                    isShowingPrivacyNotice = true
                }
                Button("Quit Ledge") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .sheet(isPresented: $isShowingPrivacyNotice) {
            PrivacyNoticeView()
        }
    }

    private var appVersion: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return switch (shortVersion, build) {
        case let (.some(version), .some(build)): "\(version) (\(build))"
        case let (.some(version), .none): version
        default: "1.0"
        }
    }
}

private struct PrivacyNoticeView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Privacy and Data Handling")
                    .font(.system(size: 20, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            ScrollView {
                Text(notice)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
        }
        .frame(width: 640, height: 540)
    }

    private var notice: AttributedString {
        guard let url = Bundle.main.url(forResource: "PRIVACY", withExtension: "md"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            return AttributedString("The privacy notice is unavailable in this build.")
        }
        return (try? AttributedString(markdown: source)) ?? AttributedString(source)
    }
}

private struct AboutInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 8)
        .frame(height: 38)
    }
}

private struct AboutAppIcon: View {
    var body: some View {
        Image(nsImage: bundledAppIcon)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
        .accessibilityHidden(true)
    }

    private var bundledAppIcon: NSImage {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else {
            return NSApplication.shared.applicationIconImage
        }

        return icon
    }
}
