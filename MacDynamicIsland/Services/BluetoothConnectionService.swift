import Foundation
import IOBluetooth

/// `IOBluetooth` predates Swift concurrency and may deliver its Objective-C
/// callbacks from a background queue. Retain the device while the callback is
/// forwarded to the main actor without claiming that the framework type itself
/// is generally safe to share between concurrent tasks.
private struct BluetoothDeviceReference: @unchecked Sendable {
    let device: IOBluetoothDevice
}

/// Track connection transitions, allowing brief link interruptions without
/// announcing the same accessory again. Only a sustained absence ends a session.
struct BluetoothConnectionTracker {
    private(set) var connectedIdentifiers: Set<String> = []
    private var absentSince: [String: Date] = [:]
    let disconnectGraceInterval: TimeInterval = 6

    mutating func update(_ liveIdentifiers: Set<String>, at now: Date, presentNew: Bool) -> Set<String> {
        for identifier in connectedIdentifiers.subtracting(liveIdentifiers) {
            let firstAbsence = absentSince[identifier] ?? now
            absentSince[identifier] = firstAbsence
            if now.timeIntervalSince(firstAbsence) >= disconnectGraceInterval {
                connectedIdentifiers.remove(identifier)
                absentSince.removeValue(forKey: identifier)
            }
        }
        let newIdentifiers = liveIdentifiers.subtracting(connectedIdentifiers)
        connectedIdentifiers.formUnion(liveIdentifiers)
        for identifier in liveIdentifiers {
            absentSince.removeValue(forKey: identifier)
        }
        return presentNew ? newIdentifiers : []
    }

    static func isAccessory(name: String, majorDeviceClass: UInt32) -> Bool {
        // Wearable links support Continuity / Auto Unlock rather than a
        // user-connected Bluetooth accessory in Settings. Check the full name
        // before icon classification, which also recognizes other name tokens.
        !name.lowercased().contains("watch") && majorDeviceClass != 0x07
    }
}

@MainActor
final class BluetoothConnectionService: NSObject {
    var onDeviceConnected: ((BluetoothConnectionEvent) -> Void)?

    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var tracker = BluetoothConnectionTracker()
    private var reconciliationTimer: Timer?

    func start() {
        guard connectNotification == nil else { return }

        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceDidConnect(_:device:))
        )

        // Treat the current connection set as the baseline. Launching the app
        // should never announce accessories that were already connected.
        reconcileConnectedDevices(presentNewConnections: false)

        reconciliationTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                self?.reconcileConnectedDevices(presentNewConnections: true)
            }
        }
    }

    func stop() {
        reconciliationTimer?.invalidate()
        reconciliationTimer = nil

        connectNotification?.unregister()
        connectNotification = nil

        disconnectNotifications.values.forEach { $0.unregister() }
        disconnectNotifications.removeAll()
        tracker = BluetoothConnectionTracker()
    }

    @objc
    nonisolated private func deviceDidConnect(
        _ notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        let deviceReference = BluetoothDeviceReference(device: device)
        Task { @MainActor [weak self] in
            guard let self, connectNotification != nil else { return }
            guard deviceReference.device.isPaired(), deviceReference.device.isConnected() else { return }
            reconcileConnectedDevices(presentNewConnections: true)
        }
    }

    @objc
    nonisolated private func deviceDidDisconnect(
        _ notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        let deviceReference = BluetoothDeviceReference(device: device)
        Task { @MainActor [weak self] in
            guard let self, connectNotification != nil else { return }
            // A low-level disconnect can be a transient link interruption.
            // Reconcile the current state instead of clearing deduplication.
            _ = deviceReference.device
            reconcileConnectedDevices(presentNewConnections: true)
        }
    }

    private func reconcileConnectedDevices(presentNewConnections: Bool) {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let connectedDevices = devices.filter {
            $0.isPaired() && $0.isConnected() && BluetoothConnectionTracker.isAccessory(
                name: $0.name ?? $0.nameOrAddress ?? "",
                majorDeviceClass: UInt32($0.deviceClassMajor)
            )
        }
        let liveIdentifiers = Set(connectedDevices.map(identifier(for:)))
        let newIdentifiers = tracker.update(liveIdentifiers, at: .now, presentNew: presentNewConnections)

        for identifier in Array(disconnectNotifications.keys)
            where !tracker.connectedIdentifiers.contains(identifier) {
            disconnectNotifications.removeValue(forKey: identifier)?.unregister()
        }

        for device in connectedDevices {
            let identifier = identifier(for: device)
            registerForDisconnect(of: device, identifier: identifier)
            if newIdentifiers.contains(identifier) {
                presentConnectedDevice(device, identifier: identifier)
            }
        }
    }

    private func presentConnectedDevice(_ device: IOBluetoothDevice, identifier: String) {
        let rawName = device.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = displayName(rawName: rawName, fallback: device.nameOrAddress)
        let event = BluetoothConnectionEvent(
            deviceIdentifier: identifier,
            deviceName: name,
            kind: BluetoothDeviceKind.classify(
                name: name,
                majorDeviceClass: UInt32(device.deviceClassMajor),
                minorDeviceClass: UInt32(device.deviceClassMinor)
            )
        )
        onDeviceConnected?(event)
    }

    private func registerForDisconnect(
        of device: IOBluetoothDevice,
        identifier: String
    ) {
        guard disconnectNotifications[identifier] == nil else { return }
        disconnectNotifications[identifier] = device.register(
            forDisconnectNotification: self,
            selector: #selector(deviceDidDisconnect(_:device:))
        )
    }

    private func identifier(for device: IOBluetoothDevice) -> String {
        if let address = device.addressString, !address.isEmpty {
            return address
        }
        return "device-\(device.hash)"
    }

    private func displayName(rawName: String?, fallback: String?) -> String {
        let resolved: String
        if let rawName, !rawName.isEmpty {
            resolved = rawName
        } else {
            resolved = fallback ?? ""
        }
        let looksLikeAddress = resolved.range(
            of: #"^[0-9A-Fa-f]{2}([-:][0-9A-Fa-f]{2}){5}$"#,
            options: .regularExpression
        ) != nil
        return looksLikeAddress || resolved.isEmpty
            ? "Bluetooth Device"
            : String(resolved.prefix(64))
    }
}
