import AppKit
import SwiftUI

struct IslandRootView: View {
    @Bindable var model: IslandModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSpotifyProgressReady = false
    @State private var spotifyProgressReveal = 0.0

    var body: some View {
        ZStack(alignment: .top) {
            // Keep one silhouette alive for every phase. On a notched display
            // the idle surface sits directly behind the physical notch, giving
            // SwiftUI a stable shape to interpolate instead of inserting a new
            // black view on the first frame of an expansion.
            IslandBackground(
                phase: model.phase,
                usesTallCompactShape: model.isShowingBluetoothConnection
                    || model.isOnboardingGreetingPresented
            )
                .frame(width: model.surfaceSize.width, height: model.surfaceSize.height)
                .overlay {
                    SpotifyProgressBorder(
                        snapshot: model.homeMediaSnapshot,
                        isVisible: shouldShowSpotifyProgress,
                        revealProgress: spotifyProgressReveal
                    )
                    // Give the centered stroke and soft endpoint blur room
                    // outside the silhouette without changing island layout.
                    .padding(-12)
                    .opacity(shouldShowSpotifyProgress ? 1 : 0)
                    // The progress edge belongs only to the compact state and
                    // should disappear before the expansion spring begins.
                    .animation(nil, value: shouldShowSpotifyProgress)
                    .allowsHitTesting(false)
                }
                .animation(surfaceAnimation, value: model.phase)
                .animation(surfaceAnimation, value: model.surfaceSize)

            ZStack(alignment: .top) {
                CompactIslandView(model: model)
                    .frame(
                        width: model.compactSurfaceSize.width,
                        height: model.compactSurfaceSize.height
                    )
                    .animation(surfaceAnimation, value: model.compactSurfaceSize)
                    .scaleEffect(model.phase == .compact ? 1 : 0.96, anchor: .top)
                    .opacity(model.phase == .compact ? 1 : 0)
                    .animation(compactContentAnimation, value: model.phase)
                    .allowsHitTesting(model.phase == .compact)

                ExpandedArtworkAmbient(model: model)
                    .allowsHitTesting(false)

                ExpandedTabbedView(model: model)
                    // Always lay out controls at their final expanded size.
                    // Only the centered silhouette and mask interpolate from
                    // the notch, so the interface no longer reflows sideways.
                    .frame(
                        width: renderedExpandedSurfaceSize.width,
                        height: renderedExpandedSurfaceSize.height
                    )
                    .animation(surfaceAnimation, value: renderedExpandedSurfaceSize)
                    .scaleEffect(expandedContentScale, anchor: .top)
                    .opacity(model.phase == .expanded ? 1 : 0)
                    .animation(expandedContentAnimation, value: model.phase)
                    .allowsHitTesting(model.phase == .expanded)

                // Artwork remains one persistent morphing element. The
                // waveform is deliberately phased between two stationary
                // copies because moving already-animated bars makes their
                // spacing appear to stretch during the island spring.
                SharedArtwork(model: model)
                    .opacity(showsSharedMediaElements ? 1 : 0)
                    .animation(contentFadeAnimation, value: showsSharedMediaElements)
                    .allowsHitTesting(false)
                    .zIndex(2)

                PhasedWaveforms(model: model)
                    .allowsHitTesting(false)
                    .zIndex(2)
            }
            .frame(
                width: IslandModel.canvasSize.width,
                height: IslandModel.canvasSize.height,
                alignment: .top
            )
            // Expanded controls must never outlive the black surface visually.
            // Using the same animated silhouette as a mask makes content reveal
            // and retract at exactly the island's current edges.
            .mask(alignment: .top) {
                IslandBackground(
                    phase: model.phase,
                    usesTallCompactShape: model.isShowingBluetoothConnection
                        || model.isOnboardingGreetingPresented
                )
                    .frame(width: model.surfaceSize.width, height: model.surfaceSize.height)
                    .animation(surfaceAnimation, value: model.phase)
                    .animation(surfaceAnimation, value: model.surfaceSize)
            }
        }
        .frame(
            width: IslandModel.canvasSize.width,
            height: IslandModel.canvasSize.height,
            alignment: .top
        )
        .preferredColorScheme(.dark)
        .task(id: model.showsSpotifyCompactProgress) {
            guard model.showsSpotifyCompactProgress else {
                // Expansion removes the border immediately.
                isSpotifyProgressReady = false
                spotifyProgressReveal = 0
                return
            }

            // Compact phase begins when retraction starts. Wait for its spring
            // to settle before restoring the progress edge.
            do {
                try await Task.sleep(for: .milliseconds(420))
            } catch {
                return
            }

            guard model.showsSpotifyCompactProgress else { return }
            spotifyProgressReveal = 0
            isSpotifyProgressReady = true

            // Let the zero-length path render once, then sweep it forward to
            // the live playback position. Once reveal reaches one, TimelineView
            // alone continues advancing the endpoint normally.
            await Task.yield()
            guard model.showsSpotifyCompactProgress else { return }
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.58)) {
                spotifyProgressReveal = 1
            }
        }
    }

    private var shouldShowSpotifyProgress: Bool {
        model.showsSpotifyCompactProgress && isSpotifyProgressReady
    }

    private var showsSharedMediaElements: Bool {
        switch model.phase {
        case .idle:
            false
        case .compact:
            model.isShowingCompactMedia
        case .expanded:
            model.selectedTab == .home
                && !model.isCalendarDetailPresented
                && model.hasHomeMedia
        }
    }

    private var surfaceAnimation: Animation {
        if reduceMotion {
            return .easeOut(duration: 0.16)
        }
        if model.isTimerStartTransitioning {
            // A single, non-bouncy retraction reads more like a native system
            // surface than the previous pair of short springs.
            return .timingCurve(0.22, 0.82, 0.24, 1, duration: 0.68)
        }
        return model.phase == .expanded
            ? .spring(response: 0.42, dampingFraction: 0.82, blendDuration: 0)
            : .spring(response: 0.38, dampingFraction: 1, blendDuration: 0)
    }

    private var contentFadeAnimation: Animation {
        // Finish the content hand-off before the silhouette completes its
        // spring so no translucent controls linger over the retracted notch.
        .easeOut(duration: model.phase == .expanded ? 0.14 : 0.09)
    }

    private var compactContentAnimation: Animation {
        if model.isTimerStartTransitioning {
            return reduceMotion
                ? .easeOut(duration: 0.12)
                : .easeOut(duration: 0.26).delay(0.32)
        }
        return model.phase == .compact
            ? .easeOut(duration: 0.14).delay(0.12)
            : .easeOut(duration: 0.08)
    }

    private var expandedContentAnimation: Animation {
        if model.isTimerStartTransitioning {
            return reduceMotion
                ? .easeOut(duration: 0.1)
                : .easeInOut(duration: 0.24)
        }
        if model.phase == .expanded {
            // A short delay lets the black shell lead. The small top-centered
            // spring adds depth without introducing a directional slide.
            return .spring(response: 0.34, dampingFraction: 0.9, blendDuration: 0)
                .delay(0.055)
        }
        return .easeOut(duration: 0.1)
    }

    private var renderedExpandedSurfaceSize: CGSize {
        // Hold the outgoing timer setup at its original coordinates while the
        // shell retracts. Once hidden, the running timer can adopt its smaller
        // expanded layout without producing visible reflow.
        model.isTimerStartTransitioning
            ? IslandModel.homeExpandedSurfaceSize
            : model.expandedSurfaceSize
    }

    private var expandedContentScale: CGFloat {
        if model.isTimerStartTransitioning { return 1 }
        return model.phase == .expanded ? 1 : 0.97
    }
}

private let notchBlack = Color(nsColor: NSColor(deviceWhite: 0, alpha: 1))

private enum IslandGeometry {
    static let expandedTopCornerRadius: CGFloat = 14
    static let expandedBottomCornerRadius: CGFloat = 26
    static let homeContentEdgeInset: CGFloat = 18
}

private struct IslandBackground: View {
    let phase: IslandPhase
    let usesTallCompactShape: Bool

    var body: some View {
        NotchSilhouette(
            topCornerRadius: topRadius,
            bottomCornerRadius: bottomRadius
        )
        .fill(notchBlack)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(notchBlack)
                .frame(height: 1.5)
                .padding(.horizontal, topRadius)
        }
        .compositingGroup()
    }

    private var topRadius: CGFloat {
        switch phase {
        case .idle: 6
        case .compact: 8
        case .expanded: IslandGeometry.expandedTopCornerRadius
        }
    }

    private var bottomRadius: CGFloat {
        switch phase {
        case .idle: 14
        case .compact: usesTallCompactShape ? 24 : 18
        case .expanded: IslandGeometry.expandedBottomCornerRadius
        }
    }
}

private struct SpotifyProgressBorder: View {
    let snapshot: MediaSessionSnapshot
    let isVisible: Bool
    let revealProgress: Double

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 12.0,
                paused: !isVisible || !snapshot.isPlaying
            )
        ) { context in
            SpotifyProgressCanvas(
                progress: playbackProgress(at: context.date) * revealProgress,
                revealProgress: revealProgress
            )
        }
        .accessibilityHidden(true)
    }

    private func playbackProgress(at date: Date) -> Double {
        guard let duration = snapshot.duration, duration > 0 else { return 0 }
        return min(max(snapshot.estimatedElapsedTime(at: date) / duration, 0), 1)
    }
}

