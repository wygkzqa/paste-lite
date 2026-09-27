import Carbon.HIToolbox
import Foundation
import Combine

@MainActor
final class GlobalHotKeyManager: ObservableObject {
    enum RegistrationError: LocalizedError {
        case eventHandler(OSStatus)
        case hotKey(OSStatus)

        var errorDescription: String? {
            switch self {
            case .eventHandler(let status):
                return L10n.tr("无法注册快捷键事件处理器（%d）。", status)
            case .hotKey(let status):
                return L10n.tr("无法注册此快捷键，可能已被占用（%d）。", status)
            }
        }
    }

    var action: (() -> Void)?
    @Published private(set) var isRecording = false
    @Published private(set) var errorMessage: String?
    private let settings: AppSettings

    init(settings: AppSettings) { self.settings = settings }

    func start() {
        do {
            try register(settings.panelShortcut)
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func beginRecording() {
        errorMessage = nil
        isRecording = true
        // Release the current combination so the recorder can receive it too.
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
    }

    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        start()
    }

    @discardableResult
    func updateShortcut(_ shortcut: PanelShortcut) -> Bool {
        guard shortcut.isValid else {
            errorMessage = L10n.tr("请使用包含 ⌘、⌥ 或 ⌃ 的组合键。")
            return false
        }
        do {
            // Register first; a failed replacement must not remove the working shortcut.
            if shortcut != settings.panelShortcut || hotKeyRef == nil { try register(shortcut) }
            settings.panelShortcut = shortcut
            errorMessage = nil
            isRecording = false
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private func register(_ shortcut: PanelShortcut) throws {
        if eventHandlerRef == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )

            let handlerStatus = InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, userData in
                    guard let userData else { return OSStatus(eventNotHandledErr) }
                    let manager = Unmanaged<GlobalHotKeyManager>
                        .fromOpaque(userData)
                        .takeUnretainedValue()
                    var identifier = EventHotKeyID()
                    guard let event,
                          GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                            nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                          identifier.signature == 0x5053544C, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
                    DispatchQueue.main.async { if !manager.isRecording { manager.action?() } }
                    return noErr
                },
                1,
                &eventType,
                Unmanaged.passUnretained(self).toOpaque(),
                &eventHandlerRef
            )
            guard handlerStatus == noErr else {
                throw RegistrationError.eventHandler(handlerStatus)
            }
        }

        var newHotKeyRef: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: 0x5053544C, id: 1) // PSTL
        let hotKeyStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &newHotKeyRef
        )
        guard hotKeyStatus == noErr else {
            throw RegistrationError.hotKey(hotKeyStatus)
        }
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = newHotKeyRef
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }
}
