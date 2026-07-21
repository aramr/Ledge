import Foundation
import IOBluetooth

/// `IOBluetooth` predates Swift concurrency and may deliver its Objective-C
/// callbacks from a background queue. Retain the device while the callback is
/// forwarded to the main actor without claiming that the framework type itself
/// is generally safe to share between concurrent tasks.
private struct BluetoothDeviceReference: @unchecked Sendable {
    let device: IOBluetoothDevice
}

@MainActor
final class BluetoothConnectionService: NSObject {
    var onDeviceConnected: ((BluetoothConnectionEvent) -> Void)?

    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var connectedDeviceIdentifiers: Set<String> = []
    private var recentlyPresentedAt: [String: Date] = [:]
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
        connectedDeviceIdentifiers.removeAll()
        recentlyPresentedAt.removeAll()
    }

    @objc
    nonisolated private func deviceDidConnect(
        _ notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        let deviceReference = BluetoothDeviceReference(device: device)
        Task { @MainActor [weak self] in
            guard let self, connectNotification != nil else { return }
            handleConnectedDevice(deviceReference.device, shouldPresent: true)
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
            let identifier = identifier(for: deviceReference.device)
            connectedDeviceIdentifiers.remove(identifier)
            recentlyPresentedAt.removeValue(forKey: identifier)
            disconnectNotifications.removeValue(forKey: identifier)?.unregister()
        }
    }

    private func reconcileConnectedDevices(presentNewConnections: Bool) {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let connectedDevices = devices.filter { $0.isConnected() }
        let liveIdentifiers = Set(connectedDevices.map(identifier(for:)))

        for identifier in connectedDeviceIdentifiers.subtracting(liveIdentifiers) {
            connectedDeviceIdentifiers.remove(identifier)
            recentlyPresentedAt.removeValue(forKey: identifier)
            disconnectNotifications.removeValue(forKey: identifier)?.unregister()
        }

        for device in connectedDevices {
            let isNewConnection = !connectedDeviceIdentifiers.contains(identifier(for: device))
            handleConnectedDevice(
                device,
                shouldPresent: presentNewConnections && isNewConnection
            )
        }
    }

    private func handleConnectedDevice(
        _ device: IOBluetoothDevice,
        shouldPresent: Bool
    ) {
        let identifier = identifier(for: device)
        let wasConnected = connectedDeviceIdentifiers.contains(identifier)
        connectedDeviceIdentifiers.insert(identifier)
        registerForDisconnect(of: device, identifier: identifier)

        guard shouldPresent, !wasConnected, shouldPresentDevice(identifier: identifier) else {
            return
        }

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

    private func shouldPresentDevice(identifier: String) -> Bool {
        let now = Date()
        defer {
            recentlyPresentedAt[identifier] = now
            recentlyPresentedAt = recentlyPresentedAt.filter {
                now.timeIntervalSince($0.value) < 30
            }
        }

        guard let lastPresentation = recentlyPresentedAt[identifier] else { return true }
        return now.timeIntervalSince(lastPresentation) >= 3
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
