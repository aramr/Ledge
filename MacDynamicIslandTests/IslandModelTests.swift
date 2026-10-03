import AppKit
import SwiftUI
import XCTest
@testable import Ledge

@MainActor
final class IslandModelTests: XCTestCase {
    func testCodexLocatorFindsCurrentBundleAndFallsBackToLegacy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let current = directory.appendingPathComponent("ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
        let legacy = directory.appendingPathComponent("Codex.app/Contents/Resources/codex")
        for url in [current, legacy] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        XCTAssertEqual(CodexExecutableLocator.resolve(applicationDirectories: [directory], cliURLs: []), current)
        try FileManager.default.removeItem(at: current)
        XCTAssertEqual(CodexExecutableLocator.resolve(applicationDirectories: [directory], cliURLs: []), legacy)
        try FileManager.default.removeItem(at: legacy)
        XCTAssertNil(CodexExecutableLocator.resolve(applicationDirectories: [directory], cliURLs: []))
    }

    func testCodexLocatorDiscoversInstallationOnNextLookup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cli = directory.appendingPathComponent("codex")
        XCTAssertNil(CodexExecutableLocator.resolve(applicationDirectories: [], cliURLs: [cli]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        XCTAssertEqual(CodexExecutableLocator.resolve(applicationDirectories: [], cliURLs: [cli]), cli)
    }

    func testBluetoothBaselineAndDuplicateEventsAreSilent() {
        var tracker = BluetoothConnectionTracker()
        let now = Date()
        XCTAssertTrue(tracker.update(["headphones"], at: now, presentNew: false).isEmpty)
        XCTAssertTrue(tracker.update(["headphones"], at: now.addingTimeInterval(2), presentNew: true).isEmpty)
        XCTAssertEqual(tracker.update(["headphones", "keyboard"], at: now.addingTimeInterval(4), presentNew: true), ["keyboard"])
    }

    func testBluetoothBriefDisconnectDoesNotRepeatAlert() {
        var tracker = BluetoothConnectionTracker()
        let now = Date()
        XCTAssertEqual(tracker.update(["airpods"], at: now, presentNew: true), ["airpods"])
        XCTAssertTrue(tracker.update([], at: now.addingTimeInterval(2), presentNew: true).isEmpty)
        XCTAssertTrue(tracker.update(["airpods"], at: now.addingTimeInterval(4), presentNew: true).isEmpty)
        XCTAssertTrue(tracker.update([], at: now.addingTimeInterval(10), presentNew: true).isEmpty)
        XCTAssertTrue(tracker.update(["airpods"], at: now.addingTimeInterval(12), presentNew: true).isEmpty)
    }

    func testBluetoothSustainedDisconnectAllowsRealReconnect() {
        var tracker = BluetoothConnectionTracker()
        let now = Date()
        _ = tracker.update(["mouse"], at: now, presentNew: false)
        _ = tracker.update([], at: now.addingTimeInterval(2), presentNew: true)
        _ = tracker.update([], at: now.addingTimeInterval(8), presentNew: true)
        XCTAssertEqual(tracker.update(["mouse"], at: now.addingTimeInterval(10), presentNew: true), ["mouse"])
    }

    func testBluetoothWearableLinksAreExcluded() {
        XCTAssertFalse(BluetoothConnectionTracker.isAccessory(name: "Aram’s Apple Watch", majorDeviceClass: 0))
        XCTAssertFalse(BluetoothConnectionTracker.isAccessory(name: "Wearable", majorDeviceClass: 0x07))
        XCTAssertFalse(BluetoothConnectionTracker.isAccessory(name: "Apple Watch Phone", majorDeviceClass: 0x02))
        XCTAssertTrue(BluetoothConnectionTracker.isAccessory(name: "AirPods Pro", majorDeviceClass: 0x04))
        XCTAssertTrue(BluetoothConnectionTracker.isAccessory(name: "Magic Keyboard", majorDeviceClass: 0x05))
    }

    func testCalendarDayRefreshAdvancesSelectionWhenItWasFollowingToday() {
        let model = IslandModel()
        let firstDay = Calendar.current.date(
            from: DateComponents(year: 2026, month: 7, day: 28)
        )!
        let nextDay = Calendar.current.date(
            from: DateComponents(year: 2026, month: 7, day: 29)
        )!

        model.refreshCalendarDay(firstDay)
        model.refreshCalendarDay(nextDay)

        XCTAssertEqual(model.currentCalendarDay, Calendar.current.startOfDay(for: nextDay))
        XCTAssertEqual(model.selectedCalendarDate, Calendar.current.startOfDay(for: nextDay))
    }

    func testCalendarDayRefreshPreservesAnExplicitDateSelection() {
        let model = IslandModel()
        let firstDay = Calendar.current.date(
            from: DateComponents(year: 2026, month: 7, day: 28)
        )!
        let nextDay = Calendar.current.date(
            from: DateComponents(year: 2026, month: 7, day: 29)
        )!
        let selectedDay = Calendar.current.date(
            from: DateComponents(year: 2026, month: 7, day: 21)
        )!

        model.refreshCalendarDay(firstDay)
        model.selectCalendarDate(selectedDay)
        model.refreshCalendarDay(nextDay)

        XCTAssertEqual(model.currentCalendarDay, Calendar.current.startOfDay(for: nextDay))
        XCTAssertEqual(model.selectedCalendarDate, Calendar.current.startOfDay(for: selectedDay))
    }

    func testPlayingBackgroundAppProducesCompactIsland() {
        let model = IslandModel()
        model.snapshot = playingSnapshot(source: "com.apple.Music")
        model.frontmostBundleIdentifier = "com.apple.Safari"

        XCTAssertEqual(model.phase, .compact)
    }

    func testPlayingForegroundAppProducesIdleNotch() {
        let model = IslandModel()
        model.snapshot = playingSnapshot(source: "com.apple.Music")
        model.frontmostBundleIdentifier = "com.apple.Music"

        XCTAssertEqual(model.phase, .idle)
        XCTAssertFalse(model.hasActiveMedia)
        XCTAssertTrue(model.hasHomeMedia)
        XCTAssertEqual(model.homeMediaSnapshot.sourceBundleIdentifier, "com.apple.Music")
        XCTAssertFalse(model.shouldCaptureLiveWaveform)

        model.isExpanded = true

        XCTAssertTrue(model.shouldCaptureLiveWaveform)
    }

    func testForegroundMediaCaptureFollowsExpandedHomeVisibility() {
        let model = IslandModel()
        model.snapshot = playingSnapshot(source: "com.spotify.client")
        model.frontmostBundleIdentifier = "com.spotify.client"
        var visibilityChangeCount = 0
        model.onWaveformVisibilityChange = { visibilityChangeCount += 1 }

        model.isExpanded = true

        XCTAssertTrue(model.shouldCaptureLiveWaveform)
        XCTAssertEqual(visibilityChangeCount, 1)

        model.selectTab(.clipboard)

        XCTAssertFalse(model.shouldCaptureLiveWaveform)
        XCTAssertEqual(visibilityChangeCount, 2)

        model.selectTab(.home)

        XCTAssertTrue(model.shouldCaptureLiveWaveform)
        XCTAssertEqual(visibilityChangeCount, 3)
    }

    func testPreviewIgnoresForegroundAppFilter() {
        let model = IslandModel()
        model.isPreviewing = true
        model.snapshot = playingSnapshot(source: "com.apple.Music")
        model.frontmostBundleIdentifier = "com.apple.Music"

        XCTAssertEqual(model.phase, .compact)
    }

    func testNoMediaProducesIdleNotch() {
        let model = IslandModel()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertFalse(model.hasActiveMedia)
    }

    func testOnboardingGreetingTakesCompactPriorityAndOpensTour() {
        let model = IslandModel()
        model.snapshot = playingSnapshot(source: "com.spotify.client")
        model.timerEndDate = .now.addingTimeInterval(60)
        model.isOnboardingGreetingPresented = true
        var openCount = 0
        model.onOpenOnboarding = { openCount += 1 }

        model.setPointerInside(true)
        model.openOnboarding()

        XCTAssertEqual(model.phase, .compact)
        XCTAssertFalse(model.isExpanded)
        XCTAssertEqual(model.surfaceSize, model.onboardingCompactSurfaceSize)
        XCTAssertFalse(model.showsSpotifyCompactProgress)
        XCTAssertEqual(openCount, 1)
    }

    func testOnboardingPanelPassesClicksThroughOutsideVisibleGreeting() {
        XCTAssertTrue(
            IslandPanelController.shouldIgnoreMouseEvents(
                phase: .compact,
                isOnboardingGreetingPresented: true,
                pointerIsInsideSurface: false
            )
        )
        XCTAssertFalse(
            IslandPanelController.shouldIgnoreMouseEvents(
                phase: .compact,
                isOnboardingGreetingPresented: true,
                pointerIsInsideSurface: true
            )
        )
    }

    func testSpotifyProgressOutlineStopsAtRightTopEdgeWithoutClosingAcrossNotch() {
        let rect = CGRect(x: 0, y: 0, width: 310, height: 62)
        let endpoint = SpotifyProgressOutline().path(in: rect).currentPoint

        XCTAssertNotNil(endpoint)
        XCTAssertEqual(endpoint?.x ?? -1, rect.maxX, accuracy: 0.001)
        XCTAssertEqual(endpoint?.y ?? -1, rect.minY, accuracy: 0.001)
    }

    func testScreenshotDiscoveryFiltersUnsupportedFilesAndCapsResults() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "Ledge-Screenshot-Scan-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        for index in 0..<18 {
            let url = directory.appending(path: "Screenshot \(index).png")
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
            try FileManager.default.setAttributes(
                [.creationDate: Date(timeIntervalSince1970: TimeInterval(index + 1))],
                ofItemAtPath: url.path
            )
        }
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: directory.appending(path: "Unrelated.png").path,
                contents: Data()
            )
        )
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: directory.appending(path: "Screenshot notes.txt").path,
                contents: Data()
            )
        )

        let results = ClipboardHistoryService.discoverRecentScreenshots(in: directory)

        XCTAssertEqual(results.count, 15)
        XCTAssertTrue(results.allSatisfy { $0.0.pathExtension == "png" })
        XCTAssertTrue(
            results.allSatisfy {
                $0.0.deletingPathExtension().lastPathComponent.lowercased()
                    .hasPrefix("screenshot")
            }
        )
    }

    func testExpandedPanelRemainsInteractiveOutsideOnboarding() {
        XCTAssertFalse(
            IslandPanelController.shouldIgnoreMouseEvents(
                phase: .expanded,
                isOnboardingGreetingPresented: false,
                pointerIsInsideSurface: false
            )
        )
        XCTAssertTrue(
            IslandPanelController.shouldIgnoreMouseEvents(
                phase: .compact,
                isOnboardingGreetingPresented: false,
                pointerIsInsideSurface: true
            )
        )
        XCTAssertFalse(
            IslandPanelController.shouldIgnoreMouseEvents(
                phase: .compact,
                isOnboardingGreetingPresented: false,
                pointerIsInsideSurface: false,
                pointerIsInsideSideBubble: true
            )
        )
    }

    func testHoverExpandsIdleNotch() {
        let model = IslandModel()

        model.setPointerInside(true)

        XCTAssertEqual(model.phase, .expanded)
        XCTAssertFalse(model.hasActiveMedia)
    }

    func testHoverExpandsPlayingMedia() {
        let model = IslandModel()
        model.renderedNotchSize = CGSize(width: 183, height: 32)
        model.snapshot = playingSnapshot(source: "com.apple.Music")
        model.frontmostBundleIdentifier = "com.apple.Safari"

        XCTAssertEqual(model.surfaceSize, CGSize(width: 295, height: 44))

        model.setPointerInside(true)

        XCTAssertEqual(model.phase, .expanded)
        XCTAssertTrue(model.hasActiveMedia)
        XCTAssertEqual(model.surfaceSize, CGSize(width: 760, height: 202))
    }

    func testActiveTimerAndMediaProduceSideMediaBubble() {
        let model = IslandModel()
        model.renderedNotchSize = CGSize(width: 184, height: 32)
        model.snapshot = playingSnapshot(source: "com.apple.Music")
        model.frontmostBundleIdentifier = "com.apple.Safari"
        model.timerEndDate = .now.addingTimeInterval(60)

        XCTAssertEqual(model.phase, .compact)
        XCTAssertFalse(model.isShowingCompactMedia)
        XCTAssertTrue(model.shouldShowSideMediaBubble)
        XCTAssertEqual(
            model.sideMediaBubbleFrame,
            CGRect(x: 596, y: 6, width: 40, height: 32)
        )
    }

    func testSideMediaBubbleOpensExpandedHome() {
        let model = IslandModel()
        model.snapshot = playingSnapshot(source: "com.apple.Music")
        model.timerEndDate = .now.addingTimeInterval(60)
        model.selectedTab = .timer

        model.openSideMediaBubble()
        // The pointer lands inside the newly expanded surface after the
        // bubble click; that hover refresh must not redirect back to Timer.
        model.setPointerInside(true)

        XCTAssertTrue(model.isExpanded)
        XCTAssertEqual(model.phase, .expanded)
        XCTAssertEqual(model.selectedTab, .home)
        XCTAssertFalse(model.shouldShowSideMediaBubble)
    }

    func testSideMediaBubbleRequiresActivelyPlayingMedia() {
        let model = IslandModel()
        model.snapshot = playingSnapshot(source: "com.apple.Music")
        model.snapshot.playbackRate = 0
        model.timerEndDate = .now.addingTimeInterval(60)

        XCTAssertFalse(model.shouldShowSideMediaBubble)
    }

    func testTimerSideMediaBubbleIncludesForegroundPrimarySpotify() {
        let model = IslandModel()
        model.snapshot = playingSnapshot(source: "com.spotify.client")
        model.snapshot.sourceName = "Spotify"
        model.frontmostBundleIdentifier = "com.spotify.client"
        model.timerEndDate = .now.addingTimeInterval(60)

        XCTAssertFalse(model.hasActiveMedia)
        XCTAssertEqual(model.phase, .compact)
        XCTAssertTrue(model.shouldShowSideMediaBubble)
        XCTAssertEqual(model.homeMediaSnapshot.identifier, model.snapshot.identifier)
    }

    func testTimerSideMediaBubbleIncludesForegroundSpotifyFallback() {
        let model = IslandModel()
        model.spotifyFallbackSnapshot = playingSnapshot(source: "com.spotify.client")
        model.frontmostBundleIdentifier = "com.spotify.client"
        model.timerEndDate = .now.addingTimeInterval(60)

        XCTAssertFalse(model.hasActiveMedia)
        XCTAssertTrue(model.homeMediaUsesSpotifyFallback)
        XCTAssertTrue(model.shouldShowSideMediaBubble)
        XCTAssertEqual(
            model.homeMediaSnapshot.identifier,
            model.spotifyFallbackSnapshot.identifier
        )
    }

    func testTimerSideMediaBubblePrefersPlayingSpotifyOverBrowserMediaRemote() {
        let model = IslandModel()
        model.snapshot = playingSnapshot(source: "com.apple.Safari")
        model.spotifyFallbackSnapshot = playingSnapshot(source: "com.spotify.client")
        model.frontmostBundleIdentifier = "com.spotify.client"
        model.timerEndDate = .now.addingTimeInterval(60)

        XCTAssertTrue(model.homeMediaUsesSpotifyFallback)
        XCTAssertTrue(model.shouldShowSideMediaBubble)
        XCTAssertEqual(
            model.homeMediaSnapshot.sourceBundleIdentifier,
            "com.spotify.client"
        )
    }

    func testPausedMediaCanResumeFromExpandedIsland() {
        let model = IslandModel()
        model.snapshot = playingSnapshot(source: "com.apple.WebKit.GPU")
        model.snapshot.playbackRate = 0
        model.frontmostBundleIdentifier = "com.apple.finder"

        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.hasMediaSession)
        XCTAssertFalse(model.hasActiveMedia)

        model.setPointerInside(true)

        XCTAssertEqual(model.phase, .expanded)
        XCTAssertEqual(model.surfaceSize, CGSize(width: 760, height: 202))
    }

    func testSpotifyProgressAppearsOnlyForCompactSpotifyPlayback() {
        let model = IslandModel()
        model.snapshot = playingSnapshot(source: "com.spotify.client")
        model.snapshot.sourceName = "Spotify"
        model.snapshot.duration = 180

        XCTAssertTrue(model.showsSpotifyCompactProgress)

        model.setPointerInside(true)

        XCTAssertFalse(model.showsSpotifyCompactProgress)
    }

    func testSpotifyProgressDoesNotAppearForOtherMediaSources() {
        let model = IslandModel()
        model.snapshot = playingSnapshot(source: "com.apple.Safari")
        model.snapshot.sourceName = "Safari"
        model.snapshot.duration = 180

        XCTAssertFalse(model.showsSpotifyCompactProgress)
    }

    func testExpandedTabsUseAdaptiveSurfaceSizes() {
        let model = IslandModel()

        // Expanded geometry is available before hover so SwiftUI can keep the
        // hidden interface laid out at its final width during the shell morph.
        XCTAssertEqual(model.expandedSurfaceSize, CGSize(width: 760, height: 202))
        XCTAssertEqual(
            model.expandedSurfaceSize(for: .home),
            CGSize(width: 760, height: 202)
        )
        model.setPointerInside(true)

        XCTAssertEqual(model.surfaceSize, CGSize(width: 760, height: 202))

        model.selectTab(.clipboard)
        XCTAssertEqual(model.surfaceSize, CGSize(width: 760, height: 202))

        model.selectTab(.timer)
        XCTAssertEqual(model.surfaceSize, CGSize(width: 760, height: 202))

        model.selectTab(.agentic)
        XCTAssertEqual(model.surfaceSize, CGSize(width: 760, height: 202))

        model.presentCalendarDetail()
        XCTAssertEqual(model.surfaceSize, CGSize(width: 760, height: 390))
    }

    func testActiveTimerTabRetainsItsOwnLayoutSizeWhenHomeIsSelected() {
        let model = IslandModel()
        model.timerEndDate = .now.addingTimeInterval(60)
        model.setPointerInside(true)

        XCTAssertEqual(model.selectedTab, .timer)
        XCTAssertEqual(
            model.expandedSurfaceSize(for: .timer),
            CGSize(width: 680, height: 132)
        )

        model.selectTab(.home)

        XCTAssertEqual(model.surfaceSize, CGSize(width: 760, height: 202))
        XCTAssertEqual(
            model.expandedSurfaceSize(for: .timer),
            CGSize(width: 680, height: 132)
        )
    }

    func testSelectingAgenticTabRequestsFreshCodexUsage() {
        let model = IslandModel()
        var refreshCount = 0
        var activationCount = 0
        model.onAgenticServicesRequest = { activationCount += 1 }
        model.onCodexUsageRefresh = { refreshCount += 1 }

        model.selectTab(.agentic)
        model.refreshCodexUsage()

        XCTAssertEqual(model.selectedTab, .agentic)
        XCTAssertEqual(activationCount, 1)
        XCTAssertEqual(refreshCount, 2)
    }

    func testAgenticServicesActivateBeforeFirstUsageRefresh() {
        let model = IslandModel()
        var events: [String] = []
        model.onAgenticServicesRequest = { events.append("activate") }
        model.onCodexUsageRefresh = { events.append("refresh") }

        model.selectTab(.agentic)

        XCTAssertEqual(events, ["activate", "refresh"])
    }

    func testSelectingClaudeRequestsOnlyClaudeUsage() {
        let settings = AppSettings()
        let model = IslandModel(settings: settings)
        var codexRefreshCount = 0
        var claudeRefreshCount = 0
        model.onCodexUsageRefresh = { codexRefreshCount += 1 }
        model.onClaudeUsageRefresh = { claudeRefreshCount += 1 }

        model.selectAgentProvider(.claude)
        model.selectTab(.agentic)

        XCTAssertEqual(model.selectedAgentProvider, .claude)
        XCTAssertEqual(codexRefreshCount, 0)
        XCTAssertEqual(claudeRefreshCount, 2)
    }

    func testSettingsControlVisibleTabsAndTheirOrder() {
        let settings = AppSettings()
        let model = IslandModel(settings: settings)

        settings.moveTab(.agentic, by: -1)
        settings.moveTab(.agentic, by: -1)
        settings.setTab(.clipboard, isVisible: false)

        XCTAssertEqual(model.visibleTabs, [.home, .agentic, .timer])
        XCTAssertFalse(settings.isTabVisible(.clipboard))
    }

    func testHidingSelectedTabMovesSelectionToFirstVisibleTab() {
        let settings = AppSettings()
        let model = IslandModel(settings: settings)
        model.selectTab(.clipboard)

        settings.setTab(.clipboard, isVisible: false)

        XCTAssertEqual(model.selectedTab, .home)
        XCTAssertFalse(model.visibleTabs.contains(.clipboard))
    }

    func testSettingsAlwaysKeepAtLeastOneIslandTabVisible() {
        let settings = AppSettings()

        settings.setTab(.clipboard, isVisible: false)
        settings.setTab(.timer, isVisible: false)
        settings.setTab(.agentic, isVisible: false)
        settings.setTab(.home, isVisible: false)

        XCTAssertEqual(settings.visibleTabs, [.home])
        XCTAssertFalse(settings.canHide(.home))
    }

    func testAgentProviderVisibilityReconcilesCurrentProvider() {
        let settings = AppSettings()
        let model = IslandModel(settings: settings)

        settings.setAgentProvider(.claude, isEnabled: true)
        model.selectAgentProvider(.claude)
        settings.setAgentProvider(.claude, isEnabled: false)

        XCTAssertEqual(model.enabledAgentProviders, [.codex])
        XCTAssertEqual(model.selectedAgentProvider, .codex)
    }

    func testNewAgenticSettingsExposeCodexAndClaude() {
        let settings = AppSettings()

        XCTAssertEqual(settings.enabledAgentProviders, [.codex, .claude])
    }

    func testLiveWaveformAndBluetoothAlertsDefaultOn() {
        let settings = AppSettings()

        XCTAssertTrue(settings.usesLiveAudioWaveform)
        XCTAssertTrue(settings.showsBluetoothConnectionNotifications)
    }

    func testPrivacyIntegrationChoicesPersistAndNotifyRuntime() {
        let suiteName = "LedgeTests.privacy-settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        let model = IslandModel(settings: settings)
        var changeCount = 0
        model.onRuntimeSettingsChange = { changeCount += 1 }

        settings.usesLiveAudioWaveform = true
        settings.showsBluetoothConnectionNotifications = true

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertTrue(reloaded.usesLiveAudioWaveform)
        XCTAssertTrue(reloaded.showsBluetoothConnectionNotifications)
        XCTAssertEqual(changeCount, 2)
    }

    func testDefaultIntegrationChoicesPersistAndExplicitOptOutIsRespected() {
        let suiteName = "LedgeTests.waveform-migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = AppSettings(defaults: defaults)
        XCTAssertTrue(initial.usesLiveAudioWaveform)
        XCTAssertTrue(initial.showsBluetoothConnectionNotifications)
        XCTAssertTrue(defaults.bool(forKey: "settings.privacy.liveAudioWaveform"))
        XCTAssertTrue(defaults.bool(forKey: "settings.privacy.bluetoothNotifications"))

        initial.usesLiveAudioWaveform = false
        initial.showsBluetoothConnectionNotifications = false
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertFalse(reloaded.usesLiveAudioWaveform)
        XCTAssertFalse(reloaded.showsBluetoothConnectionNotifications)
    }

    func testFreshPersistentSettingsRequireOnboardingOnlyUntilCompleted() {
        let suiteName = "LedgeTests.onboarding.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let freshSettings = AppSettings(defaults: defaults)
        XCTAssertTrue(freshSettings.needsOnboarding)
        XCTAssertTrue(AppSettings(defaults: defaults).needsOnboarding)

        freshSettings.completeOnboarding()
        XCTAssertFalse(freshSettings.needsOnboarding)
        XCTAssertFalse(AppSettings(defaults: defaults).needsOnboarding)
    }

    func testExistingPersistentSettingsAreNotInterruptedByNewOnboarding() {
        let suiteName = "LedgeTests.existing-onboarding.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set([IslandTab.home.rawValue], forKey: "settings.tabOrder")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(AppSettings(defaults: defaults).needsOnboarding)
        XCTAssertFalse(AppSettings(defaults: defaults).needsOnboarding)
    }

    func testSettingsAndAgentSetupActionsAreForwarded() {
        let model = IslandModel()
        var settingsOpenCount = 0
        var onboardingOpenCount = 0
        var codexSetupCount = 0
        var claudeSetupCount = 0
        var claudeConnectCount = 0
        var claudeDisconnectCount = 0
        var claudeBridgeConnectCount = 0
        var claudeBridgeDisconnectCount = 0
        model.onOpenSettings = { settingsOpenCount += 1 }
        model.onOpenOnboarding = { onboardingOpenCount += 1 }
        model.onCodexSetup = { codexSetupCount += 1 }
        model.onClaudeSetup = { claudeSetupCount += 1 }
        model.onClaudeConnect = { claudeConnectCount += 1 }
        model.onClaudeDisconnect = { claudeDisconnectCount += 1 }
        model.onClaudeCodeBridgeConnect = { claudeBridgeConnectCount += 1 }
        model.onClaudeCodeBridgeDisconnect = { claudeBridgeDisconnectCount += 1 }

        model.openSettings()
        model.openOnboarding()
        model.setUpCodex()
        model.setUpClaude()
        model.connectClaude()
        model.disconnectClaude()
        model.connectClaudeCodeBridge()
        model.disconnectClaudeCodeBridge()

        XCTAssertEqual(settingsOpenCount, 1)
        XCTAssertEqual(onboardingOpenCount, 1)
        XCTAssertEqual(codexSetupCount, 1)
        XCTAssertEqual(claudeSetupCount, 1)
        XCTAssertEqual(claudeConnectCount, 1)
        XCTAssertEqual(claudeDisconnectCount, 1)
        XCTAssertEqual(claudeBridgeConnectCount, 1)
        XCTAssertEqual(claudeBridgeDisconnectCount, 1)
    }

    func testCodexUsageParserSelectsSevenDayWindow() throws {
        let updatedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let payload = """
        {"id":0,"result":{"userAgent":"Codex"}}
        {"id":1,"result":{"rateLimits":{"primary":{"usedPercent":80,"windowDurationMins":300,"resetsAt":1780001000},"secondary":{"usedPercent":27,"windowDurationMins":10080,"resetsAt":1780500000},"planType":"plus"}}}
        """

        let snapshot = try XCTUnwrap(
            CodexUsagePayloadParser.parse(Data(payload.utf8), updatedAt: updatedAt)
        )

        XCTAssertEqual(snapshot.usedPercent, 27)
        XCTAssertEqual(snapshot.remainingPercent, 73)
        XCTAssertEqual(snapshot.windowDurationMinutes, 10_080)
        XCTAssertEqual(snapshot.resetDate, Date(timeIntervalSince1970: 1_780_500_000))
        XCTAssertEqual(snapshot.updatedAt, updatedAt)
        XCTAssertEqual(snapshot.planType, "plus")
    }

    func testCodexUsageParserHandlesSevenDayWindowAsPrimaryBucket() throws {
        let payload = """
        {"id":1,"result":{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":21,"windowDurationMins":10080,"resetsAt":1784786495},"secondary":null,"planType":"pro"}},"rateLimits":{}}}
        """

        let snapshot = try XCTUnwrap(CodexUsagePayloadParser.parse(Data(payload.utf8)))

        XCTAssertEqual(snapshot.usedPercent, 21)
        XCTAssertEqual(snapshot.remainingPercent, 79)
        XCTAssertEqual(snapshot.windowDurationMinutes, 10_080)
        XCTAssertEqual(snapshot.planType, "pro")
    }

    func testClaudeStatusLineParserReadsDocumentedSevenDayLimit() throws {
        let updatedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let payload = """
        {
          "version": "2.1.0",
          "rate_limits": {
            "five_hour": {"used_percentage": 34, "resets_at": "2026-07-18T07:00:00Z"},
            "seven_day": {"used_percentage": 19.5, "resets_at": "2026-07-22T12:30:00Z"}
          }
        }
        """

        let snapshot = try XCTUnwrap(
            ClaudeStatusLinePayloadParser.parse(
                Data(payload.utf8),
                updatedAt: updatedAt
            )
        )

        XCTAssertEqual(snapshot.usedPercent, 19.5)
        XCTAssertEqual(snapshot.updatedAt, updatedAt)
        XCTAssertEqual(snapshot.claudeVersion, "2.1.0")
        XCTAssertEqual(snapshot.resetDate, Date(timeIntervalSince1970: 1_784_723_400))
        XCTAssertEqual(snapshot.snapshot.remainingPercent, 80.5)
        XCTAssertEqual(snapshot.snapshot.windowDurationMinutes, 10_080)
        XCTAssertEqual(snapshot.snapshot.planType, "Claude Code")
    }

    func testClaudeStatusLineParserFallsBackToMostUsedModelSpecificWeek() throws {
        let payload = """
        {
          "rate_limits": {
            "seven_day_sonnet": {"used_percentage": 44, "resets_at": 1784786495},
            "seven_day_opus": {"used_percentage": 12, "resets_at": 1784786400}
          }
        }
        """

        let snapshot = try XCTUnwrap(ClaudeStatusLinePayloadParser.parse(Data(payload.utf8)))

        XCTAssertEqual(snapshot.usedPercent, 44)
        XCTAssertEqual(snapshot.snapshot.remainingPercent, 56)
        XCTAssertEqual(snapshot.resetDate, Date(timeIntervalSince1970: 1_784_786_495))
    }

    func testClaudeStatusLineParserAcceptsInactiveWeekWithoutResetDate() throws {
        let payload = """
        {"rate_limits":{"seven_day":{"used_percentage":0,"resets_at":null}}}
        """

        let snapshot = try XCTUnwrap(ClaudeStatusLinePayloadParser.parse(Data(payload.utf8)))

        XCTAssertEqual(snapshot.usedPercent, 0)
        XCTAssertEqual(snapshot.snapshot.remainingPercent, 100)
        XCTAssertNil(snapshot.resetDate)
    }

    func testClaudeStatusLineParserRequiresRateLimitMetadata() {
        let payload = """
        {"version":"2.1.0","rate_limits":null}
        """

        XCTAssertNil(ClaudeStatusLinePayloadParser.parse(Data(payload.utf8)))
    }

    func testClaudeExecutableCandidatesPreferNativeUserInstall() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let candidates = ClaudeCodeBridgeManager.executableCandidates(
            homeDirectory: home
        )

        XCTAssertEqual(candidates[0].path, "/Users/example/.local/bin/claude")
        XCTAssertEqual(candidates[1].path, "/Users/example/.claude/local/claude")
        XCTAssertEqual(candidates[2].path, "/opt/homebrew/bin/claude")
        XCTAssertEqual(candidates[3].path, "/usr/local/bin/claude")
    }

    func testClaudeBridgeSettingsPreserveAndRestoreExistingStatusLine() throws {
        let existing = """
        {
          "permissions": {"allow": ["Read"]},
          "statusLine": {
            "type": "command",
            "command": "~/.claude/statusline.sh",
            "refreshInterval": 9
          }
        }
        """
        let bridgeCommand = "'/Applications/Ledge.app/Contents/MacOS/Ledge' --claude-status-line-bridge"
        let installation = try ClaudeCodeSettingsEditor.install(
            in: Data(existing.utf8),
            command: bridgeCommand
        )

        XCTAssertTrue(installation.hadOriginalStatusLine)
        XCTAssertEqual(
            ClaudeCodeSettingsEditor.statusLineCommand(in: installation.settingsData),
            bridgeCommand
        )

        let backup = ClaudeCodeBridgeConfiguration(
            schemaVersion: ClaudeCodeBridgeConfiguration.currentSchemaVersion,
            settingsPath: "/tmp/settings.json",
            installedCommand: bridgeCommand,
            hadOriginalStatusLine: installation.hadOriginalStatusLine,
            originalStatusLineData: installation.originalStatusLineData,
            installedAt: .now
        )
        let restored = try ClaudeCodeSettingsEditor.restore(
            in: installation.settingsData,
            from: backup
        )
        let restoredRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: restored) as? [String: Any]
        )
        let restoredStatusLine = try XCTUnwrap(restoredRoot["statusLine"] as? [String: Any])

        XCTAssertEqual(restoredStatusLine["command"] as? String, "~/.claude/statusline.sh")
        XCTAssertEqual(restoredStatusLine["refreshInterval"] as? Int, 9)
        XCTAssertNotNil(restoredRoot["permissions"])
        XCTAssertEqual(backup.originalCommand, "~/.claude/statusline.sh")
    }

    func testClaudeBridgeSettingsRemoveStatusLineWhenNoneExisted() throws {
        let existing = Data("{\"theme\":\"dark\"}".utf8)
        let installation = try ClaudeCodeSettingsEditor.install(
            in: existing,
            command: "bridge --claude-status-line-bridge"
        )
        let backup = ClaudeCodeBridgeConfiguration(
            schemaVersion: ClaudeCodeBridgeConfiguration.currentSchemaVersion,
            settingsPath: "/tmp/settings.json",
            installedCommand: "bridge --claude-status-line-bridge",
            hadOriginalStatusLine: installation.hadOriginalStatusLine,
            originalStatusLineData: installation.originalStatusLineData,
            installedAt: .now
        )
        let restored = try ClaudeCodeSettingsEditor.restore(
            in: installation.settingsData,
            from: backup
        )
        let restoredRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: restored) as? [String: Any]
        )

        XCTAssertNil(restoredRoot["statusLine"])
        XCTAssertEqual(restoredRoot["theme"] as? String, "dark")
    }

    func testClaudeDesktopUsageHistoryReadsFreshCombinedWeek() throws {
        let now = Date(timeIntervalSince1970: 1_784_340_600)
        let payload = """
        {
          "version": 2,
          "samples": [
            {"t": 1784330000000, "org": "first", "u": {"fh": 11, "sd": 18}},
            {"t": 1784340540000, "org": "current", "u": {"fh": 24, "sd": 37.5}}
          ]
        }
        """

        let snapshot = try XCTUnwrap(
            ClaudeDesktopUsageHistoryParser.parse(Data(payload.utf8), now: now)
        )

        XCTAssertEqual(snapshot.usedPercent, 37.5)
        XCTAssertEqual(snapshot.remainingPercent, 62.5)
        XCTAssertNil(snapshot.resetDate)
        XCTAssertEqual(snapshot.updatedAt, Date(timeIntervalSince1970: 1_784_340_540))
        XCTAssertEqual(snapshot.planType, "Desktop")
    }

    func testClaudeDesktopUsageHistoryRejectsStaleSamples() {
        let payload = """
        {"version":2,"samples":[{"t":1784330000000,"org":"old","u":{"sd":21}}]}
        """

        XCTAssertNil(
            ClaudeDesktopUsageHistoryParser.parse(
                Data(payload.utf8),
                now: Date(timeIntervalSince1970: 1_784_340_600)
            )
        )
    }

    func testClaudeConnectionPlannerUsesFreshDesktopWithoutBridgePermission() {
        XCTAssertEqual(
            ClaudeConnectionPlanner.recommendation(
                hasFreshDesktopUsage: true,
                isBridgeActive: false,
                isClaudeCodeInstalled: true,
                isClaudeDesktopInstalled: true
            ),
            .useDesktop
        )
    }

    func testClaudeConnectionPlannerPrefersExistingBridgeWhenDesktopIsNotReady() {
        XCTAssertEqual(
            ClaudeConnectionPlanner.recommendation(
                hasFreshDesktopUsage: false,
                isBridgeActive: true,
                isClaudeCodeInstalled: true,
                isClaudeDesktopInstalled: true
            ),
            .useExistingBridge
        )
    }

    func testClaudeConnectionPlannerRequestsBridgeOnlyWhenNecessary() {
        XCTAssertEqual(
            ClaudeConnectionPlanner.recommendation(
                hasFreshDesktopUsage: false,
                isBridgeActive: false,
                isClaudeCodeInstalled: true,
                isClaudeDesktopInstalled: true
            ),
            .connectClaudeCode
        )
        XCTAssertEqual(
            ClaudeConnectionPlanner.recommendation(
                hasFreshDesktopUsage: false,
                isBridgeActive: false,
                isClaudeCodeInstalled: false,
                isClaudeDesktopInstalled: true
            ),
            .openDesktop
        )
    }

    func testSpotifyFallbackIsUsedOnlyWithoutPrimaryMedia() {
        let model = IslandModel()
        model.spotifyFallbackSnapshot = playingSnapshot(source: "com.spotify.client")
        model.spotifyFallbackSnapshot.playbackRate = 0

        XCTAssertTrue(model.usesSpotifyFallback)
        XCTAssertEqual(model.homeMediaSnapshot.sourceBundleIdentifier, "com.spotify.client")

        model.snapshot = playingSnapshot(source: "com.apple.Safari")

        XCTAssertFalse(model.usesSpotifyFallback)
        XCTAssertEqual(model.homeMediaSnapshot.sourceBundleIdentifier, "com.apple.Safari")
    }

    func testPausedPrimarySpotifyIsNotOverriddenByStalePlayingFallback() {
        let model = IslandModel()
        model.snapshot = playingSnapshot(source: "com.spotify.client")
        model.snapshot.sourceName = "Spotify"
        model.snapshot.playbackRate = 0
        model.spotifyFallbackSnapshot = playingSnapshot(source: "com.spotify.client")

        XCTAssertFalse(model.usesSpotifyFallback)
        XCTAssertFalse(model.homeMediaSnapshot.isPlaying)
    }

    func testForegroundBrowserKeepsPlayingBackgroundSpotifyCompact() {
        let model = IslandModel()
        model.snapshot = playingSnapshot(source: "com.apple.Safari")
        model.spotifyFallbackSnapshot = playingSnapshot(source: "com.spotify.client")
        model.frontmostBundleIdentifier = "com.apple.Safari"

        XCTAssertTrue(model.usesSpotifyFallback)
        XCTAssertEqual(model.homeMediaSnapshot.sourceBundleIdentifier, "com.spotify.client")
        XCTAssertTrue(model.hasActiveMedia)
        XCTAssertEqual(model.phase, .compact)
        XCTAssertTrue(model.isShowingCompactMedia)
    }

    func testPlayingBackgroundSpotifyTakesPriorityOverPlayingBackgroundBrowser() {
        let model = IslandModel()
        model.snapshot = playingSnapshot(source: "com.apple.Safari")
        model.spotifyFallbackSnapshot = playingSnapshot(source: "com.spotify.client")
        model.frontmostBundleIdentifier = "com.apple.finder"

        XCTAssertTrue(model.hasMediaSession)
        XCTAssertTrue(model.usesSpotifyFallback)
        XCTAssertEqual(model.homeMediaSnapshot.sourceBundleIdentifier, "com.spotify.client")
        XCTAssertEqual(model.phase, .compact)
    }

    func testPausedBackgroundSpotifyDoesNotOverridePlayingBackgroundBrowser() {
        let model = IslandModel()
        model.snapshot = playingSnapshot(source: "com.apple.Safari")
        model.spotifyFallbackSnapshot = playingSnapshot(source: "com.spotify.client")
        model.spotifyFallbackSnapshot.playbackRate = 0
        model.frontmostBundleIdentifier = "com.apple.finder"

        XCTAssertFalse(model.usesSpotifyFallback)
        XCTAssertEqual(model.homeMediaSnapshot.sourceBundleIdentifier, "com.apple.Safari")
    }

    func testForegroundBrowserRendersSpotifyCompactArtwork() throws {
        let model = IslandModel()
        model.renderedNotchSize = CGSize(width: 184, height: 32)
        model.snapshot = playingSnapshot(source: "com.apple.Safari")
        model.spotifyFallbackSnapshot = playingSnapshot(source: "com.spotify.client")
        model.spotifyFallbackSnapshot.artwork = solidImage(color: .red)
        model.frontmostBundleIdentifier = "com.apple.Safari"

        let renderer = ImageRenderer(
            content: IslandRootView(model: model)
                .frame(
                    width: IslandModel.canvasSize.width,
                    height: IslandModel.canvasSize.height
                )
        )
        renderer.scale = 1

        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        var foundSpotifyArtwork = false

        for x in 250..<340 where !foundSpotifyArtwork {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                if color.redComponent > 0.8,
                   color.greenComponent < 0.3,
                   color.blueComponent < 0.3,
                   color.alphaComponent > 0.8 {
                    foundSpotifyArtwork = true
                    break
                }
            }
        }

        XCTAssertTrue(foundSpotifyArtwork)
    }

    func testPausedBrowserReturnsToPlayingBackgroundSpotify() {
        let model = IslandModel()
        model.snapshot = playingSnapshot(source: "com.apple.Safari")
        model.snapshot.playbackRate = 0
        model.spotifyFallbackSnapshot = playingSnapshot(source: "com.spotify.client")
        model.frontmostBundleIdentifier = "com.apple.finder"

        XCTAssertTrue(model.usesSpotifyFallback)
        XCTAssertEqual(model.homeMediaSnapshot.sourceBundleIdentifier, "com.spotify.client")
        XCTAssertEqual(model.phase, .compact)
    }

    func testPlayingBrowserTakesPriorityWhenSpotifyBecomesForeground() {
        let model = IslandModel()
        model.snapshot = playingSnapshot(source: "com.apple.Safari")
        model.spotifyFallbackSnapshot = playingSnapshot(source: "com.spotify.client")
        model.frontmostBundleIdentifier = "com.spotify.client"

        XCTAssertFalse(model.usesSpotifyFallback)
        XCTAssertEqual(model.homeMediaSnapshot.sourceBundleIdentifier, "com.apple.Safari")
        XCTAssertEqual(model.phase, .compact)
    }

    func testForegroundSpotifyDoesNotCreateCompactFallback() {
        let model = IslandModel()
        model.spotifyFallbackSnapshot = playingSnapshot(source: "com.spotify.client")
        model.frontmostBundleIdentifier = "com.spotify.client"

        XCTAssertFalse(model.usesSpotifyFallback)
        XCTAssertFalse(model.hasActiveMedia)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.hasHomeMedia)
        XCTAssertTrue(model.homeMediaUsesSpotifyFallback)
        XCTAssertEqual(model.homeMediaSnapshot.sourceBundleIdentifier, "com.spotify.client")
    }

    func testForegroundPrimarySpotifyRemainsAvailableInExpandedHome() {
        let model = IslandModel()
        model.snapshot = playingSnapshot(source: "com.spotify.client")
        model.snapshot.sourceName = "Spotify"
        model.spotifyFallbackSnapshot = model.snapshot
        model.frontmostBundleIdentifier = "com.spotify.client"

        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.hasHomeMedia)
        XCTAssertFalse(model.homeMediaUsesSpotifyFallback)
        XCTAssertEqual(model.homeMediaSnapshot.identifier, model.snapshot.identifier)
    }

    func testPausedSpotifyFallbackReplacesPausedBrowserInHome() {
        let model = IslandModel()
        model.snapshot = playingSnapshot(source: "com.apple.Safari")
        model.snapshot.playbackRate = 0
        model.spotifyFallbackSnapshot = playingSnapshot(source: "com.spotify.client")
        model.spotifyFallbackSnapshot.title = "Last Spotify track"
        model.spotifyFallbackSnapshot.playbackRate = 0

        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.homeMediaUsesSpotifyFallback)
        XCTAssertEqual(model.homeMediaSnapshot.title, "Last Spotify track")
    }

    func testSpotifyReadyControlsUseDedicatedCommandRoute() {
        let model = IslandModel()
        var receivedCommand: MediaCommand?
        model.onSpotifyCommand = { receivedCommand = $0 }

        model.sendToSpotify(.play)

        XCTAssertEqual(receivedCommand, .play)
    }

    func testSpotifyFallbackRestoresPersistedLastTrack() throws {
        let suiteName = "SpotifyFallbackServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let data = try JSONSerialization.data(withJSONObject: [
            "identifier": "spotify:track:123",
            "title": "Persisted song",
            "artist": "Persisted artist",
            "album": "Persisted album",
            "duration": 180.0,
            "elapsedTime": 42.0,
            "artworkURL": "https://example.com/art.jpg"
        ])
        defaults.set(data, forKey: SpotifyFallbackService.persistedTrackDefaultsKey)
        let service = SpotifyFallbackService(defaults: defaults)

        service.restorePersistedSnapshot()

        XCTAssertEqual(service.snapshot.title, "Persisted song")
        XCTAssertEqual(service.snapshot.artist, "Persisted artist")
        XCTAssertEqual(service.snapshot.elapsedTime, 42)
        XCTAssertFalse(service.snapshot.isPlaying)
    }

    func testTimerDurationIsClampedToSupportedRange() {
        let model = IslandModel()

        model.setTimerMinutes(0)
        XCTAssertEqual(model.timerSelectedMinutes, 1)
        XCTAssertEqual(model.timerRemaining, 60)

        model.setTimerMinutes(500)
        XCTAssertEqual(model.timerSelectedMinutes, 120)
        XCTAssertEqual(model.timerRemaining, 7_200)
    }

    func testRunningTimerTakesPriorityOverCompactMedia() {
        let model = IslandModel()
        model.renderedNotchSize = CGSize(width: 184, height: 32)
        model.snapshot = playingSnapshot(source: "com.spotify.client")
        model.snapshot.sourceName = "Spotify"
        model.snapshot.duration = 180
        model.timerRemaining = 7_200
        model.timerEndDate = .now.addingTimeInterval(7_200)

        XCTAssertEqual(model.phase, .compact)
        XCTAssertEqual(model.surfaceSize, CGSize(width: 356, height: 44))
        XCTAssertFalse(model.showsSpotifyCompactProgress)

        model.setPointerInside(true)
        XCTAssertEqual(model.phase, .expanded)
        XCTAssertEqual(model.selectedTab, .timer)
        XCTAssertEqual(model.surfaceSize, CGSize(width: 680, height: 132))

        model.isExpanded = false
        model.timerEndDate = nil
        XCTAssertEqual(model.phase, .compact)
        XCTAssertEqual(model.surfaceSize, CGSize(width: 296, height: 44))
    }

    func testRunningTimerProducesCompactIslandWithoutMedia() {
        let model = IslandModel()
        model.timerEndDate = .now.addingTimeInterval(60)

        XCTAssertEqual(model.phase, .compact)
        XCTAssertEqual(model.compactSurfaceSize, model.timerCompactSurfaceSize)
    }

    func testStartingTimerFromExpandedViewCollapsesDirectlyToCompact() {
        let model = IslandModel()
        model.selectTab(.timer)
        model.isExpanded = true

        model.startTimer()

        XCTAssertTrue(model.isTimerActive)
        XCTAssertTrue(model.isTimerStartTransitioning)
        XCTAssertFalse(model.isExpanded)
        XCTAssertEqual(model.phase, .compact)
        XCTAssertEqual(model.surfaceSize, model.timerCompactSurfaceSize)
    }

    func testPausedTimerFreezesAndKeepsCompactPriorityUntilResumedOrCancelled() {
        let model = IslandModel()
        model.setTimerMinutes(1)
        model.startTimer()

        model.pauseTimer()
        let pausedRemaining = model.timerRemaining

        XCTAssertTrue(model.isTimerActive)
        XCTAssertTrue(model.isTimerPaused)
        XCTAssertFalse(model.isTimerRunning)
        XCTAssertNil(model.timerEndDate)
        XCTAssertGreaterThan(pausedRemaining, 0)
        XCTAssertEqual(model.phase, .compact)

        model.resumeTimer()

        XCTAssertTrue(model.isTimerActive)
        XCTAssertTrue(model.isTimerRunning)
        XCTAssertFalse(model.isTimerPaused)
        XCTAssertNotNil(model.timerEndDate)

        model.cancelTimer()

        XCTAssertFalse(model.isTimerActive)
        XCTAssertEqual(model.phase, .idle)
    }

    func testBluetoothConnectionTemporarilyCreatesTallCompactIsland() {
        let model = IslandModel()
        model.renderedNotchSize = CGSize(width: 184, height: 32)

        model.showBluetoothConnection(
            BluetoothConnectionEvent(
                deviceIdentifier: "airpods",
                deviceName: "AirPods Pro",
                kind: .airPodsPro
            ),
            displayDuration: nil
        )

        XCTAssertEqual(model.phase, .compact)
        XCTAssertEqual(model.compactSurfaceSize, CGSize(width: 364, height: 72))
        XCTAssertTrue(model.isShowingBluetoothConnection)

        model.dismissBluetoothConnection()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertFalse(model.isShowingBluetoothConnection)
    }

    func testBluetoothConnectionTemporarilyOverridesAndRestoresCompactTimer() {
        let model = IslandModel()
        model.renderedNotchSize = CGSize(width: 184, height: 32)
        model.timerRemaining = 60
        model.timerEndDate = .now.addingTimeInterval(60)

        XCTAssertEqual(model.compactSurfaceSize, CGSize(width: 356, height: 44))

        model.showBluetoothConnection(
            BluetoothConnectionEvent(
                deviceIdentifier: "keyboard",
                deviceName: "Magic Keyboard",
                kind: .keyboard
            ),
            displayDuration: nil
        )

        XCTAssertEqual(model.compactSurfaceSize, CGSize(width: 364, height: 72))

        model.dismissBluetoothConnection()

        XCTAssertEqual(model.phase, .compact)
        XCTAssertEqual(model.compactSurfaceSize, CGSize(width: 356, height: 44))
    }

    func testBluetoothConnectionSuppressesSpotifyProgressUntilDismissed() {
        let model = IslandModel()
        model.snapshot = playingSnapshot(source: "com.spotify.client")
        model.snapshot.sourceName = "Spotify"
        model.snapshot.duration = 180

        XCTAssertTrue(model.showsSpotifyCompactProgress)

        model.showBluetoothConnection(
            BluetoothConnectionEvent(
                deviceIdentifier: "headphones",
                deviceName: "Studio Headphones",
                kind: .headphones
            ),
            displayDuration: nil
        )

        XCTAssertFalse(model.showsSpotifyCompactProgress)

        model.dismissBluetoothConnection()

        XCTAssertTrue(model.showsSpotifyCompactProgress)
    }

    func testBluetoothDeviceKindUsesProductNameBeforeGenericClass() {
        XCTAssertEqual(
            BluetoothDeviceKind.classify(
                name: "Aram's AirPods Pro",
                majorDeviceClass: 0x04,
                minorDeviceClass: 0
            ),
            .airPodsPro
        )
        XCTAssertEqual(
            BluetoothDeviceKind.classify(
                name: "Magic Keyboard",
                majorDeviceClass: 0x05,
                minorDeviceClass: 0x10
            ),
            .keyboard
        )
    }

    func testClipboardCommandIndexUsesTextOnlyOrdering() {
        let model = IslandModel()
        let firstText = ClipboardEntry(id: UUID(), payload: .text("First"), createdAt: .now)
        let screenshot = ClipboardEntry(id: UUID(), payload: .image(Data([0x01])), createdAt: .now)
        let secondText = ClipboardEntry(id: UUID(), payload: .text("Second"), createdAt: .now)
        model.clipboardEntries = [firstText, screenshot, secondText]

        var copiedEntries: [ClipboardEntry] = []
        model.onClipboardCopy = { copiedEntries = $0 }
        model.copyClipboardTextItem(at: 1)

        XCTAssertEqual(copiedEntries, [secondText])
        XCTAssertTrue(model.selectedClipboardEntryIDs.isEmpty)
        XCTAssertEqual(model.copiedClipboardEntryID, secondText.id)
    }

    func testClipboardCommandClickSelectionCanCopyMultipleEntriesInHistoryOrder() {
        let model = IslandModel()
        let first = ClipboardEntry(id: UUID(), payload: .text("First"), createdAt: .now)
        let second = ClipboardEntry(id: UUID(), payload: .text("Second"), createdAt: .now)
        model.clipboardEntries = [first, second]

        model.selectClipboardEntry(second)
        model.selectClipboardEntry(first, extendingSelection: true)

        var copiedEntries: [ClipboardEntry] = []
        model.onClipboardCopy = { copiedEntries = $0 }
        model.copySelectedClipboardEntry()

        XCTAssertEqual(copiedEntries, [first, second])
    }

    func testDeletingSelectedClipboardTextPreservesSelectedScreenshots() {
        let model = IslandModel()
        let screenshot = ClipboardEntry(id: UUID(), payload: .image(Data([0x01])), createdAt: .now)
        let firstText = ClipboardEntry(id: UUID(), payload: .text("First"), createdAt: .now)
        let secondText = ClipboardEntry(id: UUID(), payload: .text("Second"), createdAt: .now)
        model.clipboardEntries = [screenshot, firstText, secondText]
        model.selectClipboardEntry(screenshot)
        model.selectClipboardEntry(firstText, extendingSelection: true)
        model.selectClipboardEntry(secondText, extendingSelection: true)

        var deletedIDs: Set<UUID> = []
        model.onClipboardDelete = { deletedIDs = $0 }
        model.deleteSelectedClipboardTextEntries()

        XCTAssertEqual(deletedIDs, [firstText.id, secondText.id])
        XCTAssertEqual(model.clipboardEntries, [screenshot])
        XCTAssertEqual(model.selectedClipboardEntryIDs, [screenshot.id])
    }

    func testClearClipboardTextHistoryPreservesScreenshots() {
        let model = IslandModel()
        let screenshot = ClipboardEntry(id: UUID(), payload: .image(Data([0x01])), createdAt: .now)
        let text = ClipboardEntry(id: UUID(), payload: .text("Text"), createdAt: .now)
        model.clipboardEntries = [screenshot, text]
        model.selectedClipboardEntryIDs = [screenshot.id, text.id]
        model.copiedClipboardEntryID = text.id

        var didClear = false
        model.onClipboardClearTextHistory = { didClear = true }
        model.clearClipboardTextHistory()

        XCTAssertTrue(didClear)
        XCTAssertEqual(model.clipboardEntries, [screenshot])
        XCTAssertEqual(model.selectedClipboardEntryIDs, [screenshot.id])
        XCTAssertNil(model.copiedClipboardEntryID)
    }

    func testBoundedInputReaderRejectsOversizedPayloads() throws {
        let maximumBytes = 1_024

        func read(_ data: Data) throws -> Data? {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try data.write(to: url, options: .atomic)
            defer { try? FileManager.default.removeItem(at: url) }

            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return BoundedInputReader.read(from: handle, maximumBytes: maximumBytes)
        }

        let accepted = Data(repeating: 0x41, count: maximumBytes)
        XCTAssertEqual(try read(accepted), accepted)
        XCTAssertNil(try read(Data(repeating: 0x42, count: maximumBytes + 1)))
    }

    func testBoundedPipeCaptureDrainsWithoutGrowingPastLimit() throws {
        let process = Process()
        let capture = BoundedPipeCapture(maximumBytes: 1_024)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/head")
        process.arguments = ["-c", "4096", "/dev/zero"]
        process.standardOutput = capture.pipe
        process.standardError = FileHandle.nullDevice

        capture.start()
        try process.run()
        capture.closeParentWriter()
        process.waitUntilExit()

        let output = capture.finish()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(output.data.count, 1_024)
        XCTAssertTrue(output.didExceedLimit)
    }

    private func playingSnapshot(source: String) -> MediaSessionSnapshot {
        var snapshot = MediaSessionSnapshot.empty
        snapshot.identifier = "test"
        snapshot.title = "Test media"
        snapshot.sourceBundleIdentifier = source
        snapshot.playbackRate = 1
        return snapshot
    }

    private func solidImage(color: NSColor) -> NSImage {
        let image = NSImage(size: CGSize(width: 32, height: 32))
        image.lockFocus()
        color.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: image.size)).fill()
        image.unlockFocus()
        return image
    }
}
