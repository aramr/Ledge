import AppKit
import Foundation

@MainActor
final class FocusMonitor {
    var onChange: ((String?) -> Void)?

    private let workspace = NSWorkspace.shared
    private var observer: NSObjectProtocol?

    func start() {
        onChange?(workspace.frontmostApplication?.bundleIdentifier)
        observer = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: workspace,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in
                self?.onChange?(application?.bundleIdentifier)
            }
        }
    }

    func stop() {
        if let observer {
            workspace.notificationCenter.removeObserver(observer)
        }
        observer = nil
    }
}
