import AppKit
import SwiftUI

struct ClipboardTypePicker: NSViewRepresentable {
    @Binding var selection: ContentFilter
    let onOpen: () -> Void
    let onClose: () -> Void

    func makeNSView(context: Context) -> TypeButton {
        let button = TypeButton(frame: .zero, pullsDown: false)
        button.font = .systemFont(ofSize: 13)
        button.preferredEdge = .maxY
        button.target = button
        button.action = #selector(TypeButton.selectType)
        for filter in ContentFilter.allCases {
            button.addItem(withTitle: filter.rawValue)
            button.lastItem?.representedObject = filter.rawValue
        }
        button.menu?.autoenablesItems = false
        button.menu?.delegate = button
        return button
    }

    func updateNSView(_ button: TypeButton, context: Context) {
        button.actions = self
        button.toolTip = L10n.tr("类型")
        button.setAccessibilityLabel(L10n.tr("类型"))
        for (index, filter) in ContentFilter.allCases.enumerated() {
            button.item(at: index)?.title = filter == .all ? L10n.tr("全部类型") : filter.title
            if filter == selection { button.selectItem(at: index) }
        }
    }

    final class TypeButton: NSPopUpButton, NSMenuDelegate {
        var actions: ClipboardTypePicker?
        override var mouseDownCanMoveWindow: Bool { false }

        func menuWillOpen(_ menu: NSMenu) { actions?.onOpen() }
        func menuDidClose(_ menu: NSMenu) {
            if window?.firstResponder === self { window?.makeFirstResponder(nil) }
            actions?.onClose()
        }

        @objc func selectType() {
            guard let rawValue = selectedItem?.representedObject as? String,
                  let filter = ContentFilter(rawValue: rawValue) else { return }
            actions?.selection = filter
        }
    }
}
