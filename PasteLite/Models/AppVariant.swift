import Foundation

enum AppVariant {
    #if BETA
    static let isBeta = true
    #else
    static let isBeta = false
    #endif

    static let displayName = isBeta ? "Paste Lite Beta" : "Paste Lite"
    static let dataDirectoryName = isBeta ? "PasteLiteBeta" : "PasteLite"
    static let importTemporaryPrefix = dataDirectoryName + "-import-"
}
