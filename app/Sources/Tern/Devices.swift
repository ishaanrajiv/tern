import Foundation
import Observation

/// Where a folder is. A folder on a device is written `host:/path` in the layout, the way scp
/// writes it; a folder on this Mac is a plain path.
nonisolated struct FolderLocation: Equatable, Sendable {
    let host: String?
    let path: String

    init(host: String?, path: String) {
        self.host = host
        self.path = path
    }

    init(_ string: String) {
        if !string.hasPrefix("/"), let colon = string.firstIndex(of: ":") {
            let host = String(string[..<colon]), rest = String(string[string.index(after: colon)...])
            if Device.validHost(host), rest.isEmpty || rest.hasPrefix("/") || rest.hasPrefix("~") {
                self.host = host
                self.path = rest.isEmpty ? "~" : rest
                return
            }
        }
        host = nil
        path = string
    }

    var string: String { host.map { "\($0):\(path)" } ?? path }

}

// Reads the devices' status, which the main thread keeps.
extension FolderLocation {
    /// The folder's name in the sidebar and picker.
    var name: String {
        guard let host else { return path == NSHomeDirectory() ? "Home" : (path as NSString).lastPathComponent }
        if path == "~" || path == Device.home(host) { return "Home" }
        return path == "/" ? host : (path as NSString).lastPathComponent
    }

    /// The path with home as `~`, the device's home for a folder on a device.
    var shortPath: String {
        guard let host else { return abbreviateHome(path) }
        return Device.abbreviate(path, home: Device.home(host))
    }

    /// `devbox:~/dev/tern`.
    var label: String { host.map { "\($0):\(shortPath)" } ?? shortPath }

}

extension FolderLocation {
    /// Without a trailing slash or doubled ones; `~` stays as typed, since only the device knows its home.
    nonisolated static func normalizeRemote(_ path: String) -> String {
        var p = path
        while p.contains("//") { p = p.replacingOccurrences(of: "//", with: "/") }
        if p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p.isEmpty ? "~" : p
    }
}

