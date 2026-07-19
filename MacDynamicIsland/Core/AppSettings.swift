import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    private static let currentOnboardingVersion = 1

    private enum Key {
        static let tabOrder = "settings.tabOrder"
        static let hiddenTabs = "settings.hiddenTabs"
        static let showsCodexProvider = "settings.agentic.codex"
        static let showsClaudeProvider = "settings.agentic.claude"
        static let agentProviderDefaultsVersion = "settings.agentic.defaultsVersion"
        static let usesLiveAudioWaveform = "settings.privacy.liveAudioWaveform"
        static let showsBluetoothConnectionNotifications = "settings.privacy.bluetoothNotifications"
        static let onboardingCompletedVersion = "onboarding.completedVersion"
        static let onboardingPendingVersion = "onboarding.pendingVersion"

        static let installationMarkers = [
            tabOrder,
            hiddenTabs,
            showsCodexProvider,
            showsClaudeProvider,
            agentProviderDefaultsVersion,
            usesLiveAudioWaveform,
            showsBluetoothConnectionNotifications,
            onboardingCompletedVersion,
            onboardingPendingVersion
        ]
    }

    var tabOrder: [IslandTab] {
        didSet { persistAndNotify() }
    }

    private(set) var hiddenTabs: Set<IslandTab> {
        didSet { persistAndNotify() }
    }

    var showsCodexProvider: Bool {
        didSet { persistAndNotify() }
    }

    var showsClaudeProvider: Bool {
        didSet { persistAndNotify() }
    }

    var usesLiveAudioWaveform: Bool {
        didSet { persistAndNotify() }
    }

    var showsBluetoothConnectionNotifications: Bool {
        didSet { persistAndNotify() }
    }

    private(set) var needsOnboarding: Bool

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var isLoading = true
    @ObservationIgnored var onChange: (() -> Void)?

    /// Passing no defaults creates an in-memory settings model, which keeps
    /// previews and tests independent from the user's real preferences.
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults

        let hadExistingInstallation = defaults.map { defaults in
            Key.installationMarkers.contains { defaults.object(forKey: $0) != nil }
        } ?? false
        let completedOnboardingVersion = defaults?.integer(
            forKey: Key.onboardingCompletedVersion
        ) ?? 0
        let pendingOnboardingVersion = defaults?.integer(
            forKey: Key.onboardingPendingVersion
        ) ?? 0

        if defaults == nil || completedOnboardingVersion >= Self.currentOnboardingVersion {
            needsOnboarding = false
        } else if pendingOnboardingVersion == Self.currentOnboardingVersion {
            // A fresh user closed Ledge before completing the tour. Keep the
            // greeting available on the next launch instead of mistaking the
            // preferences written during that launch for an existing install.
            needsOnboarding = true
        } else if !hadExistingInstallation {
            needsOnboarding = true
            defaults?.set(
                Self.currentOnboardingVersion,
                forKey: Key.onboardingPendingVersion
            )
        } else {
            needsOnboarding = false
        }

        // Existing users should not be interrupted when onboarding is added
        // to a later build. They can replay the tour from the menu or About.
        if let defaults,
           hadExistingInstallation,
           pendingOnboardingVersion != Self.currentOnboardingVersion,
           completedOnboardingVersion < Self.currentOnboardingVersion {
            defaults.set(
                Self.currentOnboardingVersion,
                forKey: Key.onboardingCompletedVersion
            )
        }

        let storedOrder = defaults?.stringArray(forKey: Key.tabOrder) ?? []
        let decodedOrder = storedOrder.compactMap(IslandTab.init(rawValue:))
        let uniqueOrder = decodedOrder.reduce(into: [IslandTab]()) { result, tab in
            if !result.contains(tab) { result.append(tab) }
        }
        tabOrder = uniqueOrder + IslandTab.allCases.filter { !uniqueOrder.contains($0) }

        let hiddenRawValues = defaults?.stringArray(forKey: Key.hiddenTabs) ?? []
        var loadedHiddenTabs = Set(hiddenRawValues.compactMap(IslandTab.init(rawValue:)))
        if loadedHiddenTabs.count == IslandTab.allCases.count {
            loadedHiddenTabs.remove(.home)
        }
        hiddenTabs = loadedHiddenTabs

        if defaults?.object(forKey: Key.showsCodexProvider) != nil {
            showsCodexProvider = defaults?.bool(forKey: Key.showsCodexProvider) ?? true
        } else {
            showsCodexProvider = true
        }

        if let defaults, defaults.integer(forKey: Key.agentProviderDefaultsVersion) < 2 {
            // Claude was previously a disabled placeholder. Reveal it once as
            // the live integration ships; choices made after this migration
            // continue to be respected.
            showsClaudeProvider = true
            defaults.set(true, forKey: Key.showsClaudeProvider)
            defaults.set(2, forKey: Key.agentProviderDefaultsVersion)
        } else if defaults?.object(forKey: Key.showsClaudeProvider) != nil {
            showsClaudeProvider = defaults?.bool(forKey: Key.showsClaudeProvider) ?? true
        } else {
            showsClaudeProvider = true
        }

        if let defaults,
           defaults.object(forKey: Key.usesLiveAudioWaveform) != nil {
            // Once a user has made a choice, always preserve it.
            usesLiveAudioWaveform = defaults.bool(forKey: Key.usesLiveAudioWaveform)
        } else {
            usesLiveAudioWaveform = true
            defaults?.set(true, forKey: Key.usesLiveAudioWaveform)
        }

        if let defaults,
           defaults.object(forKey: Key.showsBluetoothConnectionNotifications) != nil {
            showsBluetoothConnectionNotifications = defaults.bool(
                forKey: Key.showsBluetoothConnectionNotifications
            )
        } else {
            showsBluetoothConnectionNotifications = true
            defaults?.set(true, forKey: Key.showsBluetoothConnectionNotifications)
        }

        isLoading = false
    }

    static func persistent() -> AppSettings {
        AppSettings(defaults: .standard)
    }

    var visibleTabs: [IslandTab] {
        tabOrder.filter { !hiddenTabs.contains($0) }
    }

    var enabledAgentProviders: [AgentProvider] {
        AgentProvider.allCases.filter(isAgentProviderEnabled)
    }

    func completeOnboarding() {
        needsOnboarding = false
        defaults?.set(
            Self.currentOnboardingVersion,
            forKey: Key.onboardingCompletedVersion
        )
        defaults?.removeObject(forKey: Key.onboardingPendingVersion)
    }

    func isTabVisible(_ tab: IslandTab) -> Bool {
        !hiddenTabs.contains(tab)
    }

    func canHide(_ tab: IslandTab) -> Bool {
        !isTabVisible(tab) || visibleTabs.count > 1
    }

    func setTab(_ tab: IslandTab, isVisible: Bool) {
        if isVisible {
            hiddenTabs.remove(tab)
        } else if visibleTabs.count > 1 {
            hiddenTabs.insert(tab)
        }
    }

    func moveTab(_ tab: IslandTab, by offset: Int) {
        guard let currentIndex = tabOrder.firstIndex(of: tab) else { return }
        let destination = currentIndex + offset
        guard tabOrder.indices.contains(destination) else { return }
        tabOrder.swapAt(currentIndex, destination)
    }

    func isAgentProviderEnabled(_ provider: AgentProvider) -> Bool {
        switch provider {
        case .codex: showsCodexProvider
        case .claude: showsClaudeProvider
        }
    }

    func setAgentProvider(_ provider: AgentProvider, isEnabled: Bool) {
        switch provider {
        case .codex: showsCodexProvider = isEnabled
        case .claude: showsClaudeProvider = isEnabled
        }
    }

    private func persistAndNotify() {
        guard !isLoading else { return }

        defaults?.set(tabOrder.map(\.rawValue), forKey: Key.tabOrder)
        defaults?.set(hiddenTabs.map(\.rawValue), forKey: Key.hiddenTabs)
        defaults?.set(showsCodexProvider, forKey: Key.showsCodexProvider)
        defaults?.set(showsClaudeProvider, forKey: Key.showsClaudeProvider)
        defaults?.set(usesLiveAudioWaveform, forKey: Key.usesLiveAudioWaveform)
        defaults?.set(
            showsBluetoothConnectionNotifications,
            forKey: Key.showsBluetoothConnectionNotifications
        )
        onChange?()
    }
}
