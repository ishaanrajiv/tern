import AppKit
import Foundation

/// The four things tern keeps up to date, in the order the sidebar card lists them
/// when nothing more urgent is going on.
nonisolated enum UpdateSource: String, CaseIterable, Sendable {
    case app, daemon, claude, codex

    var name: String {
        switch self {
        case .app: "tern"
        case .daemon: "ternd"
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// What a button on an update row does.
nonisolated enum UpdateAction: Equatable, Sendable {
    case downloadApp, installApp
    case restartDaemon, restartDaemonWhenIdle, restartDaemonNow, cancelIdleRestart
    case runAgent(String), showOutput(String), closeRun(String)

    var label: String {
        switch self {
        case .downloadApp: "Download"
        case .installApp: "Restart to Update"
        case .restartDaemon: "Restart"
        case .restartDaemonWhenIdle: "When Idle"
        case .restartDaemonNow: "Restart Now"
        case .cancelIdleRestart: "Cancel"
        case .runAgent: "Update"
        case .showOutput: "Show Output"
        case .closeRun: "Dismiss"
        }
    }
}

/// One row of the sidebar's update card.
nonisolated struct UpdateEntry: Identifiable, Equatable, Sendable {
    enum Tone: Equatable, Sendable { case normal, warning, progress, success, failure }

    let source: UpdateSource
    let title: String
    var detail: String? = nil
    var tone: Tone = .normal
    var actions: [UpdateAction] = []
    /// The version a row offers; set for rows that Remind Me Tomorrow and Skip can hide.
    var version: String? = nil

    var id: String { source.rawValue }

    /// Urgent rows first, then rows for something already under way, then offers.
    var rank: Int {
        switch tone {
        case .warning: 0
        case .progress, .failure, .success: 1
        case .normal: 2
        }
    }

    static func sorted(_ entries: [UpdateEntry]) -> [UpdateEntry] {
        let order = Dictionary(uniqueKeysWithValues: UpdateSource.allCases.enumerated().map { ($1, $0) })
        return entries.sorted { ($0.rank, order[$0.source]!) < ($1.rank, order[$1.source]!) }
    }
}

/// Remind Me Tomorrow and Skip This Version, per source and version.
nonisolated struct UpdateDismissals {
    static let snoozeLength: TimeInterval = 24 * 3600
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func skip(_ source: UpdateSource, version: String) {
        defaults.set(version, forKey: "updateSkipped." + source.rawValue)
    }

    func snooze(_ source: UpdateSource, version: String, now: Date = Date()) {
        defaults.set(["version": version, "until": now.addingTimeInterval(Self.snoozeLength).timeIntervalSince1970],
                     forKey: "updateSnoozed." + source.rawValue)
    }

    func isHidden(_ source: UpdateSource, version: String, now: Date = Date()) -> Bool {
        if defaults.string(forKey: "updateSkipped." + source.rawValue) == version { return true }
        // Older builds' Not Now meant skip this version.
        if defaults.string(forKey: "dismissedAgentUpdate." + source.rawValue) == version { return true }
        guard let snoozed = defaults.dictionary(forKey: "updateSnoozed." + source.rawValue),
              snoozed["version"] as? String == version, let until = snoozed["until"] as? Double else { return false }
        return now.timeIntervalSince1970 < until
    }

    func reset(_ source: UpdateSource) {
        for key in ["updateSkipped.", "updateSnoozed.", "dismissedAgentUpdate."] { defaults.removeObject(forKey: key + source.rawValue) }
    }
}

/// The programs a ternd restart would end: every session not sitting at a shell prompt.
nonisolated enum BusySessions {
    static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "login"]

    /// `updating` holds the updater sessions still running. `holdsTerminal` says whether a
    /// session's own shell is in the foreground; a session counts as idle only when it does
    /// and the foreground is a shell, so `bash long-script.sh` counts as busy.
    static func programs(in sessions: [SessionInfo], updating: Set<String> = [],
                         holdsTerminal: (SessionInfo) -> Bool = shellHoldsTerminal) -> [String] {
        sessions.compactMap { s -> String? in
            if UpdateRunner.isRunSession(s.id) {
                guard updating.contains(s.id) else { return nil }
                return "the \(UpdateRunner.agent(ofRun: s.id).flatMap(UpdateSource.init(rawValue:))?.name ?? "agent") update"
            }
            if let agent = s.agent { return agent == "claude" ? "Claude Code" : agent == "codex" ? "Codex" : agent }
            let process = s.process.hasPrefix("-") ? String(s.process.dropFirst()) : s.process
            if shells.contains(process), holdsTerminal(s) { return nil }
            return s.command.flatMap { $0.isEmpty ? nil : $0 } ?? (process.isEmpty ? "a program" : process)
        }
    }

    /// Whether the session's process group owns its terminal, so nothing it started is in the
    /// foreground. False when the process can't be read.
    static func shellHoldsTerminal(_ session: SessionInfo) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, session.pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return false }
        let foreground = info.kp_eproc.e_tpgid
        return foreground > 0 && foreground == info.kp_eproc.e_pgid
    }

    /// "npm run dev, Claude Code and 2 more"
    static func summary(_ programs: [String], limit: Int = 2) -> String {
        guard programs.count > limit else { return programs.formatted(.list(type: .and)) }
        return programs.prefix(limit).joined(separator: ", ") + " and \(programs.count - limit) more"
    }
}