/// Other machines reached over SSH, whose ternd runs the sessions of their folders. The tern CLI
/// does the work (crates/tern/src/bin/tern/link.rs): `tern link HOST` holds the connection and
/// offers the device's ternd on a socket in the runtime folder, beside the Mac's own.
nonisolated enum Device {
    /// An alias from ~/.ssh/config or `user@host`: what `tern link` accepts.
    static func validHost(_ host: String) -> Bool {
        !host.isEmpty && host.utf8.count <= 255 && !host.hasPrefix("-")
            && host.utf8.allSatisfy { c in
                (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || "-_.@".utf8.contains(c)
            }
    }

    /// The device's files in devices/: the host itself when short, else a hash of it (as tern does).
    static func fileName(_ host: String) -> String {
        if host.utf8.count <= 32 && validHost(host) { return host }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in host.utf8 { hash = (hash ^ UInt64(b)) &* 0x0100_0000_01b3 }
        return "h-" + String(format: "%016llx", hash)
    }

    static var directory: String { TernClient.runtimeDir + "/devices" }
    static func socketPath(_ host: String) -> String { directory + "/" + fileName(host) + ".sock" }
    static func statusPath(_ host: String) -> String { directory + "/" + fileName(host) + ".json" }

    static func abbreviate(_ path: String, home: String?) -> String {
        guard let home, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// This Mac's id, which ternd records on the sessions it starts for it, here or on a device.
    /// The tern CLI keeps it in the runtime folder; whichever writes it first wins.
    static let clientID: String = {
        let path = TernClient.runtimeDir + "/client-id"
        func read() -> String? {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return id.hasPrefix("c-") && id.count == 18 ? id : nil
        }
        var bytes = [UInt8](repeating: 0, count: 8)
        arc4random_buf(&bytes, bytes.count)
        let id = "c-" + bytes.map { String(format: "%02x", $0) }.joined()
        // Unit tests get one of their own rather than writing into the real runtime dir.
        if NSClassFromString("XCTestCase") != nil { return id }
        if let id = read() { return id }
        try? FileManager.default.createDirectory(atPath: TernClient.runtimeDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if fd >= 0 {
            _ = id.withCString { write(fd, $0, strlen($0)) }
            close(fd)
            return id
        }
        return read() ?? id
    }()

    /// Whether the app may take a session for one of its tabs: one this Mac started, or one
    /// started from the CLI. Another Mac sharing the ternd keeps its own.
    static func isOurs(_ session: SessionInfo) -> Bool {
        session.owner == nil || session.owner == clientID
    }
}

extension Device {
    /// The device's home folder, once its link has reached it.
    static func home(_ host: String) -> String? { DeviceCenter.shared.statuses[host]?.home }
}

extension SessionInfo {
    /// Where the session is, as headers show it: `~/dev/tern`, or `devbox:~/dev/tern` on a device.
    var place: String? {
        guard let cwd else { return nil }
        guard let host else { return abbreviateHome(cwd) }
        return "\(host):" + Device.abbreviate(cwd, home: Device.home(host))
    }

    /// Where a tab for this session starts: its folder, on whichever machine it runs.
    var startDirectory: String { cwd ?? (host == nil ? NSHomeDirectory() : "~") }
}

/// How a device's link is doing, from devices/HOST.json (see `tern::device::Status`).
nonisolated struct DeviceStatus: Decodable, Equatable, Sendable {
    /// connecting, installing, connected, sign_in, unreachable, incompatible, unsupported or stopped.
    var state: String
    var message: String?
    var os: String?
    var arch: String?
    var home: String?
    var version: String?
    var `protocol`: Int?
    var current: Bool?
    var pid: Int32?

    static let stopped = DeviceStatus(state: "stopped")

    init(state: String) { self.state = state }

    /// The status file, unless the link that wrote it has gone.
    static func read(_ host: String) -> DeviceStatus {
        guard let data = FileManager.default.contents(atPath: Device.statusPath(host)),
              var status = try? JSONDecoder().decode(DeviceStatus.self, from: data) else { return .stopped }
        if let pid = status.pid, pid > 0, kill(pid, 0) != 0, errno == ESRCH { status.state = "stopped" }
        return status
    }

    var connected: Bool { state == "connected" }
    var needsSignIn: Bool { state == "sign_in" }
    /// Something only the user can fix.
    var failed: Bool { ["sign_in", "unreachable", "incompatible", "unsupported"].contains(state) }

    /// One line for the sidebar and Settings.
    var summary: String {
        switch state {
        case "connected": current == false ? "Connected · its ternd isn't this version of tern; restart it to update" : "Connected"
        case "connecting", "stopped": "Connecting…"
        case "installing": "Installing tern…"
        case "sign_in": "Needs you to sign in"
        case "incompatible": "Its ternd needs a restart"
        case "unsupported": "No tern build for \(os ?? "this system") \(arch ?? "")"
        default: message.map { "Can't connect: \($0)" } ?? "Can't connect"
        }
    }
}

/// The devices tern talks to: their links' status, and their sessions as a stream for the app.
@Observable
final class DeviceCenter {
    static let shared = DeviceCenter()

    /// Every device seen this run, by host.
    private(set) var statuses: [String: DeviceStatus] = [:]
    @ObservationIgnored var ternBinary = ""
    /// Opens a tab that signs in to a device (Settings has no window of its own to open it in).
    @ObservationIgnored var onSignIn: ((String) -> Void)?
    /// A device's session list, or nil when its watch stops.
    @ObservationIgnored var onSessions: ((String, [SessionInfo]?) -> Void)?
    @ObservationIgnored private var watches: [String: DeviceWatch] = [:]
    @ObservationIgnored private var timer: Timer?

    /// Devices from Settings → Devices (`device =` in the config file).
    var configured: [String] { Prefs.deviceList }

    /// Watches these devices' sessions, and stops watching the rest.
    func watch(_ hosts: Set<String>) {
        for host in hosts where watches[host] == nil && Device.validHost(host) {
            let watch = DeviceWatch(host: host, tern: ternBinary) { [weak self] list in self?.onSessions?(host, list) }
            watches[host] = watch
            watch.start()
        }
        for (host, watch) in watches where !hosts.contains(host) {
            watch.stop()
            watches[host] = nil
            onSessions?(host, nil)
        }
        refresh()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { DeviceCenter.shared.refresh() }
            }
        }
    }

    var watched: Set<String> { Set(watches.keys) }

    /// Rereads the status of every device in use, Settings' or the picker's.
    func refresh() {
        for host in Set(watches.keys).union(configured).union(asked) {
            let status = DeviceStatus.read(host)
            if statuses[host] != status { statuses[host] = status }
        }
    }

    /// Devices the folder picker or Settings asked about, whose status is kept fresh too.
    @ObservationIgnored private var asked: Set<String> = []

    /// Starts the device's link unless it runs. Off the main thread: it can take a moment.
    func ensure(_ host: String) {
        asked.insert(host)
        let tern = ternBinary
        DispatchQueue.global(qos: .userInitiated).async { Self.ensureNow(host, tern: tern) }
    }

    nonisolated static func ensureNow(_ host: String, tern: String) {
        _ = run(tern, ["link", host, "--ensure"])
    }

    /// Tries again now (after signing in elsewhere, or to reconnect).
    func reconnect(_ host: String) {
        let tern = ternBinary
        DispatchQueue.global(qos: .userInitiated).async {
            if DeviceStatus.read(host).state == "stopped" { Self.ensureNow(host, tern: tern) } else { _ = Self.run(tern, ["link", host, "--wake"]) }
        }
    }

    /// Restarts the device's ternd with this build. Its sessions end; their screens come back.
    func restartDaemon(_ host: String, done: @escaping @MainActor @Sendable (String?) -> Void) {
        let tern = ternBinary
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.run(tern, ["link", host, "--restart-daemon"])
            DispatchQueue.main.async { done(result.ok ? nil : result.error) }
        }
    }

    /// The command that signs in to a device in a terminal, answering SSH's questions for its link.
    func signInCommand(_ host: String) -> String {
        "\(quoteShell(ternBinary)) link \(quoteShell(host)) --sign-in"
    }

    /// Runs tern and waits; the error is what it printed when it failed.
    nonisolated static func run(_ tern: String, _ args: [String]) -> (ok: Bool, output: String, error: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tern)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (false, "", error.localizedDescription) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (p.terminationStatus == 0, String(decoding: data, as: UTF8.self), message.replacingOccurrences(of: "Error: ", with: ""))
    }
}