private struct SpotifyProgressCanvas: View, @MainActor Animatable {
    var progress: Double
    var revealProgress: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(progress, revealProgress) }
        set {
            progress = newValue.first
            revealProgress = newValue.second
        }
    }

    private let endpointHue = Color(
        hue: 0.70,
        saturation: 0.62,
        brightness: 1
    )

    var body: some View {
        Canvas { context, size in
            let outlineRect = CGRect(origin: .zero, size: size).insetBy(dx: 12, dy: 12)
            let outline = SpotifyProgressOutline().path(
                // The Canvas receives 12 extra points on every side. Removing
                // that drawing margin produces the exact same rect used by the
                // black compact silhouette, with no visible inset or black gap.
                in: outlineRect
            )
            let fadeStart = CGPoint(x: outlineRect.minX, y: outlineRect.minY)
            let fadeEnd = CGPoint(x: outlineRect.minX + 8, y: outlineRect.minY + 16)

            context.stroke(
                outline,
                with: .linearGradient(
                    Gradient(colors: [
                        .white.opacity(0),
                        .white.opacity(0.07 * revealProgress)
                    ]),
                    startPoint: fadeStart,
                    endPoint: fadeEnd
                ),
                style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
            )

            guard progress > 0 else { return }
            let completed = outline.trimmedPath(from: 0, to: progress)
            context.stroke(
                completed,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: .white.opacity(0), location: 0),
                        .init(color: .white.opacity(0.28), location: 0.38),
                        .init(color: .white.opacity(0.82), location: 1)
                    ]),
                    startPoint: fadeStart,
                    endPoint: fadeEnd
                ),
                style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round)
            )

            guard let endpoint = completed.currentPoint else { return }
            let outerGlowRect = CGRect(
                x: endpoint.x - 7,
                y: endpoint.y - 4,
                width: 14,
                height: 8
            )
            let innerGlowRect = CGRect(
                x: endpoint.x - 3.5,
                y: endpoint.y - 2,
                width: 7,
                height: 4
            )

            context.drawLayer { outerGlow in
                outerGlow.addFilter(.blur(radius: 5))
                outerGlow.fill(
                    Path(ellipseIn: outerGlowRect),
                    with: .color(endpointHue.opacity(0.72))
                )
            }

            context.drawLayer { innerGlow in
                innerGlow.addFilter(.blur(radius: 2))
                innerGlow.fill(
                    Path(ellipseIn: innerGlowRect),
                    with: .color(.white.opacity(0.9))
                )
            }
        }
    }
}

struct SpotifyProgressOutline: Shape {
    func path(in rect: CGRect) -> Path {
        let topCornerRadius: CGFloat = 8
        let bottomCornerRadius: CGFloat = 18
        var path = Path()

        // Leave the top edge open because it visually belongs to the physical
        // display cutout. Playback advances from its left edge, around the
        // visible island, and finishes at the right edge.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY)
        )
        path.addLine(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius)
        )
        path.addQuadCurve(
            to: CGPoint(
                x: rect.minX + topCornerRadius + bottomCornerRadius,
                y: rect.maxY
            ),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY)
        )
        path.addLine(
            to: CGPoint(
                x: rect.maxX - topCornerRadius - bottomCornerRadius,
                y: rect.maxY
            )
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY)
        )
        path.addLine(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY)
        )

        return path
    }
}

private struct NotchSilhouette: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

private struct CompactIslandView: View {
    @Bindable var model: IslandModel

    private let edgeInset: CGFloat = 15

    var body: some View {
        ZStack {
            if model.isOnboardingGreetingPresented {
                Button(action: model.openOnboarding) {
                    OnboardingGreetingCompactView()
                }
                .buttonStyle(.plain)
                .transition(
                    .opacity.combined(
                        with: .scale(scale: 0.94, anchor: .bottom)
                    )
                )
                .accessibilityLabel("Welcome to Ledge. Open the welcome tour.")
            } else if let event = model.bluetoothConnectionEvent {
                BluetoothConnectedCompactView(event: event)
                    .id(event.id)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(
                                with: .scale(scale: 0.94, anchor: .bottom)
                            ),
                            removal: .opacity
                        )
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Connected, \(event.deviceName)")
            } else if model.isTimerActive {
                HStack(spacing: 0) {
                    Image(systemName: "timer")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.orange)

                    Spacer(minLength: 0)

                    Text(formattedTimerRemaining)
                        .font(.system(size: 18, weight: .medium, design: .rounded))
                        .foregroundStyle(.orange)
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.linear(duration: 0.2), value: Int(model.timerRemaining))
                }
                .padding(.horizontal, 10)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Timer, \(formattedTimerRemaining) remaining")
            } else {
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: 27, height: 27)

                    Spacer(minLength: 0)

                    Color.clear
                        .frame(width: 20, height: 16)
                }
                .transition(.opacity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "Playing \(model.homeMediaSnapshot.title) by \(model.homeMediaSnapshot.artist)"
                )
            }
        }
        // The silhouette's compact side begins eight points inside its outer
        // frame, leaving an equal seven-point visual gap on both sides.
        .padding(.horizontal, edgeInset)
        .animation(.easeInOut(duration: 0.18), value: model.isTimerActive)
        .animation(.spring(response: 0.36, dampingFraction: 0.9), value: model.isOnboardingGreetingPresented)
        .animation(bluetoothContentAnimation, value: model.bluetoothConnectionEvent?.id)
    }

    private var bluetoothContentAnimation: Animation {
        model.isShowingBluetoothConnection
            ? .spring(response: 0.34, dampingFraction: 0.88, blendDuration: 0)
                .delay(0.07)
            : .easeOut(duration: 0.1)
    }

    private var formattedTimerRemaining: String {
        let seconds = max(0, Int(model.timerRemaining.rounded()))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct OnboardingGreetingCompactView: View {
    @State private var drawingProgress: CGFloat = 0

    var body: some View {
        VStack(spacing: -5) {
            AppleHelloShape()
                .trim(from: 0, to: drawingProgress)
                .stroke(
                    Self.helloGradient,
                    style: StrokeStyle(
                        lineWidth: 3.2,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .frame(width: 218, height: 75)
                .drawingGroup()

            Text("Welcome to Ledge")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .tracking(0.1)
        }
        .padding(.top, 32)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .contentShape(Rectangle())
        .onAppear {
            drawingProgress = 0
            withAnimation(.easeInOut(duration: 3).delay(0.18)) {
                drawingProgress = 1
            }
        }
    }

    private static let helloGradient = LinearGradient(
        colors: [
            .black,
            .green,
            .yellow,
            .orange,
            .red,
            .pink,
            .purple,
            .blue,
            .black
        ],
        startPoint: .leading,
        endPoint: .trailing
    )
}

// The normalized Bézier path and trim animation approach are adapted from
// mtynior/AppleHello (MIT). See ACKNOWLEDGEMENTS.md.
private struct AppleHelloShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width
        let height = rect.height

        path.move(to: CGPoint(x: 0.18942 * width, y: 0.64916 * height))
        path.addCurve(to: CGPoint(x: 0.27418 * width, y: 0.51669 * height), control1: CGPoint(x: 0.27418 * width, y: 0.51669 * height), control2: CGPoint(x: 0.23809 * width, y: 0.59394 * height))
        path.addCurve(to: CGPoint(x: 0.30536 * width, y: 0.34281 * height), control1: CGPoint(x: 0.30196 * width, y: 0.45722 * height), control2: CGPoint(x: 0.31651 * width, y: 0.37724 * height))
        path.addCurve(to: CGPoint(x: 0.24651 * width, y: 0.67414 * height), control1: CGPoint(x: 0.26479 * width, y: 0.21753 * height), control2: CGPoint(x: 0.24062 * width, y: 0.67407 * height))
        path.addCurve(to: CGPoint(x: 0.28192 * width, y: 0.5111 * height), control1: CGPoint(x: 0.2524 * width, y: 0.6742 * height), control2: CGPoint(x: 0.25206 * width, y: 0.54125 * height))
        path.addCurve(to: CGPoint(x: 0.32367 * width, y: 0.53984 * height), control1: CGPoint(x: 0.31178 * width, y: 0.48094 * height), control2: CGPoint(x: 0.3223 * width, y: 0.52111 * height))
        path.addCurve(to: CGPoint(x: 0.31839 * width, y: 0.6355 * height), control1: CGPoint(x: 0.32589 * width, y: 0.57011 * height), control2: CGPoint(x: 0.31687 * width, y: 0.61804 * height))
        path.addCurve(to: CGPoint(x: 0.43599 * width, y: 0.55398 * height), control1: CGPoint(x: 0.32473 * width, y: 0.70854 * height), control2: CGPoint(x: 0.42787 * width, y: 0.63682 * height))
        path.addCurve(to: CGPoint(x: 0.3834 * width, y: 0.61147 * height), control1: CGPoint(x: 0.44471 * width, y: 0.46492 * height), control2: CGPoint(x: 0.3683 * width, y: 0.46917 * height))
        path.addCurve(to: CGPoint(x: 0.4418 * width, y: 0.66942 * height), control1: CGPoint(x: 0.38895 * width, y: 0.66377 * height), control2: CGPoint(x: 0.42346 * width, y: 0.67724 * height))
        path.addCurve(to: CGPoint(x: 0.552 * width, y: 0.38575 * height), control1: CGPoint(x: 0.50813 * width, y: 0.64115 * height), control2: CGPoint(x: 0.55363 * width, y: 0.49671 * height))
        path.addCurve(to: CGPoint(x: 0.49571 * width, y: 0.60864 * height), control1: CGPoint(x: 0.54988 * width, y: 0.24203 * height), control2: CGPoint(x: 0.47856 * width, y: 0.38729 * height))
        path.addCurve(to: CGPoint(x: 0.57499 * width, y: 0.64351 * height), control1: CGPoint(x: 0.50232 * width, y: 0.69393 * height), control2: CGPoint(x: 0.55841 * width, y: 0.66619 * height))
        path.addCurve(to: CGPoint(x: 0.64978 * width, y: 0.36314 * height), control1: CGPoint(x: 0.60564 * width, y: 0.60157 * height), control2: CGPoint(x: 0.65966 * width, y: 0.48059 * height))
        path.addCurve(to: CGPoint(x: 0.59745 * width, y: 0.62607 * height), control1: CGPoint(x: 0.63947 * width, y: 0.24062 * height), control2: CGPoint(x: 0.56181 * width, y: 0.44249 * height))
        path.addCurve(to: CGPoint(x: 0.6548 * width, y: 0.65717 * height), control1: CGPoint(x: 0.60934 * width, y: 0.68733 * height), control2: CGPoint(x: 0.64502 * width, y: 0.6666 * height))
        path.addCurve(to: CGPoint(x: 0.70474 * width, y: 0.51817 * height), control1: CGPoint(x: 0.67802 * width, y: 0.6348 * height), control2: CGPoint(x: 0.6855 * width, y: 0.5536 * height))
        path.addCurve(to: CGPoint(x: 0.76896 * width, y: 0.5601 * height), control1: CGPoint(x: 0.72906 * width, y: 0.4734 * height), control2: CGPoint(x: 0.76738 * width, y: 0.50686 * height))
        path.addCurve(to: CGPoint(x: 0.70263 * width, y: 0.65105 * height), control1: CGPoint(x: 0.77246 * width, y: 0.67742 * height), control2: CGPoint(x: 0.72159 * width, y: 0.67749 * height))
        path.addCurve(to: CGPoint(x: 0.70448 * width, y: 0.51817 * height), control1: CGPoint(x: 0.68627 * width, y: 0.62823 * height), control2: CGPoint(x: 0.68244 * width, y: 0.56022 * height))
        path.addCurve(to: CGPoint(x: 0.7753 * width, y: 0.52099 * height), control1: CGPoint(x: 0.71954 * width, y: 0.48942 * height), control2: CGPoint(x: 0.74363 * width, y: 0.48871 * height))
        path.addCurve(to: CGPoint(x: 0.80807 * width, y: 0.51063 * height), control1: CGPoint(x: 0.78825 * width, y: 0.53419 * height), control2: CGPoint(x: 0.79935 * width, y: 0.53183 * height))
        return path
    }
}

private struct BluetoothConnectedCompactView: View {
    let event: BluetoothConnectionEvent

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: event.kind.systemImage)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(.white.opacity(0.94))
                .frame(width: 32, height: 30)
                .shadow(color: .white.opacity(0.12), radius: 7)

            VStack(alignment: .leading, spacing: 1) {
                Text("Connected")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))

                Text(event.deviceName)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.96))
                    .lineLimit(1)
                    .minimumScaleFactor(0.84)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.horizontal, 4)
        .padding(.bottom, 8)
    }
}

