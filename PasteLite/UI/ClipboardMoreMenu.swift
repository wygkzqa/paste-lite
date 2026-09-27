import AppKit
import SwiftUI

struct ClipboardMoreMenu: NSViewRepresentable {
    let onOpen: () -> Void
    let onClose: () -> Void
    let onSettings: () -> Void
    let onQuit: () -> Void

    func makeNSView(context: Context) -> MenuButton {
        let button = MenuButton(frame: .zero, pullsDown: true)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.preferredEdge = .maxY
        button.controlSize = .small
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow

        let menu = NSMenu()
        menu.autoenablesItems = false
        // A pull-down button uses its first item as the button label.
        let label = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        label.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        menu.addItem(label)
        let settings = NSMenuItem(title: "", action: #selector(MenuButton.openSettings), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = .command
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settings.target = button
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "", action: #selector(MenuButton.quit), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = .command
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        quit.target = button
        menu.addItem(quit)
        menu.delegate = button
        button.menu = menu
        return button
    }

    func updateNSView(_ button: MenuButton, context: Context) {
        button.actions = self
        button.toolTip = L10n.tr("更多")
        button.setAccessibilityLabel(L10n.tr("更多"))
        button.item(at: 0)?.title = L10n.tr("更多")
        button.item(at: 1)?.title = L10n.tr("设置…")
        button.item(at: 3)?.title = L10n.tr("退出")
    }

    final class MenuButton: NSPopUpButton, NSMenuDelegate {
        var actions: ClipboardMoreMenu?
        override var mouseDownCanMoveWindow: Bool { false }

        func menuWillOpen(_ menu: NSMenu) { actions?.onOpen() }
        func menuDidClose(_ menu: NSMenu) { actions?.onClose() }
        @objc func openSettings() { actions?.onSettings() }
        @objc func quit() { actions?.onQuit() }
    }
}
