import AppKit
import Foundation

private final class TestFileManager: FileManager, @unchecked Sendable {
    let root: URL

    init(root: URL) {
        self.root = root
        super.init()
    }

    override func urls(for directory: SearchPathDirectory, in domainMask: SearchPathDomainMask) -> [URL] {
        directory == .applicationSupportDirectory ? [root] : super.urls(for: directory, in: domainMask)
    }
}

@main
@MainActor
struct ClipboardImageTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteLite-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ClipboardRepository(fileManager: TestFileManager(root: root))
        let viewModel = ClipboardViewModel(repository: repository)
        // Use a private pasteboard so tests never overwrite the user's clipboard.
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let monitor = ClipboardMonitor(repository: repository, pasteboard: board)
        monitor.start()
        defer { monitor.stop() }

        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 160,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let color = NSColor(deviceRed: 0.2, green: 0.3, blue: 0.8, alpha: 1)
        for y in 0..<160 {
            for x in 0..<320 { bitmap.setColor(color, atX: x, y: y) }
        }

        let formats: [(NSBitmapImageRep.FileType, NSPasteboard.PasteboardType)] = [
            (.png, .png), (.tiff, .tiff), (.jpeg, .init("public.jpeg"))
        ]
        viewModel.contentFilter = .image
        for (index, format) in formats.enumerated() {
            // Make each capture distinct even after conversion to PNG.
            bitmap.setColor(.init(deviceRed: CGFloat(index) / 3, green: 0.8, blue: 0.1, alpha: 1), atX: 0, y: 0)
            let data = bitmap.representation(using: format.0, properties: [:])!
            board.clearContents()
            board.setData(data, forType: format.1)
            waitUntil { repository.items.count == index + 1 }
            waitUntil { viewModel.filteredItems.count == index + 1 }
            let item = repository.items[0]
            precondition(item.type == .image)
            checkImage(at: repository.previewURL(for: item)!, maxPixelSize: 128)
            checkImage(at: repository.assetURL(for: item)!, maxPixelSize: 1_200)
            print("PASS: \(format.1.rawValue) capture, filter, thumbnail and preview")
        }

        let jpegURL = root.appendingPathComponent("fixture.JPG")
        try bitmap.representation(using: .jpeg, properties: [:])!.write(to: jpegURL)
        board.clearContents()
        board.writeObjects([jpegURL as NSURL])
        waitUntil { repository.items.count == 4 }
        waitUntil { viewModel.filteredItems.count == 4 }
        let imageFile = repository.items[0]
        precondition(imageFile.type == .file && imageFile.hasImage)
        checkImage(at: repository.previewURL(for: imageFile)!, maxPixelSize: 128)
        checkImage(at: repository.assetURL(for: imageFile)!, maxPixelSize: 1_200)
        let pasteService = PasteService(repository: repository, monitor: monitor, pasteboard: board)
        precondition(pasteService.writeToPasteboard(imageFile))
        let pastedURLs = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        precondition(pastedURLs == [jpegURL])
        print("PASS: JPEG file appears in images, has previews and still pastes as a file")

        viewModel.query = "  图片  "
        waitUntil { viewModel.filteredItems.count == 4 }
        // Wait for the debounced query, not just the previous matching count.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(viewModel.filteredItems.count == 4)
        viewModel.sourceFilter = "nonexistent-test-source"
        waitUntil { viewModel.filteredItems.isEmpty }
        viewModel.sourceFilter = ""
        waitUntil { viewModel.filteredItems.count == 4 }
        viewModel.query = "fixture.JPG"
        waitUntil { viewModel.filteredItems.map(\.id) == [imageFile.id] }
        print("PASS: image title search, filename search and source filter")

        viewModel.query = ""
        viewModel.contentFilter = .file
        waitUntil { viewModel.filteredItems.map(\.id) == [imageFile.id] }
        let textFile = root.appendingPathComponent("fixture.txt")
        try Data("example".utf8).write(to: textFile)
        board.clearContents()
        board.writeObjects([textFile as NSURL])
        waitUntil { repository.items.count == 5 }
        let fileItem = repository.items[0]
        precondition(!fileItem.hasImage && repository.previewURL(for: fileItem) == nil)
        viewModel.contentFilter = .image
        waitUntil { viewModel.filteredItems.count == 4 }
        precondition(!viewModel.filteredItems.contains(where: { $0.id == fileItem.id }))
        print("PASS: ordinary files remain excluded from images")

        let reloaded = ClipboardRepository(fileManager: TestFileManager(root: root))
        waitUntil { reloaded.items.count == 5 }
        let reloadedImages = ClipboardViewModel(repository: reloaded)
        reloadedImages.contentFilter = .image
        waitUntil { reloadedImages.filteredItems.count == 4 }
        precondition(reloaded.previewURL(for: imageFile) == jpegURL)
        print("PASS: existing records retain image classification after reload")

        var finished = false
        Task {
            let missing = await ClipboardImageLoader.load(from: root.appendingPathComponent("missing.png"), maxPixelSize: 128)
            precondition(missing == nil)
            finished = true
        }
        waitUntil { finished }
        print("PASS: missing image returns an empty preview safely")
    }

    private static func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(6)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        precondition(condition(), "Timed out waiting for clipboard or storage update")
    }

    private static func checkImage(at url: URL, maxPixelSize: Int) {
        var finished = false
        Task {
            let image = await ClipboardImageLoader.load(from: url, maxPixelSize: maxPixelSize)
            precondition(image != nil, "Image failed to decode")
            precondition(max(image!.width, image!.height) <= maxPixelSize)
            precondition(image!.width == image!.height * 2, "Image aspect ratio changed")
            finished = true
        }
        waitUntil { finished }
    }
}