private struct AnimatedWaveform: View {
    let isAnimating: Bool
    let levels: [Double]
    let hasLiveLevels: Bool

    var body: some View {
        ZStack {
            TimelineView(
                .animation(
                    minimumInterval: 1.0 / 12.0,
                    paused: !isAnimating || hasLiveLevels
                )
            ) { context in
                DecorativeWaveformBars(
                    time: context.date.timeIntervalSinceReferenceDate,
                    isAnimating: isAnimating
                )
            }
            .opacity(hasLiveLevels ? 0 : 1)

            LiveWaveformBars(levels: levels)
                .opacity(hasLiveLevels ? 1 : 0)
        }
        .frame(width: 20, height: 16)
        .animation(.easeOut(duration: 0.14), value: hasLiveLevels)
        .accessibilityHidden(true)
    }
}

private struct LiveWaveformBars: View {
    let levels: [Double]

    var body: some View {
        WaveformBarStack { index in
            let level = levels.indices.contains(index) ? levels[index] : 0
            return CGFloat(3 + min(max(level, 0), 1) * 11)
        }
        .animation(.easeOut(duration: 0.075), value: levels)
    }
}

private struct DecorativeWaveformBars: View {
    let time: TimeInterval
    let isAnimating: Bool

    var body: some View {
        WaveformBarStack { index in
            guard isAnimating else { return 3 }
            let frequency = 3.5 + Double(index) * 0.18
            let wave = sin(time * frequency + Double(index) * 1.15)
            return CGFloat(4 + abs(wave) * 10)
        }
    }
}

private struct WaveformBarStack: View {
    let height: (Int) -> CGFloat

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.88))
                    .frame(width: 2, height: height(index))
            }
        }
        .frame(width: 20, height: 16)
    }
}

private struct SharedArtwork: View {
    @Bindable var model: IslandModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            ArtworkView(
                snapshot: model.homeMediaSnapshot,
                size: artworkSize,
                cornerRadius: artworkCornerRadius
            )
            .position(artworkPosition)
            .animation(artworkAnimation, value: model.phase)
        }
        .frame(
            width: IslandModel.canvasSize.width,
            height: IslandModel.canvasSize.height,
            alignment: .topLeading
        )
    }

    private var artworkSize: CGFloat {
        model.phase == .expanded ? 136 : 27
    }

    private var artworkCornerRadius: CGFloat {
        model.phase == .expanded ? IslandGeometry.expandedBottomCornerRadius : 7
    }

    private var artworkPosition: CGPoint {
        guard model.phase == .expanded else {
            let compactOriginX = (
                IslandModel.canvasSize.width - model.mediaCompactSurfaceSize.width
            ) / 2
            return CGPoint(
                x: compactOriginX + 28.5,
                y: model.mediaCompactSurfaceSize.height / 2
            )
        }
        return expandedArtworkPosition
    }

    private var expandedArtworkPosition: CGPoint {
        let surfaceOriginX = (
            IslandModel.canvasSize.width - IslandModel.homeExpandedSurfaceSize.width
        ) / 2
        return CGPoint(x: surfaceOriginX + 100, y: 116)
    }

    private var artworkAnimation: Animation {
        model.phase == .expanded
            ? .spring(response: 0.42, dampingFraction: 0.86, blendDuration: 0)
            : .spring(response: 0.38, dampingFraction: 0.94, blendDuration: 0)
    }
}

private struct ExpandedArtworkAmbient: View {
    @Bindable var model: IslandModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let artwork = model.homeMediaSnapshot.artwork {
                ArtworkAmbientColorField(artwork: artwork)
                    .position(ambientPosition)
                    .opacity(isVisible ? 1 : 0)
                    .animation(ambientAnimation, value: isVisible)
            }
        }
        .frame(
            width: IslandModel.canvasSize.width,
            height: IslandModel.canvasSize.height,
            alignment: .topLeading
        )
    }

    private var isVisible: Bool {
        model.phase == .expanded
            && model.selectedTab == .home
            && !model.isCalendarDetailPresented
            && model.hasHomeMedia
    }

    private var ambientPosition: CGPoint {
        let surfaceOriginX = (
            IslandModel.canvasSize.width - IslandModel.homeExpandedSurfaceSize.width
        ) / 2
        // Bias the color field into the media section instead of tracing the
        // artwork perimeter evenly.
        return CGPoint(x: surfaceOriginX + 122, y: 122)
    }

    private var ambientAnimation: Animation {
        isVisible
            ? .easeOut(duration: 0.32).delay(0.09)
            : .easeOut(duration: 0.07)
    }
}

private struct ArtworkAmbientColorField: View {
    let artwork: NSImage

    var body: some View {
        Image(nsImage: artwork)
            .resizable()
            .scaledToFill()
            .frame(width: 190, height: 180)
            .clipped()
            .saturation(1.3)
            .contrast(1.04)
            .blur(radius: 34)
            .opacity(0.24)
            .frame(width: 260, height: 220)
            .mask {
                RadialGradient(
                    stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white.opacity(0.82), location: 0.42),
                        .init(color: .white.opacity(0.34), location: 0.72),
                        .init(color: .clear, location: 1)
                    ],
                    center: .center,
                    startRadius: 20,
                    endRadius: 128
                )
            }
            .accessibilityHidden(true)
    }
}

private struct PhasedWaveforms: View {
    @Bindable var model: IslandModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            AnimatedWaveform(
                isAnimating: model.homeMediaSnapshot.isPlaying,
                levels: model.audioLevels,
                hasLiveLevels: model.hasLiveAudioLevels
            )
            .position(compactPosition)
            .opacity(showsCompactWaveform ? 1 : 0)
            .animation(compactOpacityAnimation, value: showsCompactWaveform)

            AnimatedWaveform(
                isAnimating: model.homeMediaSnapshot.isPlaying,
                levels: model.audioLevels,
                hasLiveLevels: model.hasLiveAudioLevels
            )
            .position(expandedPosition)
            .opacity(showsExpandedWaveform ? 1 : 0)
            .animation(expandedOpacityAnimation, value: showsExpandedWaveform)
        }
        .frame(
            width: IslandModel.canvasSize.width,
            height: IslandModel.canvasSize.height,
            alignment: .topLeading
        )
    }

    private var showsCompactWaveform: Bool {
        model.isShowingCompactMedia
    }

    private var showsExpandedWaveform: Bool {
        model.phase == .expanded
            && model.selectedTab == .home
            && !model.isCalendarDetailPresented
            && model.hasHomeMedia
    }

    private var compactOpacityAnimation: Animation {
        showsCompactWaveform
            ? .easeOut(duration: 0.15).delay(0.16)
            : .easeOut(duration: 0.08)
    }

    private var expandedOpacityAnimation: Animation {
        showsExpandedWaveform
            ? .easeOut(duration: 0.15).delay(0.09)
            : .easeOut(duration: 0.08)
    }

    private var compactPosition: CGPoint {
        let width = model.mediaCompactSurfaceSize.width
        let height = model.mediaCompactSurfaceSize.height
        let originX = (IslandModel.canvasSize.width - width) / 2
        return CGPoint(x: originX + width - 25, y: height / 2)
    }

    private var expandedPosition: CGPoint {
        let surfaceOriginX = (
            IslandModel.canvasSize.width - IslandModel.homeExpandedSurfaceSize.width
        ) / 2
        return CGPoint(x: surfaceOriginX + 406, y: 64)
    }
}

private struct ExpandedTabbedView: View {
    @Bindable var model: IslandModel

    var body: some View {
        VStack(spacing: 0) {
            if model.isCalendarDetailPresented {
                CalendarDetailHeader(model: model)
                    .frame(height: 50)
            } else {
                IslandTabBar(model: model)
                    .frame(height: 44)
            }

            ZStack {
                if model.isCalendarDetailPresented {
                    CalendarDetailView(model: model)
                        .transition(contentTransition)
                } else {
                    switch model.selectedTab {
                    case .home:
                        HomeTabView(model: model)
                            .transition(contentTransition)
                    case .clipboard:
                        ClipboardTabView(model: model)
                            .transition(contentTransition)
                    case .timer:
                        TimerTabView(model: model)
                            .transition(contentTransition)
                    case .agentic:
                        AgenticTabView(model: model)
                            .transition(contentTransition)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.88), value: model.selectedTab)
        .animation(.spring(response: 0.4, dampingFraction: 0.9), value: model.isCalendarDetailPresented)
    }

    private var contentTransition: AnyTransition {
        // Directional moves compete with the centered notch morph when a tab
        // is selected as expansion begins. A restrained crossfade and scale
        // keeps every tab at its final coordinates, matching Home's reveal.
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.985, anchor: .top)),
            removal: .opacity
        )
    }
}

