import AppKit
import SwiftUI

/// The strip above the panes: where this session is (folder › name, branch), then its state
/// in a capsule. What runs in each pane and where is on the pane's own header.
struct ContentHeader: View {
    let workspace: Workspace
    let layout: HeaderLayout
    @AppStorage(Prefs.workingIndicator, store: Prefs.defaults) private var indicator = WorkingIndicator.trailing
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 6) {
                if SecureKeyboard.shared.enabled { Image(systemName: "lock.fill").help("Secure Keyboard Entry is enabled").accessibilityLabel("Secure Keyboard Entry enabled") }
                if let tab = workspace.selectedTab {
                    let s = workspace.sessions[tab.focusedPane]
                    if let folder = workspace.project(containing: tab.id)?.name {
                        Text(folder).foregroundStyle(.tertiary).lineLimit(1)
                        Text("›").foregroundStyle(.tertiary).opacity(0.6)
                    }
                    Text(workspace.title(for: tab))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(workspace.hasPlaceholderTitle(tab) ? .secondary : .primary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let remote = workspace.remote(for: tab.focusedPane) {
                        HeaderChip(text: remote.host + ":" + remote.directory, symbol: "network")
                    } else if let branch = s?.branch {
                        HeaderChip(text: branch, symbol: "arrow.triangle.branch")
                    }
                    // How the last command ended, only when it says something: a failure, or a
                    // long run. Gone once the next command starts.
                    if let s, let outcome = CommandOutcome.shown(for: s) {
                        Text(outcome.text)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(outcome.failed ? Palette.failed : Color.secondary)
                            .help(outcome.detail)
                    }
                    Spacer(minLength: 12)
                    // Only what needs saying: an agent or a reporting program at work, waiting or
                    // failed, with how long. An idle shell says nothing; the sidebar already shows
                    // every tab's age. A failure stays here until you type in its pane.
                    let failing = tab.root.panes.lazy.compactMap { workspace.sessions[$0] }.first { $0.agentState == "failed" }
                    let reported = workspace.status(for: tab, now: context.date)
                    let status = reported != .needsYou && failing != nil ? SessionStatus.failed : reported
                    let agent = workspace.agent(for: tab)
                    let program = workspace.program(for: tab)
                    let urgent = status == .failed ? failing : workspace.urgentSession(tab, now: context.date)
                    if status == .needsYou || status == .failed, let message = workspace.agentMessage(tab) {
                        // What it's waiting for matters more here than the title, which the sidebar shows too.
                        Text([blockKindLabel(urgent?.agentKind), message].compactMap { $0 }.joined(separator: ": "))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 360, alignment: .trailing)
                            .layoutPriority(2)
                    }
                    if status == .needsYou || status == .failed || (status == .working && (agent ?? program) != nil) {
                        StatusCapsule(status: status, name: agent.map(agentName) ?? program, since: workspace.stateSince(tab),
                                      now: context.date, indicator: indicator,
                                      progress: urgent?.agentProgress, tasks: urgent?.statusRecords ?? 0, agent: agent, program: program)
                            .id(status)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.92).combined(with: .opacity))
                    }
                } else {
                    Spacer()
                }
            }
            .animation(Motion.animation(), value: workspace.selectedTab.map { workspace.status(for: $0, now: context.date) })
            .font(.system(size: 12.5))
            .padding(.leading, 10 + layout.leadingInset)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .themedText()
        }
    }
}

/// The branch (or remote host) beside the title.
private struct HeaderChip: View {
    let text: String
    let symbol: String

    var body: some View {
        Label {
            Text(text).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: symbol).font(.system(size: 9.5, weight: .medium))
        }
        .labelStyle(ChipLabelStyle())
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Palette.chip, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct ChipLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon; configuration.title }
    }
}

