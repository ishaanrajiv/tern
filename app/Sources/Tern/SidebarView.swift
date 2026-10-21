import SwiftUI

struct SidebarActions {
    var newSessionInProject: (String) -> Void
    var setUpHooks: () -> Void
    var rename: (String) -> Void
    var close: (String) -> Void
}

/// One line per session: name, age of last activity, status. Projects group
/// them, and say how many need you.
struct SidebarView: View {
    @Bindable var workspace: Workspace
    let hooks: AgentHooks
    let actions: SidebarActions
    @AppStorage(Prefs.hooksPromptDismissed) private var hooksPromptDismissed = false

    var body: some View {
        // Status depends on how long a session has been quiet, so re-evaluate every second.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            List(selection: Binding(
                get: { workspace.selectedTabID },
                set: { if let id = $0 { workspace.select(id) } }
            )) {
                ForEach(workspace.projects) { project in
                    Section(isExpanded: Binding(
                        get: { !project.collapsed },
                        set: { workspace.setCollapsed(project.path, !$0) }
                    )) {
                        ForEach(project.tabs) { tab in
                            TabRow(workspace: workspace, tab: tab, now: context.date)
                                .tag(tab.id)
                                .contextMenu {
                                    Button("Rename…") { actions.rename(tab.id) }
                                    Button("Close") { actions.close(tab.id) }
                                }
                        }
                    } header: {
                        ProjectHeader(workspace: workspace, project: project, now: context.date)
                            .contextMenu {
                                Button("New Session Here") { actions.newSessionInProject(project.path) }
                            }
                    }
                }
            }
            .listStyle(.sidebar)
            .environment(\.sidebarRowSize, .small)
            // One dark surface with the terminal, as in harp, instead of the system's grey material.
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: GhosttyApp.shared.chrome).ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                if hooks.anyMissing && !hooksPromptDismissed {
                    HooksPrompt(setUp: actions.setUpHooks, dismiss: { hooksPromptDismissed = true })
                }
            }
        }
    }
}

/// Without hooks tern guesses agent state from output; this offers the real thing once.
private struct HooksPrompt: View {
    let setUp: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(Palette.amber)
            VStack(alignment: .leading, spacing: 4) {
                Text("See when Claude Code or Codex needs you")
                    .font(.system(size: 11, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Set Up…", action: setUp)
                    Button("Not Now", action: dismiss).foregroundStyle(.secondary)
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(8)
    }
}

private struct ProjectHeader: View {
    let workspace: Workspace
    let project: Project
    let now: Date

    var body: some View {
        let waiting = project.tabs.filter { workspace.status(for: $0, now: now) == .needsYou }.count
        HStack(spacing: 5) {
            Text(project.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(project.tabs.count)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer()
            if waiting > 0 {
                Text("\(waiting) needs you")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.amber)
            }
        }
        // Line up with the rows' trailing edge, clear of the section's collapse chevron.
        .padding(.trailing, 14)
        .help(project.path)
    }
}

private struct TabRow: View {
    let workspace: Workspace
    let tab: Tab
    let now: Date

    var body: some View {
        let status = workspace.status(for: tab, now: now)
        let emphasized = status == .needsYou || status == .doneUnread
        HStack(spacing: 6) {
            Text(workspace.title(for: tab))
                .font(.system(size: 13, weight: emphasized ? .semibold : .regular))
                .foregroundStyle(status == .dormant ? .secondary : .primary)
                .lineLimit(1)
            if tab.root.panes.count > 1 {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .help("\(tab.root.panes.count) panes")
            }
            Spacer(minLength: 6)
            Text(relativeAge(workspace.lastActivity(tab), now: now))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            StatusIcon(status: status)
        }
        .help(helpText)
    }

    private var helpText: String {
        let s = workspace.sessions[tab.focusedPane]
        let facts = [s?.process, s?.cwd.map(abbreviateHome), s?.branch].compactMap { $0 }.joined(separator: " · ")
        return [workspace.agentMessage(tab), facts].compactMap { $0 }.joined(separator: "\n")
    }
}

struct StatusIcon: View {
    let status: SessionStatus

    var body: some View {
        Group {
            switch status {
            case .working, .starting:
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.8)
            case .needsYou:
                Image(systemName: "smallcircle.filled.circle")
                    .foregroundStyle(Palette.amber)
            case .doneUnread:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.primary)
            case .idle:
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            case .dormant:
                Image(systemName: "moon.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12))
        .frame(width: 14, height: 14)
    }
}

enum Palette {
    static let amber = Color(red: 0.96, green: 0.72, blue: 0.24)
}

func abbreviateHome(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}
