import AppKit
import SwiftUI

// Native menu timing selects the row before the menu opens, without changing left-click gestures.
struct ClipboardItemContextMenu: NSViewRepresentable {
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

    final class MenuView: NSView {
        var actions: ClipboardItemContextMenu?
        private var itemIDs = Set<UUID>()

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                  event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) else { return nil }
            return super.hitTest(point)
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            guard let actions else { return nil }
            actions.onOpen()
            let selected = actions.selection()
            itemIDs = Set(selected.keys)
            let menu = NSMenu()
            menu.autoenablesItems = false
            for (title, action) in [(L10n.tr("编辑…"), #selector(edit)), (L10n.tr("预览"), #selector(preview))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                item.isEnabled = selected.count == 1
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
}
