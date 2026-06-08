import Foundation

/// Lightweight stderr logger.
func canvasLog(_ message: String) {
    FileHandle.standardError.write(Data("[canvas] \(message)\n".utf8))
}