private struct IslandTabBar: View {
    @Bindable var model: IslandModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(model.visibleTabs) { tab in
                Button {
                    model.selectTab(tab)
                } label: {
                    IslandTabIcon(tab: tab)
                        .foregroundStyle(.white.opacity(model.selectedTab == tab ? 1 : 0.42))
                        .frame(width: 32, height: 30)
                        .background(
                            Capsule(style: .continuous)
                                .fill(.white.opacity(model.selectedTab == tab ? 0.1 : 0))
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
            }

            Spacer()

            IslandTabAccessory(model: model)
        }
        .padding(.horizontal, 22)
        .padding(.top, 4)
        .animation(.easeInOut(duration: 0.18), value: model.selectedTab)
    }
}

private struct IslandTabAccessory: View {
    @Bindable var model: IslandModel

    @ViewBuilder
    var body: some View {
        switch model.selectedTab {
        case .home:
            Button {
                model.openSettings()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))
                    .frame(width: 32, height: 30)
                    .background(
                        Capsule(style: .continuous)
                            .fill(.white.opacity(0.065))
                    )
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Open Settings")
            .accessibilityLabel("Open Settings")
            .transition(.scale(scale: 0.88).combined(with: .opacity))
        case .clipboard:
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                    model.clearClipboardTextHistory()
                }
            } label: {
                Image(systemName: "document.on.trash.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        model.textClipboardEntries.isEmpty
                            ? Color.white.opacity(0.18)
                            : Color.red.opacity(0.82)
                    )
                    .frame(width: 32, height: 30)
                    .background(
                        Capsule(style: .continuous)
                            .fill(.white.opacity(model.textClipboardEntries.isEmpty ? 0.025 : 0.07))
                    )
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(model.textClipboardEntries.isEmpty)
            .help("Clear copied text history")
            .accessibilityLabel("Clear copied text history")
            .transition(.scale(scale: 0.88).combined(with: .opacity))
        case .agentic:
            Group {
                if model.enabledAgentProviders.isEmpty {
                    Button {
                        model.openSettings()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 32, height: 30)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(.white.opacity(0.07))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Choose agent providers")
                } else {
                    let isRefreshing = model.selectedAgentProvider == .codex
                        ? model.isCodexUsageRefreshing
                        : model.isClaudeUsageRefreshing
                    Button {
                        model.refreshSelectedAgentUsage()
                    } label: {
                        Group {
                            if isRefreshing {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white.opacity(0.76))
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                        }
                        .frame(width: 32, height: 30)
                        .background(
                            Capsule(style: .continuous)
                                .fill(.white.opacity(0.07))
                        )
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isRefreshing)
                    .help("Refresh \(model.selectedAgentProvider.title) usage")
                    .accessibilityLabel("Refresh \(model.selectedAgentProvider.title) usage")
                }
            }
            .transition(.scale(scale: 0.88).combined(with: .opacity))
        case .timer:
            EmptyView()
        }
    }
}

private struct IslandTabIcon: View {
    let tab: IslandTab

    var body: some View {
        Group {
            if tab == .agentic {
                AgentTabGlyph()
                    .frame(width: 24, height: 22)
            } else {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 14, weight: .semibold))
            }
        }
    }
}

private struct AgentTabGlyph: View {
    var body: some View {
        AgentTabGlyphShape()
            .stroke(
                style: StrokeStyle(
                    lineWidth: 1.45,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
    }
}

private struct AgentTabGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sourceSize = CGSize(width: 24, height: 22)
        let scale = min(rect.width / sourceSize.width, rect.height / sourceSize.height)
        let x = rect.midX - sourceSize.width * scale / 2
        let y = rect.midY - sourceSize.height * scale / 2

        func mapped(_ source: CGRect) -> CGRect {
            CGRect(
                x: x + source.minX * scale,
                y: y + source.minY * scale,
                width: source.width * scale,
                height: source.height * scale
            )
        }

        var path = Path()
        path.addRoundedRect(
            in: mapped(CGRect(x: 3, y: 7, width: 18, height: 13)),
            cornerSize: CGSize(width: 2.1 * scale, height: 2.1 * scale)
        )
        path.addRoundedRect(
            in: mapped(CGRect(x: 0.7, y: 10, width: 2.3, height: 7)),
            cornerSize: CGSize(width: 0.8 * scale, height: 0.8 * scale)
        )
        path.addRoundedRect(
            in: mapped(CGRect(x: 21, y: 10, width: 2.3, height: 7)),
            cornerSize: CGSize(width: 0.8 * scale, height: 0.8 * scale)
        )
        path.addEllipse(in: mapped(CGRect(x: 6.5, y: 12, width: 3, height: 3)))
        path.addEllipse(in: mapped(CGRect(x: 14.5, y: 12, width: 3, height: 3)))
        path.addEllipse(in: mapped(CGRect(x: 10, y: 0.5, width: 4, height: 4)))
        path.move(to: CGPoint(x: x + 12 * scale, y: y + 4.5 * scale))
        path.addLine(to: CGPoint(x: x + 12 * scale, y: y + 7 * scale))
        return path
    }
}

private struct AgenticTabView: View {
    @Bindable var model: IslandModel

    var body: some View {
        VStack(spacing: 6) {
            if model.enabledAgentProviders.isEmpty {
                AgentProvidersDisabledState(model: model)
            } else {
                if model.enabledAgentProviders.count > 1 {
                    AgentProviderSwitcher(model: model)
                        .frame(height: 27)
                }

                switch model.selectedAgentProvider {
                case .codex:
                    AgentProviderUsageRow(provider: .codex) {
                        if shouldShowSetup(for: .codex) {
                            AgentUsageEmptyState(
                                provider: .codex,
                                isRefreshing: model.isCodexUsageRefreshing,
                                state: model.codexConnectionState,
                                errorMessage: model.codexUsageErrorMessage,
                                onPrimaryAction: codexPrimaryAction,
                                onRefresh: model.refreshCodexUsage
                            )
                        } else if let snapshot = model.codexUsageSnapshot {
                            AgentUsageDetails(
                                provider: .codex,
                                usedPercent: snapshot.usedPercent,
                                resetDate: snapshot.resetDate,
                                updatedAt: snapshot.updatedAt,
                                planType: snapshot.planType,
                                errorMessage: model.codexUsageErrorMessage
                            )
                        } else {
                            AgentUsageEmptyState(
                                provider: .codex,
                                isRefreshing: model.isCodexUsageRefreshing,
                                state: model.codexConnectionState,
                                errorMessage: model.codexUsageErrorMessage,
                                onPrimaryAction: codexPrimaryAction,
                                onRefresh: model.refreshCodexUsage
                            )
                        }
                    }
                case .claude:
                    AgentProviderUsageRow(provider: .claude) {
                        if shouldShowSetup(for: .claude) {
                            AgentUsageEmptyState(
                                provider: .claude,
                                isRefreshing: model.isClaudeUsageRefreshing,
                                state: model.claudeConnectionState,
                                errorMessage: model.claudeUsageErrorMessage,
                                isProviderConnected: model.isClaudeIntegrationEnabled,
                                onPrimaryAction: claudePrimaryAction,
                                onRefresh: model.refreshClaudeUsage
                            )
                        } else if let snapshot = model.claudeUsageSnapshot {
                            AgentUsageDetails(
                                provider: .claude,
                                usedPercent: snapshot.usedPercent,
                                resetDate: snapshot.resetDate,
                                updatedAt: snapshot.updatedAt,
                                planType: snapshot.planType,
                                errorMessage: model.claudeUsageErrorMessage
                            )
                        } else {
                            AgentUsageEmptyState(
                                provider: .claude,
                                isRefreshing: model.isClaudeUsageRefreshing,
                                state: model.claudeConnectionState,
                                errorMessage: model.claudeUsageErrorMessage,
                                isProviderConnected: model.isClaudeIntegrationEnabled,
                                onPrimaryAction: claudePrimaryAction,
                                onRefresh: model.refreshClaudeUsage
                            )
                        }
                    }
                }
            }
        }
        .padding(.leading, IslandGeometry.expandedTopCornerRadius + IslandGeometry.homeContentEdgeInset)
        .padding(.trailing, 28)
        .padding(.top, 1)
        .padding(.bottom, IslandGeometry.homeContentEdgeInset)
        .frame(maxWidth: .infinity, minHeight: 155, maxHeight: 155)
        .animation(.easeInOut(duration: 0.2), value: model.selectedAgentProvider)
    }

    private func shouldShowSetup(for provider: AgentProvider) -> Bool {
        if provider == .claude {
            return !model.isClaudeIntegrationEnabled
        }
        let state = provider == .codex
            ? model.codexConnectionState
            : model.claudeConnectionState
        return state == .notInstalled || state == .signInRequired
    }

    private func codexPrimaryAction() {
        switch model.codexConnectionState {
        case .notInstalled, .signInRequired: model.setUpCodex()
        case .checking, .connected, .unavailable: model.refreshCodexUsage()
        }
    }

    private func claudePrimaryAction() {
        model.isClaudeIntegrationEnabled
            ? model.refreshClaudeUsage()
            : model.connectClaude()
    }
}

private struct AgentProviderSwitcher: View {
    @Bindable var model: IslandModel

    var body: some View {
        HStack(spacing: 5) {
            ForEach(model.enabledAgentProviders) { provider in
                Button {
                    model.selectAgentProvider(provider)
                } label: {
                    AgentProviderIcon(provider)
                        .frame(width: 18, height: 18)
                        .frame(width: 42, height: 25)
                        .background(
                            Capsule(style: .continuous)
                                .fill(
                                    .white.opacity(
                                        model.selectedAgentProvider == provider ? 0.11 : 0.035
                                    )
                                )
                        )
                        .overlay {
                            if model.selectedAgentProvider == provider {
                                Capsule(style: .continuous)
                                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.6)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(provider.title)
                .accessibilityLabel(provider.title)
            }
        }
        .padding(2)
        .background(
            Capsule(style: .continuous)
                .fill(.white.opacity(0.025))
        )
        .frame(maxWidth: .infinity)
    }
}

private struct AgentProviderUsageRow<Content: View>: View {
    let provider: AgentProvider
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 14) {
            AgentProviderIcon(provider)
                .frame(width: 76, height: 76)
                .shadow(
                    color: provider == .codex
                        ? Color.indigo.opacity(0.16)
                        : Color.orange.opacity(0.14),
                    radius: 16
                )

            content
        }
        .frame(maxWidth: .infinity, minHeight: 103, maxHeight: 103, alignment: .leading)
        .transition(.opacity.combined(with: .scale(scale: 0.985)))
    }
}

