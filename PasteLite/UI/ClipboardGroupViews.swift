import AppKit
import SwiftUI

extension ClipboardGroupColor {
    var displayColor: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .gray: .gray
        }
    }
}

struct ClipboardGroupTab: View {
    static let spacing: CGFloat = 5
    let isSelected: Bool
    let actions: ClipboardGroupActions
    private var group: ClipboardGroup { actions.group }
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false

    var body: some View {
        Button(action: actions.onSelect) {
            HStack(spacing: 5) {
                if let color = group.color {
                    Circle().fill(color.displayColor).frame(width: 7, height: 7)
                }
                Text(group.name).font(.system(size: 12)).lineLimit(1)
            }
            .frame(maxWidth: 160)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(.primary.opacity(isSelected || isDragging ? 0.20 : 0), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(group.name)
        .accessibilityLabel(group.name)
        .accessibilityValue(group.color?.title ?? L10n.tr("无标识色"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .shadow(color: .black.opacity(isDragging ? 0.18 : 0), radius: 3, y: 1)
        .offset(x: dragOffset)
        // Keep the native event surface in its layout position while the label moves.
        .overlay {
            ClipboardGroupInteraction(actions: actions, onDragPreview: { offset, dragging in
                dragOffset = offset
                isDragging = dragging
            })
        }
        .zIndex(isDragging ? 1 : 0)
    }
}

struct ClipboardGroupActions {
    let group: ClipboardGroup
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onClose: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onColor: (ClipboardGroupColor?) -> Void
    let onMove: (UUID, Bool) -> Void
}

struct ClipboardGroupInteraction: NSViewRepresentable {
    let actions: ClipboardGroupActions
    let onDragPreview: (CGFloat, Bool) -> Void

    func makeNSView(context: Context) -> MenuView { MenuView() }
    func updateNSView(_ view: MenuView, context: Context) { view.interaction = self }
    static func dismantleNSView(_ view: MenuView, coordinator: ()) {
        view.interaction = nil
        // SwiftUI is tearing down its graph here; reset neighbouring labels afterwards.
        Task { @MainActor in view.cancelDrag() }
    }

    final class MenuView: NSView {
        var interaction: ClipboardGroupInteraction?
        private var dragStart: NSPoint?
        private var isDragging = false
        private weak var dropTarget: MenuView?
        private var dropAfter = false
        private var previewedTabs: [MenuView] = []
        private var dragCancellationObserver: NSObjectProtocol?
        private var scrollTimer: Timer?
        private var lastDragEvent: NSEvent?
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            cancelDrag()
            if event.modifierFlags.contains(.control), let menu = menu(for: event) {
                NSMenu.popUpContextMenu(menu, with: event, for: self)
                interaction?.actions.onClose()
                return
            }
            dragStart = convert(event.locationInWindow, from: nil)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let dragStart else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard isDragging || hypot(point.x - dragStart.x, point.y - dragStart.y) >= 4 else { return }
            if !isDragging {
                isDragging = true
                dragCancellationObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didResignKeyNotification, object: window, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.cancelDrag() }
                }
                let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scrollGroupRow() }
                }
                RunLoop.main.add(timer, forMode: .common)
                scrollTimer = timer
            }
            NSCursor.closedHand.set()
            lastDragEvent = event
            updateDropTarget(with: event)
            updateDragPreview(with: event)
        }

        private func scrollGroupRow() {
            guard isDragging, let event = lastDragEvent,
                  let scrollView = enclosingScrollView, let document = scrollView.documentView else { return }
            let clip = scrollView.contentView
            let row = clip.convert(clip.bounds, to: nil)
            let location = event.locationInWindow
            guard row.contains(location) else { return }
            // Scroll inside the row so releasing at either edge still commits the move.
            let edgeWidth = min(CGFloat(32), row.width / 2)
            let step: CGFloat
            if location.x < row.minX + edgeWidth {
                step = -8 * (1 - (location.x - row.minX) / edgeWidth)
            } else if location.x > row.maxX - edgeWidth {
                step = 8 * (1 - (row.maxX - location.x) / edgeWidth)
            } else { return }
            let maximum = max(document.bounds.minX, document.bounds.maxX - clip.bounds.width)
            let x = min(maximum, max(document.bounds.minX, clip.bounds.minX + step))
            guard x != clip.bounds.minX else { return }
            clip.scroll(to: NSPoint(x: x, y: clip.bounds.minY))
            scrollView.reflectScrolledClipView(clip)
            updateDropTarget(with: event)
            updateDragPreview(with: event)
        }

        override func mouseUp(with event: NSEvent) {
            guard dragStart != nil else { return }
            if isDragging {
                updateDropTarget(with: event)
                // Commit the displayed order and remove preview offsets in the same
                // transaction, so labels settle directly into their new positions.
                withAnimation(dragAnimation) {
                    if let dropTarget, let sourceID = interaction?.actions.group.id {
                        dropTarget.interaction?.actions.onMove(sourceID, dropAfter)
                    }
                    cancelDrag()
                }
            } else if bounds.contains(convert(event.locationInWindow, from: nil)) {
                interaction?.actions.onSelect()
                cancelDrag()
            } else {
                cancelDrag()
            }
        }