/// Everything the update card and Settings › Updates show, from four sources.
@Observable
final class UpdateCenter {
    let app = AppUpdates()
    let agents = AgentUpdates()
    let runner: UpdateRunner
    private(set) var daemon: DaemonStatus?
    private(set) var busy: [String] = []
    private(set) var restartWhenIdle = false
    private(set) var restartingDaemon = false
    /// Bumped when a row is hidden, so the card re-reads the dismissals.
    private var dismissals = 0
    @ObservationIgnored private let ternBinary: String
    /// Asks before a restart that ends running programs; set by the app delegate.
    @ObservationIgnored var confirmRestart: ((@escaping () -> Void) -> Void)?
    /// Shown when a restart fails.
    @ObservationIgnored var onError: ((String, String) -> Void)?
    @ObservationIgnored var openSettings: (() -> Void)?

    init(ternBinary: String) {
        self.ternBinary = ternBinary
        runner = UpdateRunner(ternBinary: ternBinary)
        let agents = self.agents, runner = self.runner
        runner.onFinish = { _, succeeded in if succeeded { agents.check() } }
        runner.stillBehind = { agents.versions[$0]?.behind == true }
        agents.onChecked = { runner.verified() }
    }

    func start() {
        app.start()
        agents.start()
        checkDaemon()
    }

    /// Check Now in Settings and the tern menu's Check for Updates.
    func checkAll() {
        app.check(interactive: true)
        agents.check()
        checkDaemon()
    }

    // MARK: Card

    var entries: [UpdateEntry] {
        _ = dismissals
        let hidden = UpdateDismissals()
        var rows: [UpdateEntry] = []
        if let row = appEntry, row.version.map({ !hidden.isHidden(.app, version: $0) }) ?? true { rows.append(row) }
        if let row = daemonEntry, row.version.map({ !hidden.isHidden(.daemon, version: $0) }) ?? true { rows.append(row) }
        for agent in ["claude", "codex"] {
            guard let row = agentEntry(agent) else { continue }
            if let version = row.version, hidden.isHidden(UpdateSource(rawValue: agent)!, version: version) { continue }
            rows.append(row)
        }
        return UpdateEntry.sorted(rows)
    }

    private var appEntry: UpdateEntry? {
        let tag = app.release?.tag_name ?? ""
        let current = AppUpdates.currentVersion
        switch app.phase {
        case .idle, .checking:
            guard app.release != nil else { return nil }
            return UpdateEntry(source: .app, title: "tern \(tag) is available", detail: "You have \(current).",
                               actions: [.downloadApp], version: tag)
        case .downloading(let interactive):
            // A background download stays out of sight until it's ready.
            guard interactive else { return nil }
            return UpdateEntry(source: .app, title: "Downloading tern \(tag)…", tone: .progress)
        case .ready:
            let installs = UserDefaults.standard.bool(forKey: Prefs.installAppUpdatesOnQuit)
            return UpdateEntry(source: .app, title: "tern \(tag) is ready",
                               detail: installs ? "Installs when you quit. Sessions keep running." : "Sessions keep running across the restart.",
                               actions: [.installApp], version: tag)
        case .installing:
            return UpdateEntry(source: .app, title: "Installing tern \(tag)…", tone: .progress)
        case .failed(let message, let interactive):
            if interactive {
                return UpdateEntry(source: .app, title: "tern couldn't update", detail: message, tone: .failure,
                                   actions: app.release == nil ? [] : [.downloadApp])
            }
            // A background failure falls back to an ordinary offer, with the reason.
            guard app.release != nil else { return nil }
            return UpdateEntry(source: .app, title: "tern \(tag) is available", detail: message,
                               actions: [.downloadApp], version: tag)
        }
    }

    private var daemonEntry: UpdateEntry? {
        if restartingDaemon { return UpdateEntry(source: .daemon, title: "Restarting ternd…", tone: .progress) }
        guard let daemon, daemon.running, !daemon.current else { return nil }
        let cost = busy.isEmpty ? "Nothing is running, so nothing ends."
            : "Ends \(busy.count == 1 ? "1 running program" : "\(busy.count) running programs"): \(BusySessions.summary(busy))."
        if restartWhenIdle {
            return UpdateEntry(source: .daemon, title: "ternd restarts when idle",
                               detail: "Waiting for \(BusySessions.summary(busy)).", tone: .progress,
                               actions: [.restartDaemonNow, .cancelIdleRestart])
        }
        let actions: [UpdateAction] = busy.isEmpty ? [.restartDaemon] : [.restartDaemon, .restartDaemonWhenIdle]
        if !daemon.compatible {
            return UpdateEntry(source: .daemon, title: "ternd needs a restart",
                               detail: "It's from an older tern and may misread this one. " + cost, tone: .warning, actions: actions)
        }
        return UpdateEntry(source: .daemon, title: "Restart ternd to finish updating", detail: cost,
                           actions: actions, version: daemon.version ?? "")
    }