private struct AgentUsageDetails: View {
    let provider: AgentProvider
    let usedPercent: Double
    let resetDate: Date?
    let updatedAt: Date
    let planType: String?
    let errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(provider.title.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.4))

                    Text("7-day limit")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.94))
                }

                Spacer()

                Text("\(Int(remainingPercent.rounded()))%")
                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)

                Text("remaining")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.46))
            }

            AgentUsageProgressBar(provider: provider, progress: remainingPercent / 100)
                .frame(height: 8)
                .padding(.top, 7)

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(resetDescription)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))

                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(errorMessage == nil ? Color.green.opacity(0.82) : Color.orange)
                                .frame(width: 4.5, height: 4.5)
                            Text(freshnessDescription(at: context.date))
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.38))
                        }
                    }
                }

                Spacer()

                if let plan = planType, !plan.isEmpty {
                    Text(plan.uppercased())
                        .font(.system(size: 8, weight: .bold))
                        .tracking(0.75)
                        .foregroundStyle(.white.opacity(0.48))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            Capsule(style: .continuous)
                                .fill(.white.opacity(0.065))
                        )
                }
            }
            .padding(.top, 7)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .fill(.white.opacity(0.032))
                .overlay {
                    RoundedRectangle(cornerRadius: 21, style: .continuous)
                        .strokeBorder(.white.opacity(0.06), lineWidth: 0.7)
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(provider.title) seven day limit, \(Int(remainingPercent.rounded())) percent remaining, \(resetDescription)"
        )
    }

    private var remainingPercent: Double {
        min(max(100 - usedPercent, 0), 100)
    }

    private var resetDescription: String {
        guard let resetDate else {
            return usedPercent <= 0.001 ? "No active reset" : "Reset time unavailable"
        }
        return "Resets " + resetDate.formatted(
            .dateTime
                .weekday(.abbreviated)
                .month(.abbreviated)
                .day()
                .hour()
                .minute()
        )
    }

    private func freshnessDescription(at now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(updatedAt))
        if seconds < 60 { return "Updated now" }
        if seconds < 3_600 { return "Updated \(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "Updated \(Int(seconds / 3_600))h ago" }
        return "Updated \(Int(seconds / 86_400))d ago"
    }
}

private struct AgentUsageProgressBar: View {
    let provider: AgentProvider
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(.white.opacity(0.09))

                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: progressColor,
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(10, proxy.size.width * min(max(progress, 0), 1)))
                    .shadow(color: progressColor.last?.opacity(0.5) ?? .clear, radius: 7)
            }
        }
        .animation(.spring(response: 0.55, dampingFraction: 0.9), value: progress)
        .accessibilityHidden(true)
    }

    private var progressColor: [Color] {
        if progress < 0.2 { return [.orange, .red] }
        if progress < 0.4 { return [.yellow, .orange] }
        switch provider {
        case .codex:
            return [Color(red: 0.35, green: 0.72, blue: 1), Color(red: 0.42, green: 0.44, blue: 1)]
        case .claude:
            return [Color(red: 0.95, green: 0.58, blue: 0.35), Color(red: 0.88, green: 0.39, blue: 0.27)]
        }
    }
}

private struct AgentUsageEmptyState: View {
    let provider: AgentProvider
    let isRefreshing: Bool
    let state: AgentConnectionState
    let errorMessage: String?
    var isProviderConnected = false
    let onPrimaryAction: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: stateIcon)
                        .foregroundStyle(stateColor)
                }

                Text(title)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.48))
                .lineLimit(2)

            if !isRefreshing {
                HStack(spacing: 8) {
                    if let primaryActionTitle {
                        Button(primaryActionTitle) {
                            onPrimaryAction()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(provider == .codex ? Color(red: 0.28, green: 0.52, blue: 1) : .orange)
                    }

                    if provider != .claude
                        && (state == .notInstalled || state == .signInRequired) {
                        Button("Check Again") {
                            onRefresh()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .fill(.white.opacity(0.032))
        )
    }

    private var title: String {
        if isRefreshing { return "Checking \(provider.title)" }
        if provider == .claude {
            if !isProviderConnected { return "Connect Claude" }
            if state == .signInRequired { return "Waiting for Claude" }
            if state == .connected, errorMessage != nil { return "Waiting for Claude Code" }
        }
        return switch state {
        case .checking: "Connect \(provider.title)"
        case .connected: "Usage is getting ready"
        case .notInstalled: "Bring \(provider.title) into Ledge"
        case .signInRequired: "Finish connecting \(provider.title)"
        case .unavailable: "\(provider.title) couldn't be reached"
        }
    }

    private var detail: String {
        if isRefreshing {
            return "Reading your seven-day allowance securely from \(provider.title)."
        }
        if provider == .claude {
            if !isProviderConnected {
                return "Connect once to display your seven-day allowance using Claude already on this Mac."
            }
            if let errorMessage { return errorMessage }
        }
        return switch state {
        case .checking:
            "Connect \(provider.title) to keep your seven-day allowance visible at a glance."
        case .connected:
            "\(provider.title) is connected. Refresh once more to load your current allowance."
        case .notInstalled:
            provider == .claude
                ? "Install Claude Code or Claude Desktop to finish setup."
                : "Install \(provider.title) and sign in. Your usage stays local and appears here automatically."
        case .signInRequired:
            provider == .claude
                ? "Open Claude and complete sign-in, then check again."
                : "Open Codex, complete sign-in, then return here and check again."
        case .unavailable:
            errorMessage ?? "\(provider.title) is installed, but its usage service is temporarily unavailable."
        }
    }

    private var stateIcon: String {
        switch state {
        case .notInstalled: "arrow.down.app.fill"
        case .signInRequired: "person.crop.circle.badge.exclamationmark"
        case .unavailable: "exclamationmark.triangle.fill"
        case .checking, .connected: "sparkles"
        }
    }

    private var stateColor: Color {
        switch state {
        case .notInstalled, .checking, .connected:
            provider == .codex ? Color(red: 0.35, green: 0.68, blue: 1) : .orange
        case .signInRequired: .orange
        case .unavailable: .red
        }
    }

    private var primaryActionTitle: String? {
        if provider == .claude {
            return isProviderConnected ? "Check Again" : "Connect Claude"
        }
        return switch state {
        case .notInstalled: "Get \(provider.title)"
        case .signInRequired: "Open \(provider.title)"
        case .checking, .connected, .unavailable: "Try Again"
        }
    }
}

private struct AgentProvidersDisabledState: View {
    @Bindable var model: IslandModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "cpu")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
            Text("No agent providers are visible")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
            Button("Choose Providers") {
                model.openSettings()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HomeTabView: View {
    @Bindable var model: IslandModel

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            HomeMediaSection(model: model)
                .frame(width: 384, height: 136, alignment: .top)

            CalendarSummarySection(model: model)
                .frame(maxWidth: .infinity, minHeight: 136, maxHeight: 136, alignment: .top)
        }
        // The expanded silhouette's visible side begins after its 14-point
        // shoulder. A 32-point frame inset therefore leaves the same visible
        // 18-point gap used below the artwork.
        .padding(.leading, IslandGeometry.expandedTopCornerRadius + IslandGeometry.homeContentEdgeInset)
        .padding(.trailing, 26)
        .padding(.top, 4)
        .padding(.bottom, IslandGeometry.homeContentEdgeInset)
        .overlay(alignment: .bottomTrailing) {
            Button {
                openCalendar()
            } label: {
                Image(systemName: "calendar")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 30, height: 30)
                    .background(
                        Circle()
                            .fill(.white.opacity(0.14))
                    )
                    .overlay(
                        Circle()
                            .stroke(.white.opacity(0.12), lineWidth: 0.75)
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Open Calendar")
            .accessibilityLabel("Open Calendar")
            // Home's layout extends through the 14-point top shoulder on the
            // right. Compensate for it so the visible right and bottom gaps
            // around the button are both 12 points.
            .padding(.trailing, IslandGeometry.expandedTopCornerRadius + 12)
            .padding(.bottom, 12)
        }
    }

    private func openCalendar() {
        if model.calendarAccessState == .authorized {
            model.presentCalendarDetail()
        } else {
            model.requestCalendarAccess()
        }
    }
}

private struct HomeMediaSection: View {
    @Bindable var model: IslandModel

    var body: some View {
        if model.hasHomeMedia {
            let snapshot = model.homeMediaSnapshot
            HStack(alignment: .top, spacing: 14) {
                Color.clear
                    .frame(width: 136, height: 136)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .center, spacing: 8) {
                        Text(snapshot.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Spacer(minLength: 2)

                        Color.clear
                            .frame(width: 20, height: 16)
                    }

                    Text(snapshot.artist)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    PlaybackTimeline(snapshot: snapshot)

                    MediaControlRow(model: model, snapshot: snapshot)
                }
                .padding(.top, 8)
                .frame(height: 136, alignment: .top)
            }
        } else {
            SpotifyReadyState(model: model)
        }
    }
}

private struct SpotifyReadyState: View {
    @Bindable var model: IslandModel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if let icon = spotifyIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
            .frame(width: 136, height: 136)

            VStack(alignment: .leading, spacing: 4) {
                Text("Spotify")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Ready to play")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))

                Spacer(minLength: 0)

                HStack(spacing: 30) {
                    MediaButton(
                        systemName: "backward.end.fill",
                        label: "Previous",
                        size: 18,
                        isEnabled: isSpotifyInstalled
                    ) { model.sendToSpotify(.previous) }

                    MediaButton(
                        systemName: "play.fill",
                        label: "Play Spotify",
                        size: 27,
                        isEnabled: isSpotifyInstalled
                    ) { model.sendToSpotify(.play) }

                    MediaButton(
                        systemName: "forward.end.fill",
                        label: "Next",
                        size: 18,
                        isEnabled: isSpotifyInstalled
                    ) { model.sendToSpotify(.next) }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.top, 8)
            .frame(height: 136, alignment: .top)
        }
    }

    private var spotifyURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client")
    }

    private var isSpotifyInstalled: Bool {
        spotifyURL != nil
    }

    private var spotifyIcon: NSImage? {
        spotifyURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}

private struct MediaControlRow: View {
    @Bindable var model: IslandModel
    let snapshot: MediaSessionSnapshot

