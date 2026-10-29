import AppKit

/// Runs Claude Code's or Codex's updater in a ternd session that no tab owns. The session's
/// terminal waits in a hidden panel: Show Output brings it up, a prompt or a failure brings it
/// up on its own, and a successful run closes it. The session's id starts with `update-`, so
/// windows never adopt it as an orphan tab.
@Observable
final class UpdateRunner {
    struct Run: Equatable {
        enum Phase: Equatable { case running, succeeded, failed(String) }
        let id: String
        let agent: String
        let command: String
        var phase = Phase.running
        /// Quiet, with a question on screen: probably waiting for the user.
        var waiting = false
        /// The session still holds its terminal (a failed run waits for Return).
        var attached = true
        /// The version check after a successful run has finished.
        var verified = false
    }

    nonisolated static let prefix = "update-"
    nonisolated static func isRunSession(_ id: String) -> Bool { id.hasPrefix(prefix) }

    /// "codex" for `update-codex-1a2b3c4d`.
    nonisolated static func agent(ofRun id: String) -> String? {
        guard isRunSession(id) else { return nil }
        return id.dropFirst(prefix.count).split(separator: "-").first.map(String.init)
    }

    private(set) var runs: [String: Run] = [:]
    /// The sessions of updaters still running.
    var runningIDs: Set<String> { Set(runs.values.filter { $0.phase == .running }.map(\.id)) }
    /// Called when an updater exits: the agent, and whether it succeeded.
    @ObservationIgnored var onFinish: ((String, Bool) -> Void)?
    @ObservationIgnored private let ternBinary: String
    @ObservationIgnored private var consoles: [String: UpdateConsole] = [:]
    @ObservationIgnored private var lastOutput: [String: UInt64] = [:]
    @ObservationIgnored private var asked: [String: Date] = [:]
    @ObservationIgnored private var timer: Timer?
    /// Runs closed here, whose sessions may still be listed for a moment.
    @ObservationIgnored private var closed: Set<String> = []
    @ObservationIgnored private var swept = false

    init(ternBinary: String) { self.ternBinary = ternBinary }

    nonisolated static var statusDirectory: URL {
        Workspace.layoutURL.deletingLastPathComponent().appendingPathComponent("update-runs")
    }

    nonisolated static func statusFile(_ id: String) -> URL { statusDirectory.appendingPathComponent(id + ".status") }
    /// The updater's command line, so a relaunched tern can name the run it finds.
    nonisolated static func commandFile(_ id: String) -> URL { statusDirectory.appendingPathComponent(id + ".command") }

    /// The session's command: the updater in the user's login shell, then its exit code in
    /// `status`. A failed run keeps its terminal until Return, so the error stays readable.
    nonisolated static func script(command: String, shell: String, status: String) -> String {
        "\(quoteShell(shell)) -lic \(quoteShell(command)); code=$?; printf %s \"$code\" > \(quoteShell(status)); "
            + "if [ \"$code\" -ne 0 ]; then printf '\\r\\n[tern] %s exited with %s. Press Return to close.\\r\\n' \(quoteShell(command)) \"$code\"; "
            + "read -r -t 3600 _; fi; exit \"$code\""
    }