/// What a blocked program needs, as the header names it before its message.
private func blockKindLabel(_ kind: String?) -> String? {
    switch kind {
    case "permission": "Permission"
    case "question": "Question"
    case "auth": "Sign-in"
    default: nil
    }
}

/// "Codex working · 4m" with the sidebar's glyph: amber-tinted when it needs you, red-tinted when
/// it failed, a quiet chip while it works. A program that reports progress or several tasks adds
/// "40%" or "3 tasks".
private struct StatusCapsule: View {
    let status: SessionStatus
    let name: String?
    let since: Date?
    let now: Date
    let indicator: WorkingIndicator
    var progress: Int?
    var tasks = 0
    var agent: String?
    var program: String?

    var body: some View {
        let tint: Color? = status == .needsYou ? Palette.amber : status == .failed ? Palette.failed : nil
        let label = name.map { "\($0) \(status.label.lowercased())" } ?? status.label
        let facts = [label, progress.map { "\($0)%" } ?? "", tasks > 1 ? "\(tasks) tasks" : "", relativeAge(since, now: now)]
        HStack(spacing: 7) {
            StatusIcon(status: status, agent: agent, program: program, turning: indicator == .turning)
            Text(facts.filter { !$0.isEmpty && $0 != "now" }.joined(separator: " · "))
                .font(.system(size: 11.5, weight: tint != nil ? .medium : .regular).monospacedDigit())
                .foregroundStyle(tint ?? Palette.text2)
                .lineLimit(1)
            if status == .working, let progress {
                ProgressRing(progress: progress, color: Palette.working).frame(width: 12, height: 12)
            } else if status == .working, indicator == .trailing {
                Spinner(color: Palette.working).frame(width: 12, height: 12)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: 24)
        .background(tint.map { $0.opacity(0.16) } ?? Palette.chip, in: Capsule())
        .fixedSize()
    }
}

/// How a shell command ended, in plain words: "Command not found", "Done in 2m 14s".
nonisolated struct CommandOutcome: Equatable {
    let text: String
    let failed: Bool
    /// "Exit code 1 · 2.3s", for a tooltip.
    let detail: String

    /// What the header says about a session's last command. Nothing while an agent or the next
    /// command runs, including a builtin like `read`, which leaves the shell in front.
    @MainActor static func shown(for s: SessionInfo) -> CommandOutcome? {
        guard s.agent == nil, s.commandRunning != true, Workspace.shells.contains(s.process) else { return nil }
        return CommandOutcome(exitCode: s.exitCode, durationMs: s.durationMs)
    }

    /// Nil when there's nothing worth saying: a quick success, or a command you stopped with ⌃C.
    init?(exitCode: Int?, durationMs: UInt64?) {
        guard let code = exitCode, code != 130 else { return nil }
        let took = durationMs.map(Self.duration)
        detail = "Exit code \(code)" + (took.map { " · " + $0 } ?? "")
        failed = code != 0
        switch code {
        case 0:
            guard let durationMs, durationMs >= 10_000, let took else { return nil }
            text = "Done in " + took
        case 126: text = "Not executable"
        case 127: text = "Command not found"
        case 137: text = "Killed"
        case 143: text = "Terminated"
        default: text = "Failed"
        }
    }

    /// "0.4s", "12s", "2m 14s", "1h 5m".
    static func duration(_ ms: UInt64) -> String {
        let s = ms / 1000
        if s < 10 { return String(format: "%.1fs", Double(ms) / 1000) }
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }
}

/// Window geometry the SwiftUI parts follow.
@Observable
final class HeaderLayout {
    /// Room the header leaves on its left for the traffic lights when the sidebar is hidden.
    var leadingInset: CGFloat = 0
    /// The titlebar's height, which the sidebar starts below (zero in full screen).
    var titlebarHeight: CGFloat = 38
}

/// Lets the header act as titlebar: drag moves the window, double-click zooms.
final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.performZoom(nil)
        } else {
            window?.performDrag(with: event)
        }
    }
}
