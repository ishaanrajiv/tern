import AppKit
import UniformTypeIdentifiers

/// The text of tern's config file, in Ghostty's style: one `key = value` per line, `#` comments,
/// keys that may repeat, and an empty value that clears the ones before it. ternd reads the same
/// file (crates/tern/src/config.rs) and parses it the same way.
nonisolated struct ConfigText: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let line: Int
        let key: String
        let value: String
    }

    private(set) var lines: [String]

    init(_ text: String) {
        lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
    }

    var text: String { lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n" }

    /// A line's key and value, or nil for a blank line or comment; `invalid` lists the rest.
    private static func parse(_ raw: String) -> (key: String, value: String)?? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { return .some(nil) }
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !key.contains(where: \.isWhitespace) else { return nil }
        var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        // Quotes are optional, as in Ghostty, and keep surrounding spaces.
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
        return .some((key, value))
    }

    var entries: [Entry] {
        lines.enumerated().compactMap { i, line in
            guard case .some(.some(let pair)) = Self.parse(line) else { return nil }
            return Entry(line: i + 1, key: pair.key, value: pair.value)
        }
    }

    /// Line numbers that aren't `key = value`.
    var invalid: [Int] {
        lines.enumerated().compactMap { i, line in Self.parse(line) == nil ? i + 1 : nil }
    }

    /// Every value given for `key`, in order, after the last empty one.
    func all(_ key: String) -> [String] {
        var values: [String] = []
        for e in entries where e.key == key {
            if e.value.isEmpty { values.removeAll() } else { values.append(e.value) }
        }
        return values
    }

    func has(_ key: String) -> Bool { entries.contains { $0.key == key } }

    /// The line `key` is set on last, for reporting a bad value.
    func line(of key: String) -> Int? { entries.last { $0.key == key }?.line }

    /// Gives `key` these values: they take the place of its first line and its other lines go,
    /// so comments and other settings stay where they are. No values removes the key; an empty
    /// value writes `key =`, which clears it.
    mutating func set(_ key: String, _ values: [String]) {
        let new = values.filter { !$0.contains(where: \.isNewline) }.map { $0.isEmpty ? "\(key) =" : "\(key) = \(Self.quoted($0))" }
        let at = lines.indices.filter { if case .some(.some(let pair)) = Self.parse(lines[$0]) { pair.key == key } else { false } }
        guard let first = at.first else {
            lines += new
            return
        }
        for i in at.reversed() where i != first { lines.remove(at: i) }
        lines.replaceSubrange(first...first, with: new)
    }

    static func quoted(_ value: String) -> String {
        let padded = value != value.trimmingCharacters(in: .whitespaces)
        let wrapped = value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\"")
        return padded || wrapped ? "\"\(value)\"" : value
    }
}

/// A setting the config file holds for the app, kept in `Prefs.defaults` while tern runs.
struct ConfigSetting {
    enum Kind {
        case flag
        case choice([String])
        /// One value a line, like `repo-root`.
        case list
    }

    let key: String
    let pref: String
    let kind: Kind
}

/// tern's config file, `~/.config/tern/config`, is where its settings live. Settings writes to
/// it, an edit to the file applies as soon as it's saved, and a line tern can't use keeps the
/// last good value and is reported in Settings → General. ternd reads its own keys (`on-<event>`,
/// `notify-*`, `away-after`) from the same file.
///
/// The app still reads settings from `Prefs.defaults`: the store copies the file's values there
/// and writes changes made there back to the file, keeping the rest of the file as it is.
@Observable
final class ConfigStore {
    static let shared = ConfigStore(url: ConfigStore.defaultURL, defaults: Prefs.defaults, domain: Prefs.domain)

