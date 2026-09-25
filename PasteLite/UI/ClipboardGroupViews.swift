import AppKit
import SwiftUI

struct ClipboardGroupContextMenu: NSViewRepresentable {
    let onOpen: () -> Void
    let onClose: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    func makeNSView(context: Context) -> MenuView { MenuView() }
    func updateNSView(_ view: MenuView, context: Context) { view.actions = self }

    final class MenuView: NSView {
        var actions: ClipboardGroupContextMenu?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                  event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) else { return nil }
            return super.hitTest(point)
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            guard let actions else { return nil }
            actions.onOpen()
            let menu = NSMenu()
            let rename = NSMenuItem(title: L10n.tr("重命名"), action: #selector(renameGroup), keyEquivalent: "")
            rename.target = self
            menu.addItem(rename)
            menu.addItem(.separator())
            let delete = NSMenuItem(title: L10n.tr("删除分组"), action: #selector(deleteGroup), keyEquivalent: "")
            delete.target = self
            menu.addItem(delete)
            return menu
        }

        override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) { actions?.onClose() }
        @objc private func renameGroup() { actions?.onRename() }
        @objc private func deleteGroup() { actions?.onDelete() }
    }
}

enum ClipboardSheet: Identifiable {
    case editGroup(ClipboardGroup?)
    case createGroup(Set<UUID>)
    case deleteGroup(ClipboardGroup)
    case deleteItems(Set<UUID>)
    case error(String)
    case preview(ClipboardItem)
    case edit(ClipboardItem)

    var id: String {
        switch self {
        case .editGroup(let group): "group-\(group?.id.uuidString ?? "new")"
        case .createGroup: "create-group-for-items"
        case .deleteGroup(let group): "delete-group-\(group.id)"
        case .deleteItems: "delete-items"
        case .error: "action-error"
        case .preview(let item): "preview-\(item.id)"
        case .edit(let item): "edit-\(item.id)"
        }
    }
}

struct ClipboardGroupEditor: View {
    @ObservedObject var repository: ClipboardRepository
    let group: ClipboardGroup?
    var itemIDs: Set<UUID> = []
    let onSave: (ClipboardGroup) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var saving = false
    @State private var error: String?
    @State private var confirmsDelete = false
    @State private var createdGroup: ClipboardGroup?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(group == nil ? L10n.tr("新建分组") : L10n.tr("编辑分组")).font(.headline)
            TextField(L10n.tr("分组名称"), text: $name).textFieldStyle(.roundedBorder)
                .focused($focused).onSubmit(save)
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if group != nil {
                    Button(L10n.tr("删除分组"), role: .destructive) { confirmsDelete = true }
                }
                Spacer()
                Button(L10n.tr("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(group == nil ? L10n.tr("创建") : L10n.tr("保存"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 340).disabled(saving)
        .onAppear { name = group?.name ?? ""; focused = true }
        .alert(L10n.tr("删除分组？"), isPresented: $confirmsDelete) {
            Button(L10n.tr("取消"), role: .cancel) {}
            Button(L10n.tr("删除分组"), role: .destructive) {
                guard let group else { return }
                saving = true
                Task {
                    defer { saving = false }
                    do { try await repository.deleteGroup(id: group.id); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            }
        } message: { Text(L10n.tr("只移除分组及归属关系，历史记录会保留。")) }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                let saved = try await repository.saveGroup(id: group?.id ?? createdGroup?.id, name: name)
                if !itemIDs.isEmpty {
                    createdGroup = saved
                    try await repository.setGroup(saved.id, for: itemIDs, included: true)
                }
                onSave(saved)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct ClipboardGroupDeleteConfirmation: View {
    let repository: ClipboardRepository
    let group: ClipboardGroup
    @Environment(\.dismiss) private var dismiss
    @State private var deleting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("删除分组“%@”？", group.name)).font(.headline)
            Text(L10n.tr("记录会保留在全部历史中。没有其他分组的记录将变为未分组，其他分组归属不受影响。"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button(L10n.tr("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.tr("删除分组"), role: .destructive) {
                    guard !deleting else { return }
                    deleting = true
                    error = nil
                    Task {
                        defer { deleting = false }
                        do { try await repository.deleteGroup(id: group.id); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
        }.padding(20).frame(width: 340).disabled(deleting)
    }
}

struct ClipboardDeleteConfirmation: View {
    let repository: ClipboardRepository
    let itemIDs: Set<UUID>
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var deletionFinished = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("删除 %d 条记录？", itemIDs.count)).font(.headline)
            Text(L10n.tr("记录将从全部历史及所有分组中删除，无法撤销。外部原文件不会删除。"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button(deletionFinished ? L10n.tr("关闭") : L10n.tr("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                if !deletionFinished { Button(L10n.tr("删除"), role: .destructive, action: delete) }
            }
        }.padding(20).frame(width: 340).disabled(saving)
    }

    private func delete() {
        guard !saving else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false; ClipboardImageLoader.clearCache() }
            do {
                try await repository.deleteItems(itemIDs)
                dismiss()
            } catch ClipboardDeleteError.filesRemain {
                deletionFinished = true
                error = ClipboardDeleteError.filesRemain.localizedDescription
            } catch { self.error = error.localizedDescription }
        }
    }
}