/// Follows one device's session list through its link, starting the link when it isn't running.
nonisolated final class DeviceWatch: @unchecked Sendable {
    let host: String
    private let tern: String
    private let onUpdate: @MainActor ([SessionInfo]) -> Void
    private let lock = NSLock()
    private var stopped = false
    private var connection: LineConnection?

    init(host: String, tern: String, onUpdate: @escaping @MainActor ([SessionInfo]) -> Void) {
        self.host = host
        self.tern = tern
        self.onUpdate = onUpdate
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "tern.device-watch"
        thread.start()
    }

    func stop() {
        lock.withLock {
            stopped = true
            connection?.hangUp()
        }
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func run() {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var ensured = Date.distantPast
        while !isStopped {
            let status = DeviceStatus.read(host)
            if status.connected, let conn = LineConnection(path: Device.socketPath(host), timeout: 0) {
                lock.withLock { connection = conn }
                conn.send(["op": "watch"])
                while let line = conn.readLine() {
                    guard var list = try? decoder.decode([SessionInfo].self, from: line) else { continue }
                    for i in list.indices { list[i].host = host }
                    let update = onUpdate
                    DispatchQueue.main.async { update(list) }
                }
                lock.withLock { connection = nil }
            } else if status.state == "stopped", -ensured.timeIntervalSinceNow > 10 {
                ensured = Date()
                DeviceCenter.ensureNow(host, tern: tern)
            }
            Thread.sleep(forTimeInterval: 1)
        }
    }
}

/// The device's answers for the folder picker (`folders` and `list_dirs`).
nonisolated struct RemoteFolders: Decodable, Sendable {
    let home: String
    let recent: [String]
    let repos: [String]
}

nonisolated struct RemoteDirs: Decodable, Sendable {
    let ok: Bool
    let path: String
    let dirs: [String]
    let error: String?
}

/// One agent's hooks on a device, as `tern hooks status` reports them.
nonisolated struct RemoteHooks: Decodable, Sendable {
    let agent: String
    let installed: Bool
    let available: Bool
}
