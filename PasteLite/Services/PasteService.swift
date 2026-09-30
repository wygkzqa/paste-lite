import AppKit

@MainActor
final class PasteService {
    private let pasteboard: NSPasteboard
    private let repository: ClipboardRepository
    private let monitor: ClipboardMonitor

    init(
        repository: ClipboardRepository,
        monitor: ClipboardMonitor,
        pasteboard: NSPasteboard = .general
    ) {
        self.repository = repository
        self.monitor = monitor
        self.pasteboard = pasteboard
    }

    @discardableResult
    func writeToPasteboard(_ item: ClipboardItem) -> Bool {
        pasteboard.clearContents()

        let succeeded: Bool
        switch item.type {
        case .text:
            succeeded = item.textContent.map { pasteboard.setString($0, forType: .string) } ?? false

        case .url:
            if let text = item.textContent, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                let entry = NSPasteboardItem()
                entry.setString(text, forType: .string)
                entry.setString(url.absoluteString, forType: .URL)
                succeeded = pasteboard.writeObjects([entry])
            } else {
                succeeded = false
            }

        case .image:
            if let url = repository.assetURL(for: item), let image = NSImage(contentsOf: url) {
                succeeded = pasteboard.writeObjects([image])
            } else {
                succeeded = false
            }

        case .file:
            let urls = item.filePaths
                .map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            succeeded = !urls.isEmpty && pasteboard.writeObjects(urls as [NSURL])
        }

        if succeeded {
            monitor.markCurrentChangeHandled()
            repository.markUsed(item)
        }
        return succeeded
    }
}
