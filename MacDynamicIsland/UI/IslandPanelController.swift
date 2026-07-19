import AppKit
import Observation
import SwiftUI

@MainActor
final class IslandPanelController {
    private let panelSize = NSSize(
        width: IslandModel.canvasSize.width,
        height: IslandModel.canvasSize.height
    )
    private let model: IslandModel
    private let panel: IslandPanel
    private var screenObserver: NSObjectProtocol?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var pointerIsInside: Bool?

    init(model: IslandModel) {
        self.model = model
        self.panel = IslandPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configurePanel()
        observeModel()
        observeScreens()
        observePointer()
        updatePanel(animated: false)
    }

    func stop() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
        }
        panel.orderOut(nil)
    }

    private func configurePanel() {
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.colorSpace = .deviceRGB
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.becomesKeyOnlyIfNeeded = true

        let hostingView = NSHostingView(rootView: IslandRootView(model: model))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
    }

    private func observeModel() {
        withObservationTracking {
            _ = model.isEnabled
            _ = model.phase
            _ = model.surfaceSize
            _ = model.hasActiveMedia
            _ = model.snapshot.identifier
            _ = model.selectedTab
            _ = model.selectedClipboardEntryIDs
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.updatePanel(animated: true)
                if self.model.phase == .expanded,
                   self.model.selectedTab == .clipboard {
                    self.panel.makeKey()
                }
                self.observeModel()
            }
        }
    }

    private func observeScreens() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updatePanel(animated: false) }
        }
    }

    private func observePointer() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor in self?.refreshPointerState() }
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown,
               model.phase == .expanded,
               model.selectedTab == .clipboard {
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let character = event.charactersIgnoringModifiers?.lowercased()

                if modifiers.contains(.command), character == "c" {
                    model.copySelectedClipboardEntry()
                    return nil
                }

                if modifiers.contains(.command),
                   let character,
                   character.count == 1,
                   let index = Int(character),
                   (0...9).contains(index) {
                    model.copyClipboardTextItem(at: index)
                    return nil
                }

                if event.keyCode == 49, modifiers.isEmpty {
                    model.previewSelectedClipboardEntries()
                    return nil
                }

                if (event.keyCode == 51 || event.keyCode == 117),
                   !model.selectedClipboardTextEntryIDs.isEmpty {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                        model.deleteSelectedClipboardTextEntries()
                    }
                    return nil
                }
            }

            Task { @MainActor in self.refreshPointerState() }
            return event
        }
    }

    private func refreshPointerState() {
        let size = model.surfaceSize
        let surfaceFrame = NSRect(
            x: panel.frame.midX - size.width / 2,
            y: panel.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        let isInside = panel.isVisible && surfaceFrame.contains(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = Self.shouldIgnoreMouseEvents(
            phase: model.phase,
            isOnboardingGreetingPresented: model.isOnboardingGreetingPresented,
            pointerIsInsideSurface: isInside
        )
        guard pointerIsInside != isInside else { return }
        pointerIsInside = isInside
        model.setPointerInside(isInside)
    }

    static func shouldIgnoreMouseEvents(
        phase: IslandPhase,
        isOnboardingGreetingPresented: Bool,
        pointerIsInsideSurface: Bool
    ) -> Bool {
        // The AppKit panel is intentionally canvas-sized so the island can
        // expand without rebuilding its SwiftUI hierarchy. During onboarding,
        // however, only the much smaller visible greeting should be clickable;
        // the transparent remainder must pass clicks through to the tour window
        // and the rest of macOS.
        if isOnboardingGreetingPresented {
            return !pointerIsInsideSurface
        }
        return phase != .expanded
    }

    private func updatePanel(animated: Bool) {
        guard model.isEnabled else {
            panel.orderOut(nil)
            return
        }

        let phase = model.phase
        guard let screen = preferredScreen() else { return }
        let usesPhysicalNotch = screen.safeAreaInsets.top > 0
        if model.usesPhysicalNotch != usesPhysicalNotch {
            model.usesPhysicalNotch = usesPhysicalNotch
        }
        let renderedNotchSize = renderedNotchSize(on: screen)
        if model.renderedNotchSize != renderedNotchSize {
            model.renderedNotchSize = renderedNotchSize
        }
        let targetFrame = panelFrame(on: screen)
        panel.ignoresMouseEvents = Self.shouldIgnoreMouseEvents(
            phase: phase,
            isOnboardingGreetingPresented: model.isOnboardingGreetingPresented,
            pointerIsInsideSurface: pointerIsInside ?? false
        )

        if !panel.isVisible || !animated {
            if !panel.isVisible {
                panel.alphaValue = 0
                panel.orderFrontRegardless()
            }
            panel.setFrame(targetFrame, display: true)
            panel.alphaValue = 1
            refreshPointerState()
            return
        }

        if panel.frame != targetFrame {
            panel.setFrame(targetFrame, display: true)
        }
        refreshPointerState()
    }

    private func preferredScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func panelFrame(on screen: NSScreen) -> NSRect {
        return NSRect(
            x: screen.frame.midX - panelSize.width / 2,
            y: screen.frame.maxY - panelSize.height,
            width: panelSize.width,
            height: panelSize.height
        )
    }

    private func renderedNotchSize(on screen: NSScreen) -> NSSize {
        let fallback = NSSize(width: 180, height: 32)

        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea,
              screen.safeAreaInsets.top > 0 else {
            return fallback
        }

        let width = right.minX - left.maxX
        guard width > 0 else { return fallback }
        // A two-point overlap on each side hides subpixel seams where the LCD
        // surface meets the physical camera housing.
        return NSSize(width: width + 4, height: screen.safeAreaInsets.top)
    }
}

private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
