import SwiftUI

struct SidebarActions {
    var newTab: (String) -> Void
    var newWorktreeTab: (String) -> Void
    var closeFolder: (String) -> Void
    var setUpHooks: () -> Void
    var rename: (String) -> Void
    var close: (String) -> Void
}

/// A header per folder, its tabs under it: status, name, agent, age.
struct SidebarView: View {
    @Bindable var workspace: Workspace
    let hooks: AgentHooks
    let actions: SidebarActions
    @AppStorage(Prefs.hooksPromptDismissed) private var hooksPromptDismissed = false
    // Read so a change in Settings re-sorts the sidebar.
    @AppStorage(Prefs.folderOrder) private var folderOrder = FolderOrder.manual.rawValue

    var body: some View {
        // Status depends on how long a session has been quiet, so re-evaluate every second.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let manual = folderOrder == FolderOrder.manual.rawValue
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(workspace.orderedProjects) { project in
                        FolderSection(workspace: workspace, project: project, now: context.date,
                                      reorderable: manual, actions: actions)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)
            // One dark surface with the terminal, as in harp, instead of the system's grey material.
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

private struct FolderSection: View {
    let workspace: Workspace
    let project: Project
    let now: Date
    let reorderable: Bool
    let actions: SidebarActions
    @State private var dropTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            FolderHeader(workspace: workspace, project: project, now: now, actions: actions)
                .overlay(alignment: .top) {
                    // Where a dragged folder will land.
                    if dropTarget {
                        Rectangle().fill(Color.accentColor).frame(height: 2).offset(y: -12)
                    }
                }
                .draggable(project.path) {
                    Text(project.name).font(.system(size: 13, weight: .semibold)).padding(6)
                }
                .dropDestination(for: String.self) { paths, _ in
                    guard reorderable, let path = paths.first else { return false }
                    workspace.moveProject(path, before: project.path)
                    return true
                } isTargeted: { dropTarget = reorderable && $0 }
            if !project.collapsed {
                ForEach(project.tabs) { tab in
                    TabRow(workspace: workspace, tab: tab, now: now)
                        .contextMenu {
                            Button("Rename…") { actions.rename(tab.id) }
                            Button("Close Tab") { actions.close(tab.id) }
                        }
                }
            }
        }
    }
}

private struct FolderHeader: View {
    let workspace: Workspace
    let project: Project
    let now: Date
    let actions: SidebarActions
    @State private var hovering = false

