import Foundation

enum TerminalLink {
    static func url(_ text: String) -> URL? {
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto", "file", "ssh", "vscode", "vscode-insiders", "cursor", "zed"].contains(scheme) else { return nil }
        return url
    }
}
