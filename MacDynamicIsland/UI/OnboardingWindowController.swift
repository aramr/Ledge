import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let onDismiss: () -> Void

    init(
        onFinish: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.onDismiss = onDismiss

        let rootView = OnboardingRootView(onFinish: onFinish)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Welcome to Ledge"
        window.setContentSize(NSSize(width: 900, height: 720))
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.center()

        super.init(window: window)
        shouldCascadeWindows = false
        window.delegate = self
        window.standardWindowButton(.zoomButton)?.isHidden = true
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

    func windowWillClose(_ notification: Notification) {
        onDismiss()
    }
}

private struct OnboardingRootView: View {
    let onFinish: () -> Void

    var body: some View {
        ZStack {
            OnboardingBackdrop()

            VStack(spacing: 0) {
                header
                    .padding(.top, 38)
                    .padding(.bottom, 26)

                VStack(spacing: 12) {
                    OnboardingFeatureRow(
                        title: "Calendar",
                        summary: "See upcoming days and events at a glance, then open the full calendar without leaving Ledge."
                    ) {
                        CalendarOnboardingPreview()
                    }

                    OnboardingFeatureRow(
                        title: "Media at a glance",
                        summary: "Artwork and a live waveform appear in the compact notch whenever Spotify or YouTube is playing."
                    ) {
                        CompactMediaOnboardingPreview()
                    }

                    OnboardingFeatureRow(
                        title: "A faster clipboard",
                        summary: "Keep recent text close, copy it again in one click, and get a clear confirmation without losing your place."
                    ) {
                        ClipboardOnboardingPreview()
                    }
                }
                .padding(.horizontal, 42)

                footer
                    .padding(.horizontal, 42)
                    .padding(.top, 18)
                    .padding(.bottom, 25)
            }
        }
        .frame(width: 900, height: 720)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 18) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 76, height: 76)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text("Ledge")
                        .font(.system(size: 31, weight: .bold))
                        .tracking(-0.5)
                    Text(appVersion)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                Text("Your essentials, always within reach.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Label(
                "Sensitive data stays local. Optional audio and Bluetooth access starts off.",
                systemImage: "hand.raised.fill"
            )
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)

            Spacer()

            Button("Start Ledge", action: onFinish)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        return "v\(version ?? "1.0")"
    }
}

private struct OnboardingBackdrop: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            RadialGradient(
                colors: [Color.blue.opacity(0.15), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 640
            )

            RadialGradient(
                colors: [Color.purple.opacity(0.14), .clear],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 620
            )

            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.18)
        }
        .ignoresSafeArea()
    }
}

private struct OnboardingFeatureRow<Preview: View>: View {
    let title: String
    let summary: String
    let preview: Preview

    init(
        title: String,
        summary: String,
        @ViewBuilder preview: () -> Preview
    ) {
        self.title = title
        self.summary = summary
        self.preview = preview()
    }

    var body: some View {
        HStack(spacing: 26) {
            preview
                .frame(width: 390, height: 126)
                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .stroke(.white.opacity(0.1), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                Text(summary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 21, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .stroke(.white.opacity(0.055), lineWidth: 1)
        }
    }
}

private struct CalendarOnboardingPreview: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.4)) { context in
            let selectedIndex = Int(
                context.date.timeIntervalSinceReferenceDate / 1.4
            ) % 5

            HStack(spacing: 15) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("JUL")
                        .font(.system(size: 12, weight: .bold))
                    Text("2026")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 11) {
                    HStack(spacing: 7) {
                        ForEach(0..<5, id: \.self) { index in
                            VStack(spacing: 3) {
                                Text(["T", "W", "T", "F", "S"][index])
                                    .font(.system(size: 8.5, weight: .semibold))
                                Text("\(14 + index)")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(index == selectedIndex ? .white : .secondary)
                            .frame(width: 39, height: 43)
                            .background(
                                index == selectedIndex
                                    ? Color.blue.opacity(0.62)
                                    : .white.opacity(0.045),
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                        }
                    }

                    HStack(spacing: 7) {
                        Circle()
                            .fill(selectedIndex.isMultiple(of: 2) ? .green : .orange)
                            .frame(width: 6, height: 6)
                        Text(selectedIndex.isMultiple(of: 2) ? "Design review · 14:30" : "Focus time · 16:00")
                            .font(.system(size: 10.5, weight: .medium))
                        Spacer()
                    }
                    .contentTransition(.opacity)
                }
            }
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.smooth(duration: 0.35), value: selectedIndex)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.92))
    }
}

private struct CompactMediaOnboardingPreview: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let progress = time.truncatingRemainder(dividingBy: 8) / 8

            ZStack(alignment: .top) {
                LinearGradient(
                    colors: [
                        Color(red: 0.08, green: 0.54, blue: 0.87),
                        Color(red: 0.31, green: 0.22, blue: 0.78)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                CompactMediaNotchPreviewShape()
                    .fill(.black)
                    .frame(width: 310, height: 62)
                    .overlay {
                        HStack(spacing: 0) {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [.blue, .purple, .pink],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 37, height: 37)
                                .overlay {
                                    Image(systemName: "music.note")
                                        .font(.system(size: 14, weight: .semibold))
                                }

                            Spacer(minLength: 0)

                            HStack(alignment: .center, spacing: 3) {
                                ForEach(0..<5, id: \.self) { index in
                                    Capsule()
                                        .fill(.white.opacity(0.9))
                                        .frame(
                                            width: 3,
                                            height: 9 + abs(sin(time * 2.7 + Double(index) * 0.9)) * 16
                                        )
                                }
                            }
                        }
                        .padding(.horizontal, 17)
                        .padding(.top, 5)
                    }
                    .overlay {
                        SpotifyProgressOutline()
                            .trim(from: 0, to: progress)
                            .stroke(
                                LinearGradient(
                                    colors: [.white.opacity(0.2), .white.opacity(0.92), .purple],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                style: StrokeStyle(lineWidth: 1.6, lineCap: .round)
                            )
                    }
                    .shadow(color: .black.opacity(0.24), radius: 14, y: 7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CompactMediaNotchPreviewShape: Shape {
    func path(in rect: CGRect) -> Path {
        let topRadius: CGFloat = 8
        let bottomRadius: CGFloat = 18
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius, y: rect.minY + topRadius),
            control: CGPoint(x: rect.minX + topRadius, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + topRadius, y: rect.maxY - bottomRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius + bottomRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topRadius - bottomRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topRadius, y: rect.maxY - bottomRadius),
            control: CGPoint(x: rect.maxX - topRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY + topRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topRadius, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

private struct ClipboardOnboardingPreview: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
            let cycle = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 4.5)
            let showsCopied = cycle > 1.8 && cycle < 3.1

            VStack(alignment: .leading, spacing: 10) {
                Label("RECENT TEXT", systemImage: "doc.on.clipboard")
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { index in
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(.white.opacity(index == 0 ? 0.11 : 0.06))

                            if index == 0 && showsCopied {
                                Label("Copied", systemImage: "checkmark.seal.fill")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(.green)
                                    .transition(.opacity.combined(with: .scale(scale: 0.93)))
                            } else {
                                Text([
                                    "Launch notes for the next…",
                                    "Meet at 14:30 near the…",
                                    "A focused layer for…"
                                ][index])
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.78))
                                .lineLimit(2)
                                .padding(10)
                            }
                        }
                        .frame(width: 106, height: 61)
                        .blur(radius: index == 0 && showsCopied ? 0.6 : 0)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.23), value: showsCopied)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.92))
    }
}
