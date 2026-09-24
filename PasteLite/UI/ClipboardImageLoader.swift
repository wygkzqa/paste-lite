import Foundation
import ImageIO

// Both thumbnail decoding and file checks share a bounded queue; scrolling cannot flood I/O.
private let resourceQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "com.local.PasteLite.resources"
    queue.qualityOfService = .userInitiated
    queue.maxConcurrentOperationCount = 2
    return queue
}()

private final class ResourceOperation<Value>: Operation, @unchecked Sendable {
    let work: (ResourceOperation<Value>) -> Value?
    private(set) var value: Value?

    init(work: @escaping (ResourceOperation<Value>) -> Value?) { self.work = work }

    override func main() {
        guard !isCancelled else { return }
        value = autoreleasepool { work(self) }
    }
}

private func loadResource<Value>(_ work: @escaping (ResourceOperation<Value>) -> Value?) async -> Value? {
    guard !Task.isCancelled else { return nil }
    let operation = ResourceOperation(work: work)
    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            operation.completionBlock = { [weak operation] in
                continuation.resume(returning: operation?.isCancelled == false ? operation?.value : nil)
            }
            resourceQueue.addOperation(operation)
        }
    } onCancel: {
        operation.cancel()
    }
}

enum ClipboardImageLoader {
    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 128
        cache.totalCostLimit = 32 * 1_024 * 1_024
        return cache
    }()

    static func clearCache() {
        resourceQueue.cancelAllOperations()
        cache.removeAllObjects()
    }

    static func load(from url: URL, fallbackURL: URL? = nil, maxPixelSize: Int) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let key = "\(url.absoluteString)#\(fallbackURL?.absoluteString ?? "")#\(maxPixelSize)" as NSString
        if let image = cache.object(forKey: key) { return image }
        return await loadResource { operation in
            if let image = cache.object(forKey: key) { return image }
            for candidate in [url, fallbackURL].compactMap({ $0 }) {
                guard !operation.isCancelled else { return nil }
                guard let source = CGImageSourceCreateWithURL(
                    candidate as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary
                ) else { continue }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                    kCGImageSourceShouldCacheImmediately: true
                ]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { continue }
                // ImageIO cannot interrupt an in-progress decode; do not retain or publish cancelled work.
                guard !operation.isCancelled else { return nil }
                cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
                return image
            }
            return nil
        }
    }
}

enum ClipboardFileStatus {
    static func filesExist(_ paths: [String]) async -> Bool? {
        await loadResource { operation in
            for path in paths {
                guard !operation.isCancelled else { return nil }
                if !FileManager.default.fileExists(atPath: path) { return false }
            }
            return true
        }
    }
}
