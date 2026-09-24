import SwiftUI

enum ClipboardSheet: Identifiable {
    case editGroup(ClipboardGroup?)
    case createGroup(Set<UUID>)
    case deleteItems(Set<UUID>)
    case error(String)
    case preview(ClipboardItem)
    case edit(ClipboardItem)

    var id: String {
        switch self {
        case .editGroup(let group): "group-\(group?.id.uuidString ?? "new")"
        case .createGroup: "create-group-for-items"
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
