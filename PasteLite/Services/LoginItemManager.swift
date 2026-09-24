import Combine
import ServiceManagement

// Keep the system boundary replaceable so tests never change the user's login items.
@MainActor
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
}

extension SMAppService: LoginItemService {}

@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var isUpdating = false
    @Published private(set) var errorMessage: String?
    private let service: any LoginItemService

    init(service: any LoginItemService = SMAppService.mainApp) {
        self.service = service
        status = service.status
    }

    var isRequested: Bool { status == .enabled || status == .requiresApproval }

    func refresh() {
        let current = service.status
        if current != status { errorMessage = nil }
        status = current
    }

    func setEnabled(_ enabled: Bool) async {
        guard !isUpdating else { return }
        refresh()
        errorMessage = nil
        guard enabled != isRequested else { return }
        isUpdating = true
        defer {
            refresh()
            isUpdating = false
        }
        do {
            if enabled {
                try service.register()
            } else {
                try await service.unregister()
            }
        } catch {
            errorMessage = enabled
                ? "无法开启开机启动，请重试或检查系统设置中的登录项。"
                : "无法关闭开机启动，请重试或在系统设置的登录项中关闭。"
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
