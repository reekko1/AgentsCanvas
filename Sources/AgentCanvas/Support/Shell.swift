import Foundation

/// Quote `s` so it survives as a single word on a POSIX shell command line.
func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
