import Foundation
import ServiceManagement

@MainActor
private final class FakeLoginItemService: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    var registeredStatus: SMAppService.Status = .enabled
    var shouldFail = false
    var registrations = 0
    var removals = 0
    var pausesRemoval = false
    var removal: CheckedContinuation<Void, Never>?

    func register() throws {
        registrations += 1
        if shouldFail { throw NSError(domain: "LoginItemTest", code: 1) }
        status = registeredStatus
    }

    func unregister() async throws {
        removals += 1
        if shouldFail { throw NSError(domain: "LoginItemTest", code: 2) }
        if pausesRemoval { await withCheckedContinuation { removal = $0 } }
        status = .notRegistered
    }
}

@main
@MainActor
struct LoginItemTests {
    static func main() async {
        let service = FakeLoginItemService()
        let manager = LoginItemManager(service: service)
        precondition(!manager.isRequested && service.registrations == 0)
        await manager.setEnabled(true)
        precondition(manager.status == .enabled && manager.isRequested)
        await manager.setEnabled(true)
        precondition(service.registrations == 1)
        await manager.setEnabled(false)
        precondition(manager.status == .notRegistered && !manager.isRequested)
        service.status = .enabled
        manager.refresh()
        precondition(manager.isRequested)
        service.status = .notRegistered
        manager.refresh()
        precondition(!manager.isRequested)
        print("PASS: login item stays off by default, enables/disables, and refreshes external system changes")

        service.registeredStatus = .requiresApproval
        await manager.setEnabled(true)
        precondition(manager.status == .requiresApproval && manager.isRequested)
        await manager.setEnabled(false)
        precondition(!manager.isRequested)
        service.status = .notFound
        manager.refresh()
        precondition(manager.status == .notFound && !manager.isRequested)
        service.shouldFail = true
        await manager.setEnabled(true)
        precondition(manager.status == .notFound && !manager.isRequested && manager.errorMessage != nil)
        service.status = .enabled
        await manager.setEnabled(false)
        precondition(manager.status == .enabled && manager.isRequested && manager.errorMessage != nil)
        service.status = .notRegistered
        manager.refresh()
        precondition(!manager.isRequested && manager.errorMessage == nil)
        print("PASS: pending approval, missing login item, and failed changes retain the actual system status")

        service.shouldFail = false
        service.status = .enabled
        manager.refresh()
        service.pausesRemoval = true
        let pending = Task { await manager.setEnabled(false) }
        while service.removal == nil { await Task.yield() }
        precondition(manager.isUpdating)
        let registrations = service.registrations
        let removals = service.removals
        await manager.setEnabled(true)
        await manager.setEnabled(false)
        precondition(service.registrations == registrations && service.removals == removals)
        service.removal?.resume()
        await pending.value
        precondition(!manager.isUpdating && !manager.isRequested && manager.errorMessage == nil)
        print("PASS: repeated toggles cannot race an in-flight removal; success clears the previous error")
    }
}
