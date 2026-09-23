import Foundation

struct ClipboardCapture: Sendable {
    let type: ClipboardContentType
    let textContent: String?
    let imageData: Data?
    let filePaths: [String]
    let sourceAppName: String
    let sourceBundleID: String
    let capturedAt: Date
}
