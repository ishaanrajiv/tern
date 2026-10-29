import Foundation

/// The names agents give their conversations, read from their own files: Claude Code's title
/// (the one `/rename` sets, else the one it generates from the first prompt) and Codex's thread
/// name. A tab running one goes by it.
nonisolated enum AgentNames {
    /// What earlier lookups learnt, so each one reads only what's new.
    struct Cache: Sendable {
        var claude: [String: ClaudeTranscript] = [:]
        var codexModified: Date?
        var codex: [String: String] = [:]
    }

    struct ClaudeTranscript: Sendable {
        var url: URL?
        /// Bytes already read, up to the end of the last whole line.
        var offset: UInt64 = 0
        var custom: String?
        var generated: String?
        var name: String? { custom ?? generated }
    }

    static let claudeRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    static let codexRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")

    /// Names by session id for these conversations. Blocking; call it off the main thread.
    static func lookup(_ refs: [AgentRef], cache: Cache, claudeRoot: URL = claudeRoot, codexRoot: URL = codexRoot) -> ([String: String], Cache) {
        var cache = cache
        var names: [String: String] = [:]
        if refs.contains(where: { $0.agent == "codex" }) { readCodex(codexRoot, into: &cache) }
        for ref in refs {
            switch ref.agent {
            case "claude":
                var transcript = cache.claude[ref.session] ?? ClaudeTranscript()
                if transcript.url == nil { transcript.url = findTranscript(ref.session, in: claudeRoot) }
                if let url = transcript.url { read(url, into: &transcript) }
                cache.claude[ref.session] = transcript
                names[ref.session] = transcript.name
            case "codex":
                names[ref.session] = cache.codex[ref.session]
            default:
                break
            }
        }
        return (names, cache)
    }

    /// `<root>/<project>/<session>.jsonl`; the project folder is the working directory, encoded.
    private static func findTranscript(_ session: String, in root: URL) -> URL? {
        guard !session.contains("/"), let projects = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        return projects.lazy.map { $0.appendingPathComponent(session + ".jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func read(_ url: URL, into transcript: inout ClaudeTranscript) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        // Rewritten from scratch: start over.
        if size < transcript.offset { transcript = ClaudeTranscript(url: url) }
        guard size > transcript.offset else { return }
        try? handle.seek(toOffset: transcript.offset)
        guard let data = try? handle.readToEnd(), let end = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        transcript.offset += UInt64(end - data.startIndex + 1)
        for line in data[..<end].split(separator: UInt8(ascii: "\n")) {
            let text = String(decoding: line, as: UTF8.self)
            // Most lines are messages; parse only the ones that can name the conversation.
            guard text.contains("-title\""),
                  let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            switch json["type"] as? String {
            case "custom-title": transcript.custom = nonblank(json["customTitle"]) ?? transcript.custom
            case "ai-title": transcript.generated = nonblank(json["aiTitle"]) ?? transcript.generated
            default: break
            }
        }
    }

    private static func nonblank(_ value: Any?) -> String? {
        (value as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    /// `session_index.jsonl`: one line per rename, the last one for a thread wins.
    private static func readCodex(_ root: URL, into cache: inout Cache) {
        let url = root.appendingPathComponent("session_index.jsonl")
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let modified, modified != cache.codexModified, let data = try? Data(contentsOf: url) else { return }
        cache.codexModified = modified
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = json["id"] as? String, let name = nonblank(json["thread_name"]) else { continue }
            cache.codex[id] = name
        }
    }
}