    private func agentEntry(_ agent: String) -> UpdateEntry? {
        let source = UpdateSource(rawValue: agent)!
        let name = source.name
        if let run = runner.runs[agent] {
            switch run.phase {
            case .running:
                return UpdateEntry(source: source, title: "Updating \(name)…",
                                   detail: run.waiting ? "It may be waiting for you." : nil,
                                   tone: run.waiting ? .warning : .progress, actions: [.showOutput(agent)])
            case .failed(let reason):
                return UpdateEntry(source: source, title: "\(name) didn't update", detail: reason, tone: .failure,
                                   actions: run.attached ? [.showOutput(agent), .closeRun(agent)] : [.runAgent(agent), .closeRun(agent)])
            case .succeeded where !run.verified:
                return UpdateEntry(source: source, title: "Checking \(name)…", tone: .progress)
            case .succeeded:
                // Done when the version check agrees; otherwise another copy may come first on PATH.
                guard let version = agents.versions[agent], version.behind else {
                    let installed = agents.versions[agent]?.installed.map { " \($0)" } ?? ""
                    return UpdateEntry(source: source, title: "\(name) updated to\(installed)", tone: .success)
                }
                return UpdateEntry(source: source, title: "\(name) is still \(version.installed ?? "out of date")",
                                   detail: version.shadowWarning ?? "The updater finished, but the version didn't change.",
                                   tone: .failure, actions: [.runAgent(agent), .closeRun(agent)])
            }
        }
        guard UserDefaults.standard.bool(forKey: Prefs.offerAgentUpdates),
              let version = agents.versions[agent], version.behind, let latest = version.latest else { return nil }
        return UpdateEntry(source: source, title: "\(name) \(latest) is available",
                           detail: ["You have \(version.installed ?? "an older version").", version.shadowWarning].compactMap { $0 }.joined(separator: " "),
                           actions: [.runAgent(agent)], version: latest)
    }

    // MARK: Actions

    func perform(_ action: UpdateAction) {
        switch action {
        case .downloadApp: app.download(interactive: true)
        case .installApp: app.install(relaunch: true)
        case .restartDaemon, .restartDaemonNow: requestDaemonRestart()
        case .restartDaemonWhenIdle: restartWhenIdle = true; restartIfIdle()
        case .cancelIdleRestart: restartWhenIdle = false
        case .runAgent(let agent): runAgent(agent)
        case .showOutput(let agent): runner.show(agent)
        case .closeRun(let agent): runner.close(agent)
        }
    }

    func runAgent(_ agent: String) {
        let version = agents.versions[agent] ?? AgentUpdates.Version(agent: agent)
        runner.start(agent: agent, command: version.updateCommand)
    }

    func remindTomorrow(_ entry: UpdateEntry) {
        guard let version = entry.version else { return }
        UpdateDismissals().snooze(entry.source, version: version)
        dismissals += 1
    }

    func skip(_ entry: UpdateEntry) {
        guard let version = entry.version else { return }
        UpdateDismissals().skip(entry.source, version: version)
        dismissals += 1
    }

    // MARK: ternd

    func checkDaemon(then: ((DaemonStatus) -> Void)? = nil) {
        let tern = ternBinary
        Task {
            guard let status = await Task.detached(priority: .utility, operation: { DaemonStatus.run("status", tern: tern) }).value else { return }
            daemon = status
            if status.current { restartWhenIdle = false }
            then?(status)
        }
    }

    /// The app delegate's session stream: what a restart would end, and the idle restart.
    func update(sessions: [SessionInfo]) {
        runner.update(sessions: sessions)
        // A restart mid-install would leave the agent half updated.
        let programs = BusySessions.programs(in: sessions, updating: runner.runningIDs)
        if programs != busy { busy = programs }
        restartIfIdle()
    }

    private func restartIfIdle() {
        guard restartWhenIdle, busy.isEmpty, !restartingDaemon else { return }
        restartWhenIdle = false
        restartDaemonNow()
    }

    /// Asks first when programs are running: the restart ends them.
    func requestDaemonRestart() {
        guard !busy.isEmpty, let confirmRestart else { return restartDaemonNow() }
        confirmRestart { [weak self] in self?.restartDaemonNow() }
    }

    func restartDaemonNow() {
        guard !restartingDaemon else { return }
        restartingDaemon = true
        let tern = ternBinary
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status = DaemonStatus.run("restart", tern: tern)
            DispatchQueue.main.async {
                guard let self else { return }
                self.restartingDaemon = false
                // Panes reconnect on their own once the new daemon is up.
                if status?.running != true { self.onError?("Couldn't restart ternd", "See ~/Library/Application Support/tern/ternd.log.") }
                self.checkDaemon()
            }
        }
    }
}
