/// Quotes a string for a POSIX shell: single quotes, with embedded ones closed,
/// escaped and reopened. Safe for any byte except NUL.
func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