    /// The end of the screen looks like a question: a password, a yes/no, a choice.
    nonisolated static func looksLikePrompt(_ text: String) -> Bool {
        guard let last = text.split(whereSeparator: \.isNewline).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return false }
        let line = last.trimmingCharacters(in: .whitespaces).lowercased()
        let marks = ["[y/n]", "(y/n)", "[y/n]:", "yes/no", "password", "passphrase", "press enter", "press return", "continue?", "proceed?"]
        if marks.contains(where: line.contains) { return true }
        return line.hasSuffix("?") || line.hasSuffix(":") || line.hasSuffix("›") || line.hasSuffix(">")
    }

    func start(agent: String, command: String) {
        if let run = runs[agent], run.phase == .running { return show(agent) }
        close(agent)
        let id = Self.prefix + agent + "-" + UUID().uuidString.prefix(8).lowercased()
        let status = Self.statusFile(id)
        try? FileManager.default.createDirectory(at: Self.statusDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.removeItem(at: status)
        try? command.write(to: Self.commandFile(id), atomically: true, encoding: .utf8)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        open(Run(id: id, agent: agent, command: command), command: Self.script(command: command, shell: shell, status: status.path))
    }

    /// Attaches a console to the run's session, creating the session with `command` if needed.
    private func open(_ run: Run, command: String) {
        let agent = run.agent, id = run.id
        let terminal = TerminalView(sessionID: id, ternBinary: ternBinary, cwd: NSHomeDirectory(), command: command)
        terminal.onClose = { [weak self] in self?.attachEnded(agent, id: id) }
        let console = UpdateConsole(title: "Updating \(UpdateSource(rawValue: agent)?.name ?? agent)", terminal: terminal)
        console.onCloseRequest = { [weak self] in self?.closeRequested(agent) }
        consoles[agent] = console
        runs[agent] = run
        startTimer()
    }

    /// An updater tern quit during: ternd kept it, so this launch picks it up again.
    private func adopt(_ id: String) {
        guard let agent = Self.agent(ofRun: id), runs[agent] == nil, !closed.contains(id) else { return }
        let command = (try? String(contentsOf: Self.commandFile(id), encoding: .utf8))
            ?? (agent == "claude" ? "claude update" : "\(agent) update")
        // `true` only runs if the session ended since it was listed; attaching then ends the run.
        open(Run(id: id, agent: agent, command: command), command: "true")
        if let code = Self.exitCode(id) {
            // It finished while tern was closed; a failure still waits for Return.
            finish(agent, code: code)
        }
    }

    private func startTimer() {
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }

    func show(_ agent: String) { consoles[agent]?.show() }

    /// Dismiss: ends a session still waiting, and forgets the run.
    func close(_ agent: String) {
        guard let run = runs.removeValue(forKey: agent) else { return }
        if run.attached { TernClient.kill(run.id) }
        consoles.removeValue(forKey: agent)?.dispose()
        lastOutput[run.id] = nil; asked[run.id] = nil
        closed.insert(run.id)
        try? FileManager.default.removeItem(at: Self.statusFile(run.id))
        try? FileManager.default.removeItem(at: Self.commandFile(run.id))
        stopTimerIfIdle()
    }

    /// The version check after a successful run ended; a success that checks out fades soon after.
    func verified() {
        for (agent, run) in runs where run.phase == .succeeded && !run.verified {
            runs[agent]?.verified = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self, self.runs[agent]?.id == run.id, self.runs[agent]?.phase == .succeeded,
                      self.stillBehind?(agent) != true else { return }
                self.close(agent)
            }
        }
    }

    /// Whether the agent's version is still behind after its run; set by the update center.
    @ObservationIgnored var stillBehind: ((String) -> Bool)?

    func update(sessions: [SessionInfo]) {
        for s in sessions where Self.isRunSession(s.id) {
            lastOutput[s.id] = s.lastOutputMs
            if !runs.values.contains(where: { $0.id == s.id }) { adopt(s.id) }
        }
        if !swept { swept = true; sweep(keeping: Set(sessions.map(\.id) + runs.values.map(\.id))) }
    }

    /// Files left by runs whose sessions ended while tern was closed.
    private func sweep(keeping live: Set<String>) {
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: Self.statusDirectory, includingPropertiesForKeys: nil)) ?? [] {
            if !live.contains(url.deletingPathExtension().lastPathComponent) { try? fm.removeItem(at: url) }
        }
    }

    private func closeRequested(_ agent: String) {
        // Closing the panel of a running update only hides it; the update carries on.
        if runs[agent]?.phase == .running { consoles[agent]?.hide() } else { close(agent) }
    }

    private func tick() {
        for (agent, run) in runs where run.phase == .running {
            if let code = Self.exitCode(run.id) { finish(agent, code: code); continue }
            watchForPrompt(agent, run)
        }
    }

    private func watchForPrompt(_ agent: String, _ run: Run) {
        let now = Date()
        let quiet = lastOutput[run.id].map { now.timeIntervalSince1970 * 1000 - Double($0) } ?? 0
        if quiet < 4000 {
            if run.waiting { runs[agent]?.waiting = false }
            return
        }
        guard !run.waiting, now.timeIntervalSince(asked[run.id] ?? .distantPast) > 3 else { return }
        asked[run.id] = now
        let id = run.id
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let waiting = TernClient.output(id).flatMap(\.text).map(UpdateRunner.looksLikePrompt) ?? false
            DispatchQueue.main.async {
                guard let self, waiting, self.runs[agent]?.id == id, self.runs[agent]?.phase == .running else { return }
                self.runs[agent]?.waiting = true
                self.consoles[agent]?.show()
            }
        }
    }

    nonisolated private static func exitCode(_ id: String) -> Int32? {
        guard let text = try? String(contentsOf: statusFile(id), encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func finish(_ agent: String, code: Int32) {
        guard let run = runs[agent] else { return }
        try? FileManager.default.removeItem(at: Self.statusFile(run.id))
        runs[agent]?.waiting = false
        if code == 0 {
            runs[agent]?.phase = .succeeded
            runs[agent]?.attached = false
            // A visible panel stays up a moment, so a glance at it reads as success.
            let console = consoles.removeValue(forKey: agent)
            DispatchQueue.main.asyncAfter(deadline: .now() + (console?.isVisible == true ? 1.2 : 0)) { console?.dispose() }
        } else {
            runs[agent]?.phase = .failed("`\(run.command)` exited with \(code).")
            consoles[agent]?.show()
        }
        stopTimerIfIdle()
        onFinish?(agent, code == 0)
    }

    /// `tern attach` ended: the session is gone.
    private func attachEnded(_ agent: String, id: String) {
        guard let run = runs[agent], run.id == id else { return }
        runs[agent]?.attached = false
        switch run.phase {
        case .running:
            if let code = Self.exitCode(id) { return finish(agent, code: code) }
            runs[agent]?.phase = .failed("The update stopped before it finished.")
            consoles.removeValue(forKey: agent)?.dispose()
            stopTimerIfIdle()
            onFinish?(agent, false)
        case .failed:
            // Return pressed after a failure: the row stays, offering to try again.
            consoles.removeValue(forKey: agent)?.dispose()
        case .succeeded:
            break
        }
    }

    private func stopTimerIfIdle() {
        guard !runs.values.contains(where: { $0.phase == .running }) else { return }
        timer?.invalidate(); timer = nil
    }
}

/// The panel an update's terminal lives in, hidden until it's worth seeing.
final class UpdateConsole: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let terminal: TerminalView
    var onCloseRequest: (() -> Void)?

    init(title: String, terminal: TerminalView) {
        self.terminal = terminal
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 300),
                        styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        panel.title = title
        panel.identifier = NSUserInterfaceItemIdentifier("tern.update")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.titlebarAppearsTransparent = true
        panel.minSize = NSSize(width: 420, height: 180)
        panel.backgroundColor = ThemeStore.shared.theme.terminal
        panel.delegate = self
        let content = NSView()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            terminal.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            terminal.topAnchor.constraint(equalTo: content.topAnchor, constant: 30),
            terminal.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
        panel.contentView = content
        panel.layoutIfNeeded()
    }

    var isVisible: Bool { panel.isVisible }

    /// Low over the window in front, where the sidebar card that opened it is.
    func show() {
        if !panel.isVisible, let main = NSApp.mainWindow ?? NSApp.keyWindow, main !== panel {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: main.frame.midX - size.width / 2, y: main.frame.minY + 48))
        }
        panel.backgroundColor = ThemeStore.shared.theme.terminal
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(terminal)
    }

    func hide() { panel.orderOut(nil) }

    /// Hangs up the terminal and closes the panel; the session is the runner's business.
    func dispose() {
        terminal.onClose = nil
        terminal.detach()
        panel.delegate = nil
        panel.orderOut(nil)
        panel.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onCloseRequest?()
        return false
    }
}