    var body: some View {
        HStack(spacing: 30) {
            MediaButton(
                systemName: backwardCommand == .skipBackward ? "gobackward.15" : "backward.end.fill",
                label: backwardCommand == .skipBackward ? "Back 15 seconds" : "Previous",
                size: 18,
                isEnabled: backwardCommand != nil
            ) {
                if let backwardCommand { model.send(backwardCommand) }
            }

            MediaButton(
                systemName: snapshot.isPlaying ? "pause.fill" : "play.fill",
                label: snapshot.isPlaying ? "Pause" : "Play",
                size: 27,
                isEnabled: supportsPlayPause
            ) { model.send(playPauseCommand) }

            MediaButton(
                systemName: forwardCommand == .skipForward ? "goforward.15" : "forward.end.fill",
                label: forwardCommand == .skipForward ? "Forward 15 seconds" : "Next",
                size: 18,
                isEnabled: forwardCommand != nil
            ) {
                if let forwardCommand { model.send(forwardCommand) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var playPauseCommand: MediaCommand {
        if model.homeMediaUsesSpotifyFallback && !snapshot.isPlaying { return .play }
        if snapshot.capabilities.contains(.togglePlayPause) { return .togglePlayPause }
        return snapshot.isPlaying ? .pause : .play
    }

    private var supportsPlayPause: Bool {
        snapshot.capabilities.contains(.togglePlayPause)
            || snapshot.capabilities.contains(snapshot.isPlaying ? .pause : .play)
    }

    private var backwardCommand: MediaCommand? {
        if snapshot.capabilities.contains(.previous) { return .previous }
        return snapshot.capabilities.contains(.skipBackward) ? .skipBackward : nil
    }

    private var forwardCommand: MediaCommand? {
        if snapshot.capabilities.contains(.next) { return .next }
        return snapshot.capabilities.contains(.skipForward) ? .skipForward : nil
    }
}

private struct CalendarSummarySection: View {
    @Bindable var model: IslandModel
    @State private var visibleCalendarDate: Date?

    var body: some View {
        let headerDate = visibleCalendarDate ?? model.selectedCalendarDate

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 7) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(headerDate.formatted(.dateTime.month(.abbreviated)))
                        .font(.system(size: 16, weight: .semibold))
                    Text(headerDate.formatted(.dateTime.year()))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                }
                .frame(width: 42, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { openCalendar() }

                CalendarDayStrip(model: model) { date in
                    visibleCalendarDate = date
                }
            }
            .frame(height: 54)

            Group {
                switch model.calendarAccessState {
                case .authorized:
                    CalendarEventSummary(model: model)
                        .onTapGesture { model.presentCalendarDetail() }
                case .unknown:
                    CalendarPermissionState(
                        icon: "calendar.badge.plus",
                        title: "Connect Apple Calendar",
                        detail: nil,
                        buttonTitle: "Connect"
                    ) { model.requestCalendarAccess() }
                case .requesting:
                    CalendarPermissionState(
                        icon: "ellipsis.circle",
                        title: "Waiting for permission",
                        detail: "Choose an option in the system dialog",
                        buttonTitle: nil,
                        action: {}
                    )
                case .denied:
                    CalendarPermissionState(
                        icon: "calendar.badge.exclamationmark",
                        title: "Calendar access is off",
                        detail: "Enable it in Privacy & Security settings",
                        buttonTitle: "Open Settings"
                    ) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 74, maxHeight: 74)
            .clipped()
        }
        .frame(height: 136, alignment: .top)
        .clipped()
    }

    private func openCalendar() {
        if model.calendarAccessState == .authorized {
            model.presentCalendarDetail()
        } else {
            model.requestCalendarAccess()
        }
    }
}

private struct CalendarDayStrip: View {
    @Bindable var model: IslandModel
    let onVisibleDateChange: (Date) -> Void
    @State private var timelineAnchor: Date
    @State private var todayNavigationDirection: TodayNavigationDirection?

    private let timelineRadius = 730

    init(model: IslandModel, onVisibleDateChange: @escaping (Date) -> Void) {
        self.model = model
        self.onVisibleDateChange = onVisibleDateChange
        let selectedDay = Calendar.current.startOfDay(for: model.selectedCalendarDate)
        _timelineAnchor = State(initialValue: selectedDay)
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 2) {
                Button {
                    selectToday(using: proxy)
                } label: {
                    HStack(spacing: 2) {
                        if todayNavigationDirection == .backward {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 7, weight: .bold))
                        }
                        Text("Today")
                        if todayNavigationDirection == .forward {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 7, weight: .bold))
                        }
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.58))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .frame(height: 12)
                .opacity(todayNavigationDirection == nil ? 0 : 1)
                .allowsHitTesting(todayNavigationDirection != nil)
                .accessibilityLabel("Go to today")
                .accessibilityHidden(todayNavigationDirection == nil)
                .animation(.easeInOut(duration: 0.16), value: todayNavigationDirection)

                ScrollView(.horizontal) {
                    LazyHStack(spacing: CalendarDayStripLayout.spacing) {
                        ForEach(days, id: \.self) { day in
                            let calendar = Calendar.current
                            let selected = calendar.isDate(
                                day,
                                inSameDayAs: model.selectedCalendarDate
                            )
                            let isToday = calendar.isDateInToday(day)

                            Button {
                                select(day, using: proxy)
                            } label: {
                                VStack(spacing: 2) {
                                    Text(day.formatted(.dateTime.weekday(.narrow)))
                                        .font(.system(size: 8, weight: .semibold))
                                        .foregroundStyle(.white.opacity(selected ? 0.9 : 0.36))
                                    Text(day.formatted(.dateTime.day()))
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(dayNumberColor(selected: selected, isToday: isToday))
                                    Circle()
                                        .fill(eventIndicatorColor(for: day, selected: selected, isToday: isToday))
                                        .frame(width: 3, height: 3)
                                }
                                .frame(width: CalendarDayStripLayout.dayWidth, height: 40)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(dayBackgroundColor(selected: selected, isToday: isToday))
                                )
                            }
                            .buttonStyle(.plain)
                            .id(day)
                        }
                    }
                    .padding(.horizontal, CalendarDayStripLayout.horizontalPadding)
                }
                .scrollIndicators(.hidden)
                .onScrollGeometryChange(for: Int.self) { geometry in
                    let firstDayCenter = CalendarDayStripLayout.horizontalPadding
                        + CalendarDayStripLayout.dayWidth / 2
                    return Int(
                        ((geometry.visibleRect.midX - firstDayCenter)
                            / CalendarDayStripLayout.pitch).rounded()
                    )
                } action: { _, centeredIndex in
                    let timelineDays = days
                    guard timelineDays.indices.contains(centeredIndex) else { return }
                    onVisibleDateChange(timelineDays[centeredIndex])
                }
                .onScrollGeometryChange(for: Optional<TodayNavigationDirection>.self) { geometry in
                    let calendar = Calendar.current
                    let today = calendar.startOfDay(for: .now)
                    let dayOffset = calendar.dateComponents(
                        [.day],
                        from: timelineAnchor,
                        to: today
                    ).day ?? 0
                    let todayIndex = dayOffset + timelineRadius
                    if todayIndex < 0 {
                        return .backward
                    }
                    if todayIndex > timelineRadius * 2 {
                        return .forward
                    }

                    let todayMinX = CalendarDayStripLayout.horizontalPadding
                        + CGFloat(todayIndex) * CalendarDayStripLayout.pitch
                    let todayMaxX = todayMinX + CalendarDayStripLayout.dayWidth
                    if todayMaxX < geometry.visibleRect.minX {
                        return .backward
                    }
                    if todayMinX > geometry.visibleRect.maxX {
                        return .forward
                    }
                    return nil
                } action: { _, newDirection in
                    todayNavigationDirection = newDirection
                }
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.09),
                            .init(color: .black, location: 0.91),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
                .frame(height: 40)
            }
            .frame(height: 54)
            .onAppear {
                DispatchQueue.main.async {
                    center(model.selectedCalendarDate, using: proxy, animated: false)
                }
            }
            .onChange(of: model.selectedCalendarDate) { _, newDate in
                center(newDate, using: proxy, animated: true)
            }
        }
    }

    private var days: [Date] {
        let calendar = Calendar.current
        return (-timelineRadius...timelineRadius).compactMap {
            calendar.date(byAdding: .day, value: $0, to: timelineAnchor)
        }
    }

    private func select(_ day: Date, using proxy: ScrollViewProxy) {
        if Calendar.current.isDate(day, inSameDayAs: model.selectedCalendarDate) {
            center(day, using: proxy, animated: true)
        } else {
            model.selectCalendarDate(day)
        }
    }

    private func selectToday(using proxy: ScrollViewProxy) {
        select(Calendar.current.startOfDay(for: .now), using: proxy)
    }

    private func center(
        _ date: Date,
        using proxy: ScrollViewProxy,
        animated: Bool
    ) {
        let day = Calendar.current.startOfDay(for: date)
        let distance = Calendar.current.dateComponents(
            [.day],
            from: timelineAnchor,
            to: day
        ).day ?? 0

        let needsNewTimeline = abs(distance) >= timelineRadius
        if needsNewTimeline {
            timelineAnchor = day
        }

        let scroll = {
            proxy.scrollTo(day, anchor: .center)
            onVisibleDateChange(day)
        }

        let performScroll = {
            if animated {
                withAnimation(.snappy(duration: 0.28), scroll)
            } else {
                scroll()
            }
        }

        if needsNewTimeline {
            DispatchQueue.main.async {
                if animated {
                    withAnimation(.snappy(duration: 0.28), scroll)
                } else {
                    scroll()
                }
            }
        } else {
            performScroll()
        }
    }

    private func dayNumberColor(selected: Bool, isToday: Bool) -> Color {
        if isToday {
            return selected ? .white : .red
        }
        return .white.opacity(selected ? 1 : 0.64)
    }

    private func dayBackgroundColor(selected: Bool, isToday: Bool) -> Color {
        if isToday {
            return selected ? .red : .black
        }
        return selected ? Color.blue.opacity(0.32) : .white.opacity(0.035)
    }

    private func eventIndicatorColor(for day: Date, selected: Bool, isToday: Bool) -> Color {
        guard !model.events(on: day).isEmpty else { return .clear }
        return selected && isToday ? .white : .blue
    }

    private enum TodayNavigationDirection: Equatable {
        case backward
        case forward
    }
}

private enum CalendarDayStripLayout {
    static let dayWidth: CGFloat = 35
    static let spacing: CGFloat = 7
    static let horizontalPadding: CGFloat = 12

    static var pitch: CGFloat { dayWidth + spacing }
}

