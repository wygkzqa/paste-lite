import Foundation
import ImageIO

enum ClipboardImageLoader {
    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 128
        cache.totalCostLimit = 32 * 1_024 * 1_024
        return cache
    }()

    static func load(from url: URL, maxPixelSize: Int) async -> CGImage? {
        await Task.detached(priority: .userInitiated) { () -> CGImage? in
            let key = "\(url.absoluteString)#\(maxPixelSize)" as NSString
            if let image = cache.object(forKey: key) {
                return image
            }
            guard let source = CGImageSourceCreateWithURL(
                url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ) else { return nil }

            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }
            cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
            return image
        }.value
    }
}
