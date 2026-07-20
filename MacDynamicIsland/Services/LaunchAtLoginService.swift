import Observation
import ServiceManagement

@MainActor
@Observable
final class LaunchAtLoginService {
    private(set) var isEnabled = false
    private(set) var requiresApproval = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
        refreshStatus()
    }

    func refreshStatus() {
        switch service.status {
        case .enabled:
            isEnabled = true
            requiresApproval = false
        case .requiresApproval:
            isEnabled = false
            requiresApproval = true
        case .notRegistered, .notFound:
            isEnabled = false
            requiresApproval = false
        @unknown default:
            isEnabled = false
            requiresApproval = false
        }
    }

    func setEnabled(_ shouldEnable: Bool) {
        errorMessage = nil

        do {
            if shouldEnable {
                guard service.status != .enabled else {
                    refreshStatus()
                    return
                }
                try service.register()
            } else {
                guard service.status != .notRegistered else {
                    refreshStatus()
                    return
                }
                try service.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        refreshStatus()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