private struct CalendarEventSummary: View {
    @Bindable var model: IslandModel

    var body: some View {
        let allEvents = model.events(on: model.selectedCalendarDate)
        let visibleEvents = Array(allEvents.prefix(4))
        let overflowCount = max(allEvents.count - visibleEvents.count, 0)
        let transitionID = "\(model.selectedCalendarDate.timeIntervalSinceReferenceDate)|"
            + visibleEvents.map(\.id).joined(separator: "|")

        ZStack(alignment: .topLeading) {
            Group {
                if visibleEvents.isEmpty {
                    VStack(spacing: 5) {
                        Image(systemName: "calendar.badge.checkmark")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(.white.opacity(0.38))
                        Text("No events")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Enjoy the open space.")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.36))
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                } else {
                    VStack(spacing: 3) {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)
                            ],
                            alignment: .leading,
                            spacing: 6
                        ) {
                            ForEach(visibleEvents) { event in
                                CalendarEventRow(event: event, compact: true)
                                    .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
                            }
                        }

                        if overflowCount > 0 {
                            Text("+ \(overflowCount)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.5))
                                .frame(maxWidth: .infinity, alignment: .center)
                                .accessibilityLabel("\(overflowCount) more events")
                        }

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .id(transitionID)
            .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.2), value: transitionID)
        .contentShape(Rectangle())
    }
}

private struct CalendarPermissionState: View {
    let icon: String
    let title: String
    let detail: String?
    let buttonTitle: String?
    let action: () -> Void

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.46))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            if let detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.36))
            }
            if let buttonTitle {
                Button(buttonTitle, action: action)
                    .buttonStyle(IslandCapsuleButtonStyle(tint: .blue))
            }
        }
        .multilineTextAlignment(.center)
    }
}

private struct CalendarDetailHeader: View {
    @Bindable var model: IslandModel

    var body: some View {
        HStack {
            Button {
                model.dismissCalendarDetail()
            } label: {
                Label("Home", systemImage: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))
                    .frame(height: 30)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 6)
    }
}

private struct CalendarDetailView: View {
    @Bindable var model: IslandModel

    var body: some View {
        HStack(spacing: 24) {
            VStack(spacing: 14) {
                HStack {
                    Button { model.changeCalendarMonth(by: -1) } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.plain)

                    Spacer()
                    Text(model.displayedCalendarMonth.formatted(.dateTime.month(.wide).year()))
                        .font(.system(size: 23, weight: .bold))
                    Spacer()

                    Button { model.changeCalendarMonth(by: 1) } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(.white.opacity(0.86))

                MonthGrid(model: model)
            }
            .frame(width: 405)

            Rectangle()
                .fill(.white.opacity(0.1))
                .frame(width: 1)
                .padding(.vertical, 5)

            VStack(alignment: .leading, spacing: 12) {
                Text(model.selectedCalendarDate.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))

                ScrollView {
                    LazyVStack(spacing: 10) {
                        let events = model.events(on: model.selectedCalendarDate)
                        if events.isEmpty {
                            VStack(spacing: 9) {
                                Image(systemName: "calendar.badge.checkmark")
                                    .font(.system(size: 23))
                                    .foregroundStyle(.white.opacity(0.34))
                                Text("No events")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("This day is all yours.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.36))
                            }
                            .padding(.top, 48)
                        } else {
                            ForEach(events) { event in
                                CalendarEventRow(event: event, compact: false)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
    }
}

private struct MonthGrid: View {
    @Bindable var model: IslandModel
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)

    var body: some View {
        VStack(spacing: 8) {
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(Calendar.current.veryShortWeekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.3))
                        .frame(height: 22)
                }
            }

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(monthDates, id: \.self) { date in
                    let inMonth = Calendar.current.isDate(
                        date,
                        equalTo: model.displayedCalendarMonth,
                        toGranularity: .month
                    )
                    let selected = Calendar.current.isDate(date, inSameDayAs: model.selectedCalendarDate)
                    Button {
                        model.selectCalendarDate(date)
                    } label: {
                        ZStack {
                            Circle()
                                .fill(selected ? Color.red : .clear)
                            Text(date.formatted(.dateTime.day()))
                                .font(.system(size: 12, weight: selected ? .bold : .medium))
                                .foregroundStyle(.white.opacity(inMonth ? 0.84 : 0.2))
                        }
                        .frame(width: 34, height: 34)
                        .overlay(alignment: .bottom) {
                            if !model.events(on: date).isEmpty && !selected {
                                Circle().fill(Color.blue).frame(width: 3, height: 3)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var monthDates: [Date] {
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: .month, for: model.displayedCalendarMonth) else {
            return []
        }
        let weekday = calendar.component(.weekday, from: interval.start)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        guard let gridStart = calendar.date(byAdding: .day, value: -leading, to: interval.start) else {
            return []
        }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
    }
}

private struct CalendarEventRow: View {
    let event: CalendarEventItem
    let compact: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Capsule()
                .fill(Color(red: event.red, green: event.green, blue: event.blue))
                .frame(width: 4, height: compact ? 24 : 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(.system(size: compact ? 11 : 13, weight: .semibold))
                    .lineLimit(compact ? 1 : 2)
                    .truncationMode(.tail)
                Text(eventTime)
                    .font(.system(size: compact ? 9 : 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(compact ? 0 : 10)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.white.opacity(compact ? 0 : 0.055))
        )
    }

    private var eventTime: String {
        if event.isAllDay { return "All day · \(event.calendarTitle)" }
        return "\(event.startDate.formatted(date: .omitted, time: .shortened))–\(event.endDate.formatted(date: .omitted, time: .shortened))"
    }
}

private struct ClipboardTabView: View {
    @Bindable var model: IslandModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ClipboardSectionTitle(title: "Recent screenshots")

            FadingClipboardScrollView {
                if model.screenshotClipboardEntries.isEmpty {
                    ClipboardEmptyRow(
                        systemImage: "photo.on.rectangle.angled",
                        title: "Copied screenshots appear here"
                    )
                } else {
                    LazyHStack(spacing: 8) {
                        ForEach(model.screenshotClipboardEntries) { entry in
                            ClipboardScreenshotItem(
                                entry: entry,
                                isSelected: model.selectedClipboardEntryIDs.contains(entry.id)
                            )
                            .onTapGesture { select(entry) }
                            .onDrag { entry.itemProvider }
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
            .frame(height: 61)

            ClipboardSectionTitle(title: "Recent copied text")

            FadingClipboardScrollView {
                if model.textClipboardEntries.isEmpty {
                    ClipboardEmptyRow(
                        systemImage: "text.alignleft",
                        title: "Copied text appears here"
                    )
                } else {
                    LazyHStack(spacing: 8) {
                        ForEach(model.textClipboardEntries) { entry in
                            ClipboardTextItem(
                                entry: entry,
                                isSelected: model.selectedClipboardEntryIDs.contains(entry.id),
                                isCopied: model.copiedClipboardEntryID == entry.id
                            )
                            .onTapGesture { select(entry) }
                            .onDrag { entry.itemProvider }
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
            .frame(height: 39)
        }
        .padding(.leading, IslandGeometry.expandedTopCornerRadius + IslandGeometry.homeContentEdgeInset)
        .padding(.trailing, 26)
        .padding(.top, 1)
        .padding(.bottom, 12)
    }

    private func select(_ entry: ClipboardEntry) {
        let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        model.selectClipboardEntry(entry, extendingSelection: modifiers.contains(.command))
    }
}

private struct ClipboardSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.48))
            .frame(height: 11)
    }
}

private struct FadingClipboardScrollView<Content: View>: View {
    @State private var hasScrolledFromStart = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.horizontal) {
            content()
                .frame(minWidth: 1, maxHeight: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.x > 3
        } action: { _, isScrolled in
            hasScrolledFromStart = isScrolled
        }
        .mask {
            LinearGradient(
                stops: [
                    .init(color: hasScrolledFromStart ? .clear : .white, location: 0),
                    .init(color: .white, location: 0.035),
                    .init(color: .white, location: 0.955),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .animation(.easeOut(duration: 0.16), value: hasScrolledFromStart)
    }
}

private struct ClipboardEmptyRow: View {
    let systemImage: String
    let title: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
            Text(title)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.white.opacity(0.26))
        .frame(width: 240, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .leading)
    }
}

private struct ClipboardScreenshotItem: View {
    let entry: ClipboardEntry
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 3) {
            Group {
                if let image = entry.previewImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: 76, height: 40)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.white.opacity(0.035))
            )
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            Text(entry.screenshotDisplayName)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(isSelected ? 1 : 0.7))
                .lineLimit(1)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .frame(width: 90, height: 59)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.25) : .clear)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.9) : .clear, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct ClipboardTextItem: View {
    let entry: ClipboardEntry
    let isSelected: Bool
    let isCopied: Bool

    var body: some View {
        ZStack {
            Text(entry.textSnippet)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(isSelected ? 1 : 0.68))
                .lineLimit(1)
                .frame(width: 148, height: 36, alignment: .leading)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.24) : .white.opacity(0.055))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(
                            isSelected ? Color.accentColor.opacity(0.85) : .white.opacity(0.05),
                            lineWidth: 1
                        )
                }
                .blur(radius: isCopied ? 5 : 0)
                .opacity(isCopied ? 0.42 : 1)

            if isCopied {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.seal.fill")
                    Text("Copied")
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.green)
                .transition(
                    .scale(scale: 0.9)
                        .combined(with: .opacity)
                )
            }
        }
        .frame(width: 168, height: 36)
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .animation(.easeInOut(duration: 0.2), value: isCopied)
    }
}

private extension ClipboardEntry {
    var previewImage: NSImage? {
        switch payload {
        case .image(let data):
            NSImage(data: data)
        case .files(let urls):
            urls.lazy.compactMap(NSImage.init(contentsOf:)).first
        case .text:
            nil
        }
    }

    var screenshotDisplayName: String {
        switch payload {
        case .files(let urls):
            urls.first?.deletingPathExtension().lastPathComponent ?? "Screenshot"
        case .image:
            "Screenshot \(createdAt.formatted(date: .omitted, time: .shortened))"
        case .text:
            "Screenshot"
        }
    }

