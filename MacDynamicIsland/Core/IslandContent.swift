import Foundation

enum BluetoothDeviceKind: Equatable {
    case airPodsPro
    case airPods
    case airPodsMax
    case beats
    case headphones
    case speaker
    case keyboard
    case pointingDevice
    case gameController
    case phone
    case watch
    case computer
    case imaging
    case generic

    var systemImage: String {
        switch self {
        case .airPodsPro: "airpodspro.chargingcase.wireless.fill"
        case .airPods: "airpods"
        case .airPodsMax: "airpodsmax"
        case .beats: "beats.headphones"
        case .headphones: "headphones"
        case .speaker: "hifispeaker.fill"
        case .keyboard: "keyboard.fill"
        case .pointingDevice: "computermouse.fill"
        case .gameController: "gamecontroller.fill"
        case .phone: "iphone"
        case .watch: "applewatch"
        case .computer: "laptopcomputer"
        case .imaging: "printer.fill"
        case .generic: "dot.radiowaves.left.and.right"
        }
    }

    static func classify(
        name: String,
        majorDeviceClass: UInt32,
        minorDeviceClass: UInt32
    ) -> BluetoothDeviceKind {
        let normalizedName = name.lowercased()

        if normalizedName.contains("airpods max") { return .airPodsMax }
        if normalizedName.contains("airpods pro") { return .airPodsPro }
        if normalizedName.contains("airpods") { return .airPods }
        if normalizedName.contains("beats") { return .beats }
        if normalizedName.contains("homepod") || normalizedName.contains("speaker") {
            return .speaker
        }
        if normalizedName.contains("headphone")
            || normalizedName.contains("headset")
            || normalizedName.contains("earbud")
            || normalizedName.contains("buds") {
            return .headphones
        }
        if normalizedName.contains("keyboard") { return .keyboard }
        if normalizedName.contains("mouse") || normalizedName.contains("trackpad") {
            return .pointingDevice
        }
        if normalizedName.contains("controller") || normalizedName.contains("gamepad") {
            return .gameController
        }
        if normalizedName.contains("iphone") || normalizedName.contains("phone") {
            return .phone
        }
        if normalizedName.contains("watch") { return .watch }
        if normalizedName.contains("macbook") || normalizedName.contains("computer") {
            return .computer
        }
        if normalizedName.contains("printer") || normalizedName.contains("scanner") {
            return .imaging
        }

        switch majorDeviceClass {
        case 0x01:
            return .computer
        case 0x02:
            return .phone
        case 0x04:
            return .headphones
        case 0x05:
            // Peripheral minor class bits distinguish keyboard, pointing
            // device, and combined keyboard/pointing accessories.
            switch minorDeviceClass & 0x30 {
            case 0x10: return .keyboard
            case 0x20, 0x30: return .pointingDevice
            default: return .gameController
            }
        case 0x06:
            return .imaging
        case 0x07:
            return .watch
        default:
            return .generic
        }
    }
}

struct BluetoothConnectionEvent: Identifiable, Equatable {
    let id: UUID
    let deviceIdentifier: String
    let deviceName: String
    let kind: BluetoothDeviceKind

    init(
        id: UUID = UUID(),
        deviceIdentifier: String,
        deviceName: String,
        kind: BluetoothDeviceKind
    ) {
        self.id = id
        self.deviceIdentifier = deviceIdentifier
        self.deviceName = deviceName
        self.kind = kind
    }
}

enum IslandTab: String, CaseIterable, Identifiable {
    case home
    case clipboard
    case timer
    case agentic

    var id: Self { self }

    var title: String {
        switch self {
        case .home: "Home"
        case .clipboard: "Clipboard"
        case .timer: "Timer"
        case .agentic: "Agentic"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house.fill"
        case .clipboard: "tray.full.fill"
        case .timer: "timer"
        case .agentic: "cpu"
        }
    }
}

enum AgentProvider: String, CaseIterable, Identifiable {
    case codex
    case claude

    var id: Self { self }

    var title: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }
}

enum AgentConnectionState: Equatable {
    case checking
    case connected
    case notInstalled
    case signInRequired
    case unavailable
}

struct CodexUsageSnapshot: Codable, Equatable, Sendable {
    let usedPercent: Double
    let resetDate: Date
    let updatedAt: Date
    let windowDurationMinutes: Int
    let planType: String?

    var remainingPercent: Double {
        min(max(100 - usedPercent, 0), 100)
    }
}

struct ClaudeUsageSnapshot: Codable, Equatable, Sendable {
    let usedPercent: Double
    let resetDate: Date?
    let updatedAt: Date
    let windowDurationMinutes: Int
    let planType: String?

    var remainingPercent: Double {
        min(max(100 - usedPercent, 0), 100)
    }
}

enum CalendarAccessState: Equatable {
    case unknown
    case requesting
    case authorized
    case denied
}

struct CalendarEventItem: Identifiable, Equatable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let calendarTitle: String
    let red: Double
    let green: Double
    let blue: Double
}

enum ClipboardPayload: Equatable {
    case text(String)
    case image(Data)
    case files([URL])
}

struct ClipboardEntry: Identifiable, Equatable {
    let id: UUID
    let payload: ClipboardPayload
    let createdAt: Date

    var title: String {
        switch payload {
        case .text(let text):
            text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Text"
        case .image:
            "Image"
        case .files(let urls):
            urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        }
    }

    var detail: String {
        switch payload {
        case .text(let text):
            "\(text.count) characters"
        case .image(let data):
            ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        case .files(let urls):
            urls.count == 1 ? urls[0].deletingLastPathComponent().path : "Drag to export"
        }
    }

    var isText: Bool {
        if case .text = payload { return true }
        return false
    }

    var isVisual: Bool {
        switch payload {
        case .image:
            true
        case .files(let urls):
            urls.contains { url in
                ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp"]
                    .contains(url.pathExtension.lowercased())
            }
        case .text:
            false
        }
    }
}
