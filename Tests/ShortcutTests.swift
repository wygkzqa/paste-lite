import AppKit
import Carbon.HIToolbox

@main
@MainActor
struct ShortcutTests {
    static func main() throws {
        _ = NSApplication.shared
        let suite = "PasteLite-shortcut-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        precondition(settings.panelShortcut == .default)
        precondition(PanelShortcut.default.displayName == "⇧⌘V")
        precondition(PanelShortcut.default.modifierFlags == [.command, .shift])
        precondition(!PanelShortcut(keyCode: 9, modifiers: 0).isValid)
        precondition(!PanelShortcut(keyCode: 9, modifiers: UInt32(shiftKey)).isValid)
        precondition(!PanelShortcut(keyCode: UInt32.max, modifiers: UInt32(cmdKey)).isValid)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .option, .capsLock],
                                    timestamp: 0, windowNumber: 0, context: nil, characters: "x",
                                    charactersIgnoringModifiers: "x", isARepeat: false, keyCode: UInt16(kVK_ANSI_X))!
        let captured = PanelShortcut(event: event)
        precondition(captured.modifiers == UInt32(controlKey | optionKey) && captured.displayName == "⌃⌥X")
        precondition(PanelShortcut(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(cmdKey)).keyEquivalent == String(UnicodeScalar(NSLeftArrowFunctionKey)!))

        // Use uncommon combinations, never the user's default app shortcut.
        let initial = PanelShortcut(keyCode: UInt32(kVK_F17), modifiers: UInt32(cmdKey | controlKey | optionKey | shiftKey))
        let replacement = PanelShortcut(keyCode: UInt32(kVK_F18), modifiers: initial.modifiers)
        let manager = GlobalHotKeyManager(settings: settings)
        defer { manager.unregister() }
        precondition(manager.updateShortcut(initial), manager.errorMessage ?? "Registration failed")
        precondition(AppSettings(defaults: defaults).panelShortcut == initial)
        precondition(manager.updateShortcut(initial), "Reapplying the active shortcut must succeed")

        var blocker: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: 0x54455354, id: 99)
        precondition(RegisterEventHotKey(replacement.keyCode, replacement.modifiers, identifier,
                                        GetApplicationEventTarget(), 0, &blocker) == noErr)
        precondition(!manager.updateShortcut(replacement) && manager.errorMessage != nil)
        precondition(settings.panelShortcut == initial && AppSettings(defaults: defaults).panelShortcut == initial)
        var probe: EventHotKeyRef?
        precondition(RegisterEventHotKey(initial.keyCode, initial.modifiers, identifier,
                                        GetApplicationEventTarget(), 0, &probe) == eventHotKeyExistsErr,
                     "The original shortcut must remain registered after a failed change")
        UnregisterEventHotKey(blocker)
        precondition(manager.updateShortcut(replacement))
        precondition(settings.panelShortcut == replacement && manager.errorMessage == nil)
        print("PASS: shortcut validation, key display, persistence, replacement and real Carbon registration conflicts")

        manager.beginRecording()
        precondition(manager.isRecording)
        precondition(RegisterEventHotKey(replacement.keyCode, replacement.modifiers, identifier,
                                        GetApplicationEventTarget(), 0, &probe) == noErr)
        UnregisterEventHotKey(probe)
        precondition(!manager.updateShortcut(PanelShortcut(keyCode: 9, modifiers: 0)))
        precondition(manager.isRecording && settings.panelShortcut == replacement)
        manager.cancelRecording()
        precondition(!manager.isRecording && manager.errorMessage == nil)
        precondition(RegisterEventHotKey(replacement.keyCode, replacement.modifiers, identifier,
                                        GetApplicationEventTarget(), 0, &probe) == eventHotKeyExistsErr)
        manager.beginRecording()
        precondition(manager.updateShortcut(replacement) && !manager.isRecording)
        manager.unregister()
        precondition(RegisterEventHotKey(replacement.keyCode, replacement.modifiers, identifier,
                                        GetApplicationEventTarget(), 0, &probe) == noErr)
        UnregisterEventHotKey(probe)
        print("PASS: recording releases the current shortcut, cancel restores it, and shutdown releases it")

        defaults.set(Data("invalid".utf8), forKey: "panelShortcut")
        precondition(AppSettings(defaults: defaults).panelShortcut == .default)
        defaults.set(try JSONEncoder().encode(PanelShortcut(keyCode: 9, modifiers: 0)), forKey: "panelShortcut")
        precondition(AppSettings(defaults: defaults).panelShortcut == .default)
        print("PASS: invalid saved shortcuts fall back to the default without changing other settings")
    }
}