    var textSnippet: String {
        guard case .text(let text) = payload else { return "" }
        let normalized = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let limit = 72
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)) + "..."
    }

    var itemProvider: NSItemProvider {
        switch payload {
        case .text(let text):
            return NSItemProvider(object: text as NSString)
        case .image(let data):
            if let image = NSImage(data: data) {
                return NSItemProvider(object: image)
            }
            return NSItemProvider(object: "Image" as NSString)
        case .files(let urls):
            if let url = urls.first {
                return NSItemProvider(object: url as NSURL)
            }
            return NSItemProvider()
        }
    }
}

private struct TimerTabView: View {
    @Bindable var model: IslandModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            if model.isTimerActive && !model.isTimerStartTransitioning {
                RunningTimerView(model: model)
                    .transition(runningTimerTransition)
            } else {
                VStack(spacing: 0) {
                    TimerRuler(model: model)

                    Spacer(minLength: 8)

                    HStack {
                        Button("Start Timer") { model.startTimer() }
                            .buttonStyle(TimerStartButtonStyle())

                        Spacer()

                        Text(timerText(model.timerSelectedMinutes * 60))
                            .font(.system(size: 38, weight: .light, design: .rounded))
                            .foregroundStyle(.orange)
                            .contentTransition(.numericText())
                    }
                    // The timer surface has the same 14-point upper shoulder as
                    // Home. Adding the shared 18-point visual inset makes the
                    // button's left and bottom spacing match the artwork layout.
                    .padding(.leading, IslandGeometry.expandedTopCornerRadius + IslandGeometry.homeContentEdgeInset)
                    .padding(.trailing, IslandGeometry.expandedTopCornerRadius + IslandGeometry.homeContentEdgeInset)
                }
                .padding(.top, 4)
                .padding(.bottom, IslandGeometry.homeContentEdgeInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                // Fade the ruler as one layer. Without this, the parent shell's
                // size spring keeps Canvas alive until the entire shrink ends.
                .compositingGroup()
                .transition(timerSetupTransition)
            }
        }
        .animation(timerStateAnimation, value: model.isTimerActive)
    }

    private func timerText(_ interval: TimeInterval) -> String {
        Self.format(interval)
    }

    static func format(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var timerStateAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.3, dampingFraction: 0.92, blendDuration: 0)
    }

    private var timerSetupTransition: AnyTransition {
        let insertion = AnyTransition.opacity
            .combined(with: reduceMotion ? .identity : .scale(scale: 0.99, anchor: .bottom))
            .animation(.easeOut(duration: 0.16).delay(0.04))
        let removal = AnyTransition.opacity
            .combined(with: reduceMotion ? .identity : .scale(scale: 0.995, anchor: .top))
            .animation(.easeOut(duration: 0.08))
        return .asymmetric(insertion: insertion, removal: removal)
    }

    private var runningTimerTransition: AnyTransition {
        let insertion = AnyTransition.opacity
            .combined(with: reduceMotion ? .identity : .scale(scale: 0.985, anchor: .bottom))
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.12)
                    : .spring(response: 0.28, dampingFraction: 0.92, blendDuration: 0)
                        .delay(0.035)
            )
        let removal = AnyTransition.opacity.animation(.easeOut(duration: 0.08))
        return .asymmetric(insertion: insertion, removal: removal)
    }
}

private struct TimerRuler: View {
    @Bindable var model: IslandModel
    @State private var dragStartMinutes: Double?

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .top) {
                Canvas { context, size in
                    let centerX = size.width / 2
                    let selected = Int(model.timerSelectedMinutes.rounded())
                    for minute in 1...120 {
                        let x = centerX + CGFloat(minute - selected) * 12
                        guard x >= -15, x <= size.width + 15 else { continue }
                        let major = minute.isMultiple(of: 5)
                        let height: CGFloat = major ? 31 : 20
                        var tick = Path()
                        tick.move(to: CGPoint(x: x, y: 20))
                        tick.addLine(to: CGPoint(x: x, y: 20 + height))
                        context.stroke(
                            tick,
                            with: .color(.orange.opacity(minute == selected ? 1 : major ? 0.62 : 0.32)),
                            lineWidth: minute == selected ? 5 : major ? 3 : 2
                        )

                        if major {
                            context.draw(
                                Text("\(minute)")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.orange.opacity(minute == selected ? 1 : 0.58)),
                                at: CGPoint(x: x, y: 8)
                            )
                        }
                    }
                }

                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.orange)
                    .padding(.top, 58)

                TimerRulerInteractionView(
                    onDragBegan: {
                        dragStartMinutes = model.timerSelectedMinutes
                    },
                    onDragChanged: { translation in
                        let start = dragStartMinutes ?? model.timerSelectedMinutes
                        model.setTimerMinutes(start - translation / 12)
                    },
                    onDragEnded: {
                        dragStartMinutes = nil
                    },
                    onScroll: { steps in
                        model.setTimerMinutes(model.timerSelectedMinutes + Double(steps))
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .contentShape(Rectangle())
            // Values can begin at the centered selection marker, so opacity
            // only falls when ticks approach the island's actual outer edges.
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.075),
                        .init(color: .black, location: 0.925),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        }
        .frame(height: 76)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timer duration")
        .accessibilityValue("\(Int(model.timerSelectedMinutes)) minutes")
    }
}

private struct TimerRulerInteractionView: NSViewRepresentable {
    let onDragBegan: () -> Void
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void
    let onScroll: (Int) -> Void

    func makeNSView(context: Context) -> TimerRulerInputView {
        TimerRulerInputView()
    }

    func updateNSView(_ view: TimerRulerInputView, context: Context) {
        view.onDragBegan = onDragBegan
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
        view.onScroll = onScroll
    }
}

private final class TimerRulerInputView: NSView {
    var onDragBegan: (() -> Void)?
    var onDragChanged: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    var onScroll: ((Int) -> Void)?

    private var dragStartX: CGFloat?
    private var scrollRemainder: CGFloat = 0

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragStartX = event.locationInWindow.x
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartX else { return }
        onDragChanged?(event.locationInWindow.x - dragStartX)
    }

    override func mouseUp(with event: NSEvent) {
        dragStartX = nil
        onDragEnded?()
    }

    override func scrollWheel(with event: NSEvent) {
        let horizontal = event.scrollingDeltaX
        let vertical = event.scrollingDeltaY
        let dominantDelta = abs(horizontal) > abs(vertical) ? -horizontal : vertical
        let normalizedDelta = event.hasPreciseScrollingDeltas
            ? dominantDelta / 10
            : dominantDelta

        scrollRemainder += normalizedDelta
        let steps = Int(scrollRemainder.rounded(.towardZero))
        if steps != 0 {
            scrollRemainder -= CGFloat(steps)
            onScroll?(steps)
        }

        if event.phase == .ended || event.momentumPhase == .ended {
            scrollRemainder = 0
        }
    }
}

private struct TimerStartButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 28)
            .frame(height: 52)
            .background(
                ArtworkRoundedRectangle(
                    cornerRadius: IslandGeometry.expandedBottomCornerRadius
                )
                .fill(.orange.opacity(configuration.isPressed ? 0.22 : 0.14))
            )
            .contentShape(
                ArtworkRoundedRectangle(
                    cornerRadius: IslandGeometry.expandedBottomCornerRadius
                )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct RunningTimerView: View {
    @Bindable var model: IslandModel

    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.toggleTimerPause()
            } label: {
                Image(systemName: model.isTimerPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(TimerCircleButtonStyle(tint: .orange))
            .accessibilityLabel(model.isTimerPaused ? "Resume timer" : "Pause timer")

            Button {
                model.cancelTimer()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(TimerCircleButtonStyle(tint: .white))
            .accessibilityLabel("Cancel timer")

            Spacer(minLength: 20)

            HStack(alignment: .lastTextBaseline, spacing: 7) {
                Text("Timer")
                    .font(.system(size: 13, weight: .semibold))

                Text(TimerTabView.format(model.timerRemaining))
                    .font(.system(size: 38, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: model.isTimerRunning))
                    .animation(.linear(duration: 0.2), value: Int(model.timerRemaining))
            }
            .foregroundStyle(.orange)
        }
        .padding(.leading, IslandGeometry.expandedTopCornerRadius + IslandGeometry.homeContentEdgeInset)
        .padding(.trailing, IslandGeometry.expandedTopCornerRadius + IslandGeometry.homeContentEdgeInset)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

private struct TimerCircleButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 46, height: 46)
            .background(
                Circle()
                    .fill(tint.opacity(configuration.isPressed ? 0.2 : 0.11))
            )
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct IslandCapsuleButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(configuration.isPressed ? 0.2 : 0.12))
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct PlaybackTimeline: View {
    let snapshot: MediaSessionSnapshot

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let elapsed = snapshot.estimatedElapsedTime(at: context.date)
            let duration = snapshot.duration ?? 0
            let progress = duration > 0 ? min(max(elapsed / duration, 0), 1) : 0

            VStack(spacing: 5) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.16))
                        Capsule()
                            .fill(.white.opacity(0.92))
                            .frame(width: proxy.size.width * progress)
                    }
                }
                .frame(height: 5)

                HStack {
                    Text(Self.format(elapsed))
                    Spacer()
                    Text(duration > 0 ? "−\(Self.format(max(0, duration - elapsed)))" : "Live")
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.48))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback progress")
    }

    private static func format(_ interval: TimeInterval) -> String {
        guard interval.isFinite else { return "0:00" }
        let seconds = max(0, Int(interval.rounded(.down)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct ArtworkView: View {
    let snapshot: MediaSessionSnapshot
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        Group {
            if let artwork = snapshot.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color(nsColor: NSColor(deviceWhite: 0.075, alpha: 1))

                    if let sourceIcon = snapshot.sourceIcon {
                        Image(nsImage: sourceIcon)
                            .resizable()
                            .scaledToFit()
                            .padding(size * 0.23)
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.42, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                }
            }
        }
        .frame(width: size, height: size)
        // A neutral backing prevents an unrendered NSImage texture from
        // exposing a colorful placeholder during compact/expanded cross-fades.
        .background(Color(nsColor: NSColor(deviceWhite: 0.075, alpha: 1)))
        .clipShape(ArtworkRoundedRectangle(cornerRadius: cornerRadius))
        .accessibilityLabel("Artwork for \(snapshot.title)")
    }
}

private struct ArtworkRoundedRectangle: Shape {
    var cornerRadius: CGFloat

    var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, min(rect.width, rect.height) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + radius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

private struct MediaButton: View {
    let systemName: String
    let label: String
    let size: CGFloat
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 42, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.3))
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }
}
