import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

enum SourceAppIcon {
    static func filename(for bundleID: String) -> String {
        SHA256.hash(data: Data(bundleID.utf8)).map { String(format: "%02x", $0) }.joined() + ".png"
    }

    static func snapshot(from image: NSImage?) -> CGImage? {
        var rect = CGRect(x: 0, y: 0, width: 64, height: 64)
        return image?.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    static func installedIcon(for bundleID: String) -> CGImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return snapshot(from: NSWorkspace.shared.icon(forFile: url.path))
    }

    static func pngData(from image: CGImage) -> Data? {
        guard let context = CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let scale = min(64 / CGFloat(image.width), 64 / CGFloat(image.height))
        let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (64 - width) / 2, y: (64 - height) / 2, width: width, height: height))
        guard let resized = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, resized, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