    var body: some View {
        let statuses = project.tabs.map { workspace.status(for: $0, now: now) }
        let waiting = statuses.filter { $0 == .needsYou }.count
        let branch = Worktree.headBranch(at: project.path)
        let place = branch ?? abbreviateHome(project.path)
        HStack(spacing: 7) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(project.collapsed ? 0 : 90))
                .frame(width: 10)
            Text(project.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .layoutPriority(1)
            Text(project.collapsed ? "\(place) · \(project.tabs.count) tab\(project.tabs.count == 1 ? "" : "s")" : place)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            if project.collapsed {
                // What's inside, at a glance: its agents and the most urgent state.
                let agents = project.tabs.compactMap { workspace.agent(for: $0) }
                ForEach(Array(Set(agents)).sorted(), id: \.self) { AgentMark(agent: $0) }
                if let worst = statuses.min(), waiting == 0 { StatusIcon(status: worst) }
            }
            if waiting > 0 {
                Text("\(waiting)")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(Color.black.opacity(0.85))
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .background(Palette.amber, in: Capsule())
                    .help("\(waiting) need\(waiting == 1 ? "s" : "") you")
            }
            if hovering {
                Button { actions.newTab(project.path) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("New tab in \(project.name) (⌘T)")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(hovering ? Color.primary.opacity(0.04) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { workspace.setCollapsed(project.path, !project.collapsed) }
        .help(abbreviateHome(project.path))
        .contextMenu {
            Button("New Tab") { actions.newTab(project.path) }
            Button("New Tab in Worktree") { actions.newWorktreeTab(project.path) }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(project.path, forType: .string)
            }
            Divider()
            Button("Close Folder") { actions.closeFolder(project.path) }
        }
    }
}

private struct TabRow: View {
    let workspace: Workspace
    let tab: Tab
    let now: Date
    @State private var hovering = false

    var body: some View {
        let status = workspace.status(for: tab, now: now)
        let selected = tab.id == workspace.selectedTabID
        let emphasized = status == .needsYou || status == .doneUnread
        let agent = workspace.agent(for: tab)
        HStack(spacing: 8) {
            StatusIcon(status: status, isAgent: agent != nil)
            let title = workspace.title(for: tab)
            Text(title)
                .font(.system(size: 13, weight: emphasized ? .semibold : selected ? .medium : .regular))
                .foregroundStyle(status == .dormant ? .secondary : .primary)
                .lineLimit(1)
                // Short names never truncate; long ones give way last.
                .fixedSize(horizontal: title.count <= 14, vertical: false)
                .layoutPriority(1)
            if let worktree = tab.worktree {
                Chip(text: (worktree as NSString).lastPathComponent)
                    .help("Worktree \(abbreviateHome(worktree))")
            }
            if let stray = workspace.strayCwd(tab) {
                Text(stray)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if tab.root.panes.count > 1 {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .help("\(tab.root.panes.count) panes")
            }
            Spacer(minLength: 4)
            if let agent { AgentMark(agent: agent) }
            Text(relativeAge(workspace.lastActivity(tab), now: now))
                .font(.system(size: 11, weight: status == .needsYou ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(status == .needsYou ? Palette.amber : .secondary)
                .frame(minWidth: 22, alignment: .trailing)
        }
        .padding(.leading, 26)
        .padding(.trailing, 8)
        .frame(height: 28)
        .background(
            selected ? Color.primary.opacity(0.09) : hovering ? Color.primary.opacity(0.04) : .clear,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { workspace.select(tab.id) }
        .help(helpText)
    }

    private var helpText: String {
        let s = workspace.sessions[tab.focusedPane]
        let facts = [s?.process, s?.cwd.map(abbreviateHome), s?.branch].compactMap { $0 }.joined(separator: " · ")
        return [workspace.agentMessage(tab), facts].compactMap { $0 }.joined(separator: "\n")
    }
}

/// Which agent runs in a tab: a small lettered tile.
struct AgentMark: View {
    let agent: String

    var body: some View {
        let (letter, fg, bg): (String, Color, Color) = switch agent {
        case "claude": ("C", Color(red: 0.94, green: 0.64, blue: 0.49), Color(red: 0.23, green: 0.16, blue: 0.13))
        case "codex": ("X", Color(red: 0.55, green: 0.77, blue: 1.0), Color(red: 0.12, green: 0.17, blue: 0.22))
        default: (String(agent.prefix(1)).uppercased(), .secondary, Color.primary.opacity(0.1))
        }
        Text(letter)
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .foregroundStyle(fg)
            .frame(width: 16, height: 16)
            .background(bg, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .help(agent == "claude" ? "Claude Code" : agent == "codex" ? "Codex" : agent)
    }
}

/// Session state as one 12pt glyph: a turning arc while working, an amber ring when it
/// needs you, a solid dot when done and unread, a hollow ring when idle, dashed when dormant.
struct StatusIcon: View {
    let status: SessionStatus
    var isAgent = true

    var body: some View {
        Group {
            switch status {
            case .working:
                Spinner(color: isAgent ? Palette.working : Color.primary.opacity(0.7))
            case .starting:
                Spinner(color: Color.primary.opacity(0.45))
            case .needsYou:
                ZStack {
                    Circle().strokeBorder(Palette.amber, lineWidth: 1.5)
                    Circle().fill(Palette.amber).frame(width: 4.4, height: 4.4)
                }
            case .doneUnread:
                Circle().fill(Color.primary.opacity(0.92)).frame(width: 8, height: 8)
            case .idle:
                Circle().strokeBorder(Color.primary.opacity(0.4), lineWidth: 1.25).frame(width: 7.5, height: 7.5)
            case .dormant:
                Circle().strokeBorder(Color.primary.opacity(0.35), style: StrokeStyle(lineWidth: 1.25, dash: [1.6, 1.8]))
                    .frame(width: 8, height: 8)
            }
        }
        .frame(width: 12, height: 12)
        .help(status.label)
    }
}

private struct Spinner: View {
    let color: Color
    @State private var turning = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1.5)
            Circle().trim(from: 0, to: 0.28)
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(turning ? 360 : 0))
                .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: turning)
        }
        .padding(0.75)
        .onAppear { turning = true }
    }
}

enum Palette {
    static let amber = Color(red: 0.96, green: 0.72, blue: 0.24)
    static let working = Color(red: 0.49, green: 0.72, blue: 1.0)
}

func abbreviateHome(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}
