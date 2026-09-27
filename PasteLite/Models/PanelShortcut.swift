import AppKit
import Carbon.HIToolbox

struct PanelShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let `default` = PanelShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey))

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        let flags = event.modifierFlags
        modifiers = (flags.contains(.command) ? UInt32(cmdKey) : 0)
            | (flags.contains(.option) ? UInt32(optionKey) : 0)
            | (flags.contains(.control) ? UInt32(controlKey) : 0)
            | (flags.contains(.shift) ? UInt32(shiftKey) : 0)
    }

    var isValid: Bool {
        modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
            && modifiers & ~UInt32(cmdKey | optionKey | controlKey | shiftKey) == 0
            && !keyEquivalent.isEmpty
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    var displayName: String {
        let flags = modifierFlags
        return (flags.contains(.control) ? "⌃" : "")
            + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "")
            + (flags.contains(.command) ? "⌘" : "")
            + (specialKey?.label ?? keyEquivalent.uppercased())
    }

    private var specialKey: (label: String, equivalent: String)? {
        switch Int(keyCode) {
        case kVK_Space: return (L10n.tr("空格"), " ")
        case kVK_Return: return ("↩", "\r")
        case kVK_Tab: return ("⇥", "\t")
        case kVK_Delete: return ("⌫", "\u{8}")
        case kVK_ForwardDelete: return ("⌦", String(UnicodeScalar(NSDeleteFunctionKey)!))
        case kVK_Escape: return ("⎋", "\u{1b}")
        case kVK_LeftArrow: return ("←", String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        case kVK_RightArrow: return ("→", String(UnicodeScalar(NSRightArrowFunctionKey)!))
        case kVK_UpArrow: return ("↑", String(UnicodeScalar(NSUpArrowFunctionKey)!))
        case kVK_DownArrow: return ("↓", String(UnicodeScalar(NSDownArrowFunctionKey)!))
        case kVK_Home: return ("↖", String(UnicodeScalar(NSHomeFunctionKey)!))
        case kVK_End: return ("↘", String(UnicodeScalar(NSEndFunctionKey)!))
        case kVK_PageUp: return ("⇞", String(UnicodeScalar(NSPageUpFunctionKey)!))
        case kVK_PageDown: return ("⇟", String(UnicodeScalar(NSPageDownFunctionKey)!))
        default:
            let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
                                kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
                                kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
            guard let index = functionKeys.firstIndex(of: Int(keyCode)) else { return nil }
            return ("F\(index + 1)", String(UnicodeScalar(NSF1FunctionKey + index)!))
        }
    }

    var keyEquivalent: String {
        if let specialKey { return specialKey.equivalent }
        guard keyCode < 128,
              let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "" }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        let layout = UnsafeRawPointer(CFDataGetBytePtr(data)).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                    &deadKeyState, characters.count, &length, &characters)
        guard status == noErr, length > 0 else { return "" }
        let text = String(utf16CodeUnits: characters, count: length).lowercased()
        return text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ? "" : text
    }
}