    /// The same path ternd uses: `$TERN_RUNTIME_DIR/config` for a private instance, else
    /// `$XDG_CONFIG_HOME/tern/config` or `~/.config/tern/config`.
    nonisolated static var defaultURL: URL {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["TERN_RUNTIME_DIR"] { return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("config") }
        let base = env["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
        return base.appendingPathComponent("tern/config")
    }

    static let settings: [ConfigSetting] = [
        ConfigSetting(key: "theme", pref: Prefs.theme, kind: .choice(Theme.builtIn.map(\.id) + ["ghostty"])),
        ConfigSetting(key: "working-indicator", pref: Prefs.workingIndicator, kind: .choice(["trailing", "turning"])),
        ConfigSetting(key: "folder-order", pref: Prefs.folderOrder, kind: .choice(["manual", "recent"])),
        ConfigSetting(key: "repo-root", pref: Prefs.repoRoots, kind: .list),
        ConfigSetting(key: "file-editor", pref: Prefs.fileEditor, kind: .choice(["system", "vscode", "cursor", "zed"])),
        ConfigSetting(key: "global-hotkey", pref: Prefs.globalHotkey, kind: .flag),
        ConfigSetting(key: "tab-worktrees", pref: Prefs.worktrees, kind: .flag),
        ConfigSetting(key: "notify-needs-you", pref: Prefs.notifyNeedsYou, kind: .flag),
        ConfigSetting(key: "notify-done", pref: Prefs.notifyDone, kind: .flag),
        ConfigSetting(key: "notify-command-done", pref: Prefs.notifyCommandDone, kind: .flag),
        ConfigSetting(key: "resume-agents", pref: Prefs.resumeAgents, kind: .flag),
        ConfigSetting(key: "claude-account-usage", pref: Prefs.claudeAccountUsage, kind: .flag),
        ConfigSetting(key: "check-app-updates", pref: Prefs.checkAppUpdates, kind: .flag),
        ConfigSetting(key: "download-app-updates", pref: Prefs.downloadAppUpdates, kind: .flag),
        ConfigSetting(key: "install-updates-on-quit", pref: Prefs.installAppUpdatesOnQuit, kind: .flag),
        ConfigSetting(key: "include-prereleases", pref: Prefs.includePrereleases, kind: .flag),
        ConfigSetting(key: "offer-agent-updates", pref: Prefs.offerAgentUpdates, kind: .flag),
    ]
    /// Read by ternd, so the app only checks they're spelt right.
    static let terndKeys = ["notify-ntfy", "notify-events", "away-after"]
        + ["needs-you", "working", "done", "failed", "command-done", "command-failed", "bell", "start", "exit"].map { "on-\($0)" }

    static let header = """
    # tern's settings. Settings writes here, and edits apply as soon as you save.
    # One `key = value` a line; the README lists every key.


    """

    let url: URL
    let defaults: UserDefaults
    let domain: String
    var presetsURL: URL { url.deletingLastPathComponent().appendingPathComponent("presets", isDirectory: true) }
    /// What's wrong with the file as it is, line by line.
    private(set) var problems: [String] = []
    @ObservationIgnored private(set) var config = ConfigText("")
    /// Each setting as last copied to or from the file, to tell the app's own changes apart.
    @ObservationIgnored private var applied: [String: [String]] = [:]
    @ObservationIgnored private var flushing = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var observers: [Any] = []
    @ObservationIgnored private var sources: [DispatchSourceFileSystemObject] = []

    init(url: URL, defaults: UserDefaults, domain: String) {
        self.url = url
        self.defaults = defaults
        self.domain = domain
    }

    /// Migrates once, reads the file, and follows it and the app's settings from then on.
    func start() {
        migrate()
        reload(force: true)
        started = true
        observers = [
            NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.defaultsChanged() }
            },
            // A fallback for an edit the watch misses, such as one made while the folder was gone.
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            },
        ]
        watch()
    }

    /// The file's path with symlinks resolved, so a config kept in a dotfiles repository stays linked.
    private var target: URL { url.resolvingSymlinksInPath() }

    /// Reads the file and applies it if it changed.
    func reload(force: Bool = false) {
        let text = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
        guard force || text != config.text else { return }
        config = ConfigText(text)
        apply()
    }

    /// Changes the file, as Settings does, and applies the result.
    func write(_ change: (inout ConfigText) -> Void) throws {
        var next = config
        change(&next)
        guard next != config else { return }
        try Self.writePrivate(Data(next.text.utf8), to: target)
        config = next
        apply()
    }

    // MARK: Applying the file

    private func apply() {
        var problems = config.invalid.map { "Line \($0) isn't a “key = value” setting." }
        let known = Set(Self.settings.map(\.key) + TerminalPreferences.configKeys + Self.terndKeys)
        for e in config.entries where !known.contains(e.key) {
            problems.append("Line \(e.line): tern has no setting called \(e.key).")
        }
        for s in Self.settings {
            switch Self.validate(s, config.all(s.key), given: config.has(s.key)) {
            case .success(let values):
                if current(s) != (values ?? registered(s)) { store(s, values) }
            case .failure(let problem):
                problems.append("Line \(config.line(of: s.key) ?? 0): \(problem.reason) Keeping the last good value.")
            }
            applied[s.key] = current(s)
        }
        TerminalPreferences.apply(config, check: started, problems: &problems)
        if problems != self.problems {
            for p in problems { NSLog("tern config: %@", p) }
            self.problems = problems
        }
    }

    /// The values to use, or nil for the default. A list given only as `key =` is empty.
    static func validate(_ s: ConfigSetting, _ values: [String], given: Bool) -> Result<[String]?, ConfigProblem> {
        if case .list = s.kind, given { return .success(values) }
        guard let last = values.last else { return .success(nil) }
        switch s.kind {
        case .flag:
            return ["true", "false"].contains(last) ? .success([last]) : .failure(ConfigProblem("\(s.key) is true or false, not \(last)."))
        case .choice(let options):
            return options.contains(last) ? .success([last])
                : .failure(ConfigProblem("\(s.key) is one of \(options.joined(separator: ", ")), not \(last)."))
        case .list:
            return .success(values)
        }
    }

    private func values(_ s: ConfigSetting, from read: (String) -> Any?) -> [String] {
        switch s.kind {
        case .flag: [(read(s.pref) as? Bool ?? false) ? "true" : "false"]
        case .choice: [read(s.pref) as? String ?? ""]
        case .list: Prefs.parseRoots(read(s.pref) as? String ?? "")
        }
    }

    private func current(_ s: ConfigSetting) -> [String] { values(s) { defaults.object(forKey: $0) } }

    private func registered(_ s: ConfigSetting) -> [String] {
        let domain = defaults.volatileDomain(forName: UserDefaults.registrationDomain)
        return values(s) { domain[$0] }
    }

    /// Nil goes back to the default.
    private func store(_ s: ConfigSetting, _ values: [String]?) {
        guard let values else { return defaults.removeObject(forKey: s.pref) }
        switch s.kind {
        case .flag: defaults.set(values[0] == "true", forKey: s.pref)
        case .choice: defaults.set(values[0], forKey: s.pref)
        case .list: defaults.set(Prefs.joinRoots(values), forKey: s.pref)
        }
    }

    // MARK: Writing the app's changes back

    private func defaultsChanged() {
        // Several changes in a row, like previewing themes, are written once.
        guard !flushing else { return }
        flushing = true
        DispatchQueue.main.async { [weak self] in
            self?.flushing = false
            self?.flush()
        }
    }

    /// Writes the settings changed in the app since they were last applied. A setting the file
    /// doesn't mention is added only when it's no longer the default.
    func flush() {
        var next = config
        for s in Self.settings {
            let now = current(s)
            guard now != applied[s.key] else { continue }
            applied[s.key] = now
            // An empty list is written `key =`, so it doesn't fall back to a default that isn't.
            if next.has(s.key) || now != registered(s) { next.set(s.key, now.isEmpty ? [""] : now) }
        }
        guard next != config else { return }
        do {
            try Self.writePrivate(Data(next.text.utf8), to: target)
            config = next
        } catch {
            NSLog("tern config: couldn't write %@: %@", url.path, error.localizedDescription)
        }
    }

    // MARK: Migration

    private var migratedKey: String { "configMigrated:" + url.path }

    /// Once per config path: settings changed in Settings before there was a file, the terminal
    /// settings and the launch presets move into it. The old files stay, for an older tern.
    func migrate(terminal: URL = TerminalPreferences.legacyURL, presets: URL = LaunchPresetFile.legacyURL) {
        guard !defaults.bool(forKey: migratedKey) else { return }
        let existing = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
        var next = ConfigText(existing.isEmpty ? Self.header : existing)
        let persisted = defaults.persistentDomain(forName: domain) ?? [:]
        for s in Self.settings where persisted[s.pref] != nil && !next.has(s.key) {
            next.set(s.key, current(s))
        }
        TerminalPreferences.migrate(from: terminal, into: &next)
        do {
            if next.text != existing { try Self.writePrivate(Data(next.text.utf8), to: target) }
            try LaunchPresetFile.migrate(from: presets, to: presetsURL)
            defaults.set(true, forKey: migratedKey)
        } catch {
            NSLog("tern config: couldn't migrate settings to %@: %@", url.path, error.localizedDescription)
        }
    }

    // MARK: Files

    /// Atomically, readable only by you: the file can hold an ntfy topic or a hook command.
    nonisolated static func writePrivate(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).tern-\(getpid())")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp.path])
        }
        guard rename(temp.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// Follows the file and its folder; editors save by replacing the file, so the watch on the
    /// file itself is set up again after each change.
    private func watch() {
        sources.forEach { $0.cancel() }
        sources = []
        let paths = Set([url.deletingLastPathComponent().path, target.deletingLastPathComponent().path, target.path])
        for path in paths {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.reload()
                    self?.watch()
                }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
        }
    }

    /// Opens the file in the default text editor, creating it first if needed.
    func openInEditor() {
        if !FileManager.default.fileExists(atPath: target.path) { try? Self.writePrivate(Data(Self.header.utf8), to: target) }
        if let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) {
            NSWorkspace.shared.open([target], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(target)
        }
    }
}

struct ConfigProblem: Error, Equatable {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}
