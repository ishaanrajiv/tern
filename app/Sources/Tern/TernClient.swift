import Foundation

/// Live state of one ternd session, as reported by `{"op":"list"}` / `{"op":"watch"}`.
nonisolated struct SessionInfo: Decodable, Equatable {
    let id: String
    let pid: Int32
    let cols: Int
    let rows: Int
    let clients: Int
    let cwd: String?
    let process: String
    let title: String
    let gitRoot: String?
    let branch: String?
    let lastOutputMs: UInt64
    let bells: UInt64
    /// "claude" or "codex" when one is running.
    let agent: String?
    /// "idle", "working", "needs_you", "done"; nil without hooks.
    let agentState: String?
    let agentStateMs: UInt64?
    let agentSession: String?
    let agentMessage: String?
    /// What runs in the foreground, or last ran there ("npm run dev"); nil from an older ternd.
    let command: String?
    /// When the shell last finished a command (Unix ms); nil from an older ternd.
    let finishedMs: UInt64?
    var exitCode: Int? = nil
    var durationMs: UInt64? = nil
}

/// How the running ternd compares with this app's, from `tern daemon status`.
nonisolated struct DaemonStatus: Decodable {
    let running: Bool
    /// Speaks this tern's protocol; an older daemon may misread the app.
    let compatible: Bool
    /// The build installed in this app; false means a restart would upgrade it.
    let current: Bool
    let version: String?

    /// `tern daemon status` or `tern daemon restart`; nil if tern couldn't run.
    static func run(_ action: String, tern: String) -> DaemonStatus? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tern)
        p.arguments = ["daemon", action]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return try? JSONDecoder().decode(DaemonStatus.self, from: data)
    }
}

/// Talks to ternd over its unix socket (see crates/tern/src/lib.rs for the protocol).
nonisolated enum TernClient {
    static let socketPath: String = {
        if let dir = ProcessInfo.processInfo.environment["TERN_RUNTIME_DIR"] {
            return dir + "/ternd.sock"
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/tern/ternd.sock").path
    }()

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    /// The current session list, or nil if ternd isn't running.
    static func listNow() -> [SessionInfo]? {
        guard let conn = LineConnection(path: socketPath) else { return nil }
        conn.send(["op": "list"])
        guard let line = conn.readLine() else { return nil }
        return try? decoder.decode([SessionInfo].self, from: line)
    }

    static func kill(_ id: String) {
        DispatchQueue.global().async {
            guard let conn = LineConnection(path: socketPath) else { return }
            conn.send(["op": "kill", "id": id])
            _ = conn.readLine()
        }
    }

    static func output(_ id: String, lastCommand: Bool = false) -> TerminalOutput? {
        guard let conn = LineConnection(path: socketPath, maximumLine: 64 << 20) else { return nil }
        conn.send(["op": "read_output", "id": id, "last_command": lastCommand])
        guard let data = conn.readLine() else { return nil }
        return try? JSONDecoder().decode(TerminalOutput.self, from: data)
    }

    static func setScrollback(_ bytes: Int) {
        DispatchQueue.global(qos: .utility).async {
            guard let conn = LineConnection(path: socketPath) else { return }
            conn.send(["op": "set_scrollback", "bytes": bytes])
            _ = conn.readLine()
        }
    }

    /// Streams session lists to `onUpdate` on the main queue, reconnecting forever.
    static func watch(_ onUpdate: @escaping @MainActor ([SessionInfo]) -> Void) {
        let thread = Thread {
            while true {
                if let conn = LineConnection(path: socketPath) {
                    conn.send(["op": "watch"])
                    while let line = conn.readLine() {
                        guard let list = try? decoder.decode([SessionInfo].self, from: line) else { continue }
                        DispatchQueue.main.async { onUpdate(list) }
                    }
                }
                // ternd not up yet (the first `tern attach` starts it) or it restarted.
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        thread.name = "tern.watch"
        thread.start()
    }
}

/// A blocking unix-socket connection that speaks newline-delimited JSON.
nonisolated final class LineConnection {
    /// A longer line than any session list is junk; the connection is dropped.
    static let maxLine = 16 << 20

    private let maximumLine: Int
    private let fd: Int32
    private var buffer = Data()

    init(fd: Int32) { self.fd = fd; maximumLine = Self.maxLine }

    init?(path: String, maximumLine: Int = LineConnection.maxLine) {
        self.maximumLine = maximumLine
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLen else { close(fd); return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard ok else { close(fd); return nil }
    }

    deinit { close(fd) }

    func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return }
                offset += n
            }
        }
    }

    func readLine() -> Data? {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        // Bytes already searched for a newline, so a long line isn't rescanned on every read.
        var searched = 0
        while true {
            if let nl = buffer[(buffer.startIndex + searched)...].firstIndex(of: 0x0A) {
                guard buffer.distance(from: buffer.startIndex, to: nl) <= maximumLine else { return nil }
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                return Data(line)
            }
            searched = buffer.count
            if buffer.count > maximumLine { return nil }
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            buffer.append(chunk, count: n)
        }
    }
}
