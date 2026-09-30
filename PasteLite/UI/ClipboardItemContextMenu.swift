import AppKit
import SwiftUI

// Handle selection on mouse-down without waiting for SwiftUI tap recognition.
struct ClipboardItemContextMenu: NSViewRepresentable {
    let onSelect: (NSEvent.ModifierFlags) -> Void
    let onDoubleClick: () -> Void
    let onOpen: () -> Void
    let onClose: () -> Void
    let onEdit: () -> Void
    let onPreview: () -> Void
    let groups: [ClipboardGroup]
    let selection: () -> [UUID: Set<UUID>]
    let onSelectAll: () -> Void
    let onGroup: (UUID, Set<UUID>, Bool) -> Void
    let onNewGroup: (Set<UUID>) -> Void
    let onDelete: (Set<UUID>) -> Void

    func makeNSView(context: Context) -> MenuView { MenuView() }

    func updateNSView(_ view: MenuView, context: Context) { view.actions = self }

    final class MenuView: NSView, NSMenuDelegate {
        var actions: ClipboardItemContextMenu?
        private var itemIDs = Set<UUID>()
        private var doubleClickPending = false

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                  event.type == .rightMouseDown || event.type == .leftMouseDown else { return nil }
            return super.hitTest(point)
        }

        override func mouseDown(with event: NSEvent) {
            doubleClickPending = false
            guard !event.modifierFlags.contains(.control) else {
                super.mouseDown(with: event)
                return
            }
            if window?.firstResponder is NSPopUpButton { window?.makeFirstResponder(nil) }
            actions?.onSelect(event.modifierFlags)
            doubleClickPending = event.clickCount == 2 && event.modifierFlags.intersection([.command, .shift]).isEmpty
        }

        override func mouseDragged(with event: NSEvent) {
            doubleClickPending = false
        }

        override func mouseUp(with event: NSEvent) {
            defer { doubleClickPending = false }
            guard doubleClickPending,
                  event.modifierFlags.intersection([.command, .shift, .control]).isEmpty,
                  bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            actions?.onDoubleClick()
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            guard let actions else { return nil }
            if window?.firstResponder is NSPopUpButton { window?.makeFirstResponder(nil) }
            actions.onOpen()
            let selected = actions.selection()
            itemIDs = Set(selected.keys)
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.delegate = self
            for (title, action) in [(L10n.tr("编辑…"), #selector(edit)), (L10n.tr("预览"), #selector(preview))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                item.isEnabled = selected.count == 1
                if action == #selector(preview) {
                    item.keyEquivalent = " "
                    item.keyEquivalentModifierMask = []
                    // AppKit localizes key names using the launch language, not our live language setting.
                    item.view = PreviewMenuItemView(item: item)
                }
                menu.addItem(item)
            }
            let groupMenu = NSMenu()
            for group in actions.groups {
                let item = NSMenuItem(title: group.name, action: #selector(group(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = group.id.uuidString
                let count = selected.values.filter { $0.contains(group.id) }.count
                item.state = count == selected.count ? .on : (count > 0 ? .mixed : .off)
                groupMenu.addItem(item)
            }
            if !actions.groups.isEmpty { groupMenu.addItem(.separator()) }
            let newGroup = NSMenuItem(title: L10n.tr("新建分组…"), action: #selector(createGroup), keyEquivalent: "")
            newGroup.target = self
            groupMenu.addItem(newGroup)
            let groups = NSMenuItem(title: L10n.tr("加入分组"), action: nil, keyEquivalent: "")
            groups.submenu = groupMenu
            menu.addItem(groups)
            menu.addItem(.separator())
            let all = NSMenuItem(title: L10n.tr("全选"), action: #selector(selectAllEntries), keyEquivalent: "a")
            all.keyEquivalentModifierMask = .command
            all.target = self
            menu.addItem(all)
            let deletion = NSMenuItem(title: selected.count > 1 ? L10n.tr("删除选中的 %d 条记录…", selected.count) : L10n.tr("删除…"),
                action: #selector(deleteItems), keyEquivalent: "")
            deletion.target = self
            menu.addItem(deletion)
            return menu
        }

        override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
            actions?.onClose()
        }

        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
            for item in menu.items { item.view?.needsDisplay = true }
        }

        @objc private func edit() { actions?.onEdit() }
        @objc private func preview() { actions?.onPreview() }
        @objc private func group(_ sender: NSMenuItem) {
            guard let value = sender.representedObject as? String, let id = UUID(uuidString: value) else { return }
            actions?.onGroup(id, itemIDs, sender.state != .on)
        }
        @objc private func createGroup() { actions?.onNewGroup(itemIDs) }
        @objc private func selectAllEntries() { actions?.onSelectAll() }
        @objc private func deleteItems() { actions?.onDelete(itemIDs) }
    }

    final class PreviewMenuItemView: NSView {
        private let shortcutLabel = L10n.tr("空格键")
        private var didActivate = false

        init(item: NSMenuItem) {
            let font = NSFont.menuFont(ofSize: 0)
            let textWidth = (item.title as NSString).size(withAttributes: [.font: font]).width
                + (shortcutLabel as NSString).size(withAttributes: [.font: font]).width
            super.init(frame: NSRect(x: 0, y: 0, width: max(160, textWidth + 52), height: ceil(font.ascender - font.descender) + 8))
            autoresizingMask = [.width]
            setAccessibilityElement(true)
            setAccessibilityRole(.menuItem)
            setAccessibilityLabel(item.title)
            setAccessibilityHelp(shortcutLabel)
            setAccessibilityEnabled(item.isEnabled)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var acceptsFirstResponder: Bool { enclosingMenuItem?.isEnabled == true }
        // Keep keyboard activation without taking the menu's initial focus.
        override var canBecomeKeyView: Bool { false }

        override func mouseDown(with event: NSEvent) {}

        override func keyDown(with event: NSEvent) {
            if [36, 49, 76].contains(event.keyCode),
               event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                _ = activate()
            } else {
                super.keyDown(with: event)
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let item = enclosingMenuItem else { return }
            let selected = item.isEnabled && item.isHighlighted
            if selected {
                NSColor.selectedContentBackgroundColor.setFill()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 4, yRadius: 4).fill()
            }
            let font = item.menu?.font ?? NSFont.menuFont(ofSize: 0)
            let color: NSColor = !item.isEnabled ? .disabledControlTextColor : (selected ? .selectedMenuItemTextColor : .labelColor)
            let text = NSAttributedString(string: item.title, attributes: [.font: font, .foregroundColor: color])
            let shortcut = NSAttributedString(string: shortcutLabel,
                attributes: [.font: font, .foregroundColor: item.isEnabled && !selected ? NSColor.tertiaryLabelColor : color])
            text.draw(at: NSPoint(x: 16, y: (bounds.height - text.size().height) / 2))
            shortcut.draw(at: NSPoint(x: bounds.width - 18 - shortcut.size().width, y: (bounds.height - shortcut.size().height) / 2))
        }

        override func mouseUp(with event: NSEvent) {
            guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            _ = activate()
        }

        override func accessibilityPerformPress() -> Bool { activate() }

        private func activate() -> Bool {
            guard !didActivate, let item = enclosingMenuItem, item.isEnabled, let action = item.action else { return false }
            didActivate = true
            item.menu?.cancelTracking()
            return NSApp.sendAction(action, to: item.target, from: item)
        }
    }
}