        private func updateDropTarget(with event: NSEvent) {
            dropTarget = nil
            guard let scrollView = enclosingScrollView, let document = scrollView.documentView else { return }
            let location = event.locationInWindow
            let row = scrollView.contentView.convert(scrollView.contentView.bounds, to: nil)
            guard row.contains(location) else { return }
            let source = convert(bounds, to: nil)
            guard location.x < source.minX || location.x > source.maxX else { return }
            let tabs = groupTabs(in: document).filter { $0 !== self }
                .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
            // The whole row accepts drops, including gaps and empty ends. Entering a
            // neighbouring tab swaps positions instead of requiring its far half.
            dropAfter = location.x > source.maxX
            if dropAfter {
                dropTarget = tabs.last { $0.convert($0.bounds, to: nil).minX <= location.x }
            } else {
                dropTarget = tabs.first { $0.convert($0.bounds, to: nil).maxX >= location.x }
            }
        }

        private var dragAnimation: Animation? {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.18)
        }

        private func updateDragPreview(with event: NSEvent) {
            guard let dragStart, let document = enclosingScrollView?.documentView else { return }
            let source = convert(bounds, to: nil)
            let target = dropTarget.map { $0.convert($0.bounds, to: nil) }
            previewedTabs = groupTabs(in: document).filter { $0 !== self }
            // The event surfaces stay put; only labels shift to make a gap for the source.
            withAnimation(dragAnimation) {
                for tab in previewedTabs {
                    let frame = tab.convert(tab.bounds, to: nil)
                    var offset: CGFloat = 0
                    if let target {
                        if dropAfter && frame.minX > source.minX && frame.minX <= target.minX {
                            offset = -(source.width + ClipboardGroupTab.spacing)
                        } else if !dropAfter && frame.minX < source.minX && frame.minX >= target.minX {
                            offset = source.width + ClipboardGroupTab.spacing
                        }
                    }
                    tab.interaction?.onDragPreview(offset, false)
                }
            }
            interaction?.onDragPreview(convert(event.locationInWindow, from: nil).x - dragStart.x, true)
        }

        func cancelDrag() {
            scrollTimer?.invalidate()
            scrollTimer = nil
            lastDragEvent = nil
            if let dragCancellationObserver {
                NotificationCenter.default.removeObserver(dragCancellationObserver)
                self.dragCancellationObserver = nil
            }
            for tab in previewedTabs { tab.interaction?.onDragPreview(0, false) }
            previewedTabs.removeAll()
            interaction?.onDragPreview(0, false)
            dropTarget = nil
            dragStart = nil
            isDragging = false
            NSCursor.arrow.set()
        }

        deinit {
            scrollTimer?.invalidate()
            if let dragCancellationObserver { NotificationCenter.default.removeObserver(dragCancellationObserver) }
        }

        private func groupTabs(in view: NSView) -> [MenuView] {
            if let tab = view as? MenuView { return [tab] }
            return view.subviews.flatMap { groupTabs(in: $0) }
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            guard let actions = interaction?.actions else { return nil }
            actions.onOpen()
            let menu = NSMenu()
            let rename = NSMenuItem(title: L10n.tr("重命名"), action: #selector(renameGroup), keyEquivalent: "")
            rename.target = self
            menu.addItem(rename)
            let delete = NSMenuItem(title: L10n.tr("删除分组"), action: #selector(deleteGroup), keyEquivalent: "")
            delete.target = self
            menu.addItem(delete)
            menu.addItem(.separator())
            let colors = NSMenuItem()
            colors.view = NSHostingView(rootView: ClipboardGroupColorPicker(selected: actions.group.color) { [weak self, weak menu] color in
                menu?.cancelTracking()
                self?.interaction?.actions.onColor(color)
            })
            colors.view?.frame = NSRect(x: 0, y: 0, width: 256, height: 54)
            menu.addItem(colors)
            return menu
        }

        override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) { interaction?.actions.onClose() }
        @objc private func renameGroup() { interaction?.actions.onRename() }
        @objc private func deleteGroup() { interaction?.actions.onDelete() }
    }
}

private struct ClipboardGroupColorPicker: View {
    let selected: ClipboardGroupColor?
    let onSelect: (ClipboardGroupColor?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.tr("标识色")).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                colorButton(nil)
                ForEach(ClipboardGroupColor.allCases, id: \.self) { colorButton($0) }
            }
        }.padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func colorButton(_ color: ClipboardGroupColor?) -> some View {
        Button { onSelect(color) } label: {
            ZStack {
                Circle().fill(color?.displayColor ?? Color.secondary.opacity(0.15))
                    .frame(width: 14, height: 14)
                if color == nil {
                    Image(systemName: "nosign").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if selected == color {
                    Circle().strokeBorder(Color.primary.opacity(0.7), lineWidth: 1.5).frame(width: 20, height: 20)
                }
            }.frame(width: 20, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(color?.title ?? L10n.tr("无标识色"))
        .accessibilityLabel(color?.title ?? L10n.tr("无标识色"))
        .accessibilityAddTraits(selected == color ? .isSelected : [])
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
