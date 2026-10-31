import SwiftUI

struct SidebarActions {
    var newTab: (String) -> Void
    var newWorktreeTab: (String) -> Void
    var closeFolder: (String) -> Void
    var setUpHooks: () -> Void
    var rename: (String) -> Void
    var close: (String) -> Void
}

/// Number badges shown while ⌘ (folders) or ⌃⌘ (tabs) is held.
@Observable
final class ShortcutHints {
    enum Kind { case folders, tabs }
    var kind: Kind?
}

/// A header per folder, its tabs under it: status (the agent's logo for an agent), name, age.
struct SidebarView: View {
    @Bindable var workspace: Workspace
    let hooks: AgentHooks
    let usage: AgentUsage
    let updates: UpdateCenter
    let hints: ShortcutHints
    let layout: HeaderLayout
    let actions: SidebarActions
    @AppStorage(Prefs.hooksPromptDismissed, store: Prefs.defaults) private var hooksPromptDismissed = false
    // Read so a change in Settings re-sorts the sidebar.
    @AppStorage(Prefs.folderOrder, store: Prefs.defaults) private var folderOrder = FolderOrder.manual.rawValue

    var body: some View {
        // Status depends on how long a session has been quiet, so re-evaluate every second.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let manual = folderOrder == FolderOrder.manual.rawValue
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    let current = workspace.currentProject?.path
                    ForEach(Array(workspace.orderedProjects.enumerated()), id: \.element.id) { index, project in
                        FolderSection(workspace: workspace, project: project, now: context.date,
                                      reorderable: manual, actions: actions,
                                      folderHint: hints.kind == .folders && index < 9 ? index + 1 : nil,
                                      tabHints: hints.kind == .tabs && project.path == current)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, layout.titlebarHeight + 6)
                .padding(.bottom, 16)
                // Full width even with no folders, or the sidebar shrinks to its padding.
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollIndicators(.never)
            // Clear the titlebar with padding, not the safe area: with the safe-area inset, rows
            // were drawn a titlebar lower than where clicks and hovers landed.
            .ignoresSafeArea(.container, edges: .top)
            // One dark surface with the terminal, as in harp, instead of the system's grey material.
            .background(Palette.sidebar.ignoresSafeArea())
            .themedText()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if hooks.anyMissing && !hooksPromptDismissed {
                        HooksPrompt(setUp: actions.setUpHooks, dismiss: { hooksPromptDismissed = true })
                    }
                    UpdateCard(center: updates)
                    UsageFooter(usage: usage, now: context.date)
                }
                .themedText()
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
        .background(Palette.hover, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(8)
    }
}

private struct FolderSection: View {
    let workspace: Workspace
    let project: Project
    let now: Date
    let reorderable: Bool
    let actions: SidebarActions
    let folderHint: Int?
    let tabHints: Bool
    @State private var dropTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            FolderHeader(workspace: workspace, project: project, now: now, actions: actions, hint: folderHint)
                .overlay(alignment: .top) {
                    // Where a dragged folder will land.
                    if dropTarget {
                        Rectangle().fill(Palette.working).frame(height: 2).offset(y: -12)
                    }
                }
                .draggable(project.path) {
                    Text(project.name).font(.system(size: 13, weight: .semibold)).padding(6)
                }
                .dropDestination(for: String.self) { paths, _ in
                    guard let path = paths.first else { return false }
                    if path.hasPrefix("tern-tab:") {
                        workspace.moveTab(String(path.dropFirst(9)), to: project.path)
                        return true
                    }
                    guard reorderable else { return false }
                    workspace.moveProject(path, before: project.path)
                    return true
                } isTargeted: { dropTarget = reorderable && $0 }
            if !project.collapsed {
                ForEach(Array(project.tabs.enumerated()), id: \.element.id) { index, tab in
                    TabRow(workspace: workspace, tab: tab, now: now, actions: actions,
                           hint: tabHints && index < 9 ? ShortcutRegistry.label("tab.select.\(index + 1)") : nil)
                        .draggable("tern-tab:" + tab.id)
                        .dropDestination(for: String.self) { items, _ in
                            guard let item = items.first, item.hasPrefix("tern-tab:") else { return false }
                            workspace.moveTab(String(item.dropFirst(9)), to: project.path, before: tab.id)
                            return true
                        }
                        .contextMenu {
                            Button("Rename…") { actions.rename(tab.id) }
                            Menu("Move to Folder") {
                                ForEach(workspace.projects) { folder in
                                    Button(folder.name) { workspace.moveTab(tab.id, to: folder.path) }
                                }
                            }
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
    let hint: Int?
    @AppStorage(Prefs.workingIndicator, store: Prefs.defaults) private var indicator = WorkingIndicator.trailing
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
            // What's inside, at a glance: the most urgent tab, as its row shows it.
            if project.collapsed, let worst = zip(project.tabs, statuses).min(by: { $0.1 < $1.1 }) {
                if indicator == .trailing, worst.1 == .working || worst.1 == .starting {
                    Spinner(color: worst.1 == .working ? Palette.working : Palette.ring)
                        .frame(width: 12, height: 12)
                } else {
                    StatusIcon(status: worst.1, agent: workspace.agent(for: worst.0), program: workspace.program(for: worst.0),
                               turning: indicator == .turning)
                }
            }
            if waiting > 0 {
                Text("\(waiting)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Palette.amber)
                    .help("\(waiting) need\(waiting == 1 ? "s" : "") you")
            }
            if let hint {
                KeyBadge(text: ShortcutRegistry.label("folder.select.\(hint)"))
            } else if hovering {
                Button { actions.newTab(project.path) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .background(Palette.selection, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("New tab in \(project.name) (\(ShortcutRegistry.label("tab.new")))")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(hovering ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
    let actions: SidebarActions
    let hint: String?
    @AppStorage(Prefs.workingIndicator, store: Prefs.defaults) private var indicator = WorkingIndicator.trailing
    @State private var hovering = false

    var body: some View {
        let status = workspace.status(for: tab, now: now)
        let selected = tab.id == workspace.selectedTabID
        // Weight is for what wants you; selection shows in the background alone.
        let emphasized = status == .needsYou || status == .failed || status == .doneUnread
        let busy = status == .working || status == .starting
        let progress = busy ? workspace.urgentSession(tab, now: now)?.agentProgress : nil
        HStack(spacing: 8) {
            StatusIcon(status: status, agent: workspace.agent(for: tab), program: workspace.program(for: tab),
                       turning: indicator == .turning)
            let title = workspace.title(for: tab)
            if workspace.renamingTabID == tab.id {
                RenameField(initial: tab.name ?? title) { workspace.finishRename(tab.id, name: $0) }
            } else {
                Text(title)
                    .font(.system(size: 13, weight: emphasized ? .semibold : .regular))
                    .foregroundStyle(status == .dormant || status == .starting || workspace.hasPlaceholderTitle(tab) ? .secondary : .primary)
                    .lineLimit(1)
                    // Short names never truncate; long ones give way last.
                    .fixedSize(horizontal: title.count <= 14, vertical: false)
                    .layoutPriority(1)
            }
            if let worktree = tab.worktree {
                Chip(text: (worktree as NSString).lastPathComponent)
                    .help("Worktree \(abbreviateHome(worktree))")
            }
            if let stray = workspace.strayCwd(tab), stray != title {
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
            if let hint {
                KeyBadge(text: hint)
            } else if hovering {
                Button { actions.close(tab.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(Palette.selection, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .buttonStyle(.plain)
                .frame(minWidth: 22, alignment: .trailing)
                .help("Close tab (\(ShortcutRegistry.label("tab.close")))")
            } else if let progress {
                ProgressRing(progress: progress, color: Palette.working)
                    .frame(width: 12, height: 12)
                    .frame(minWidth: 22, alignment: .trailing)
                    .help("\(status.label) · \(progress)%")
            } else if indicator == .trailing, busy {
                Spinner(color: status == .working ? Palette.working : Palette.ring)
                    .frame(width: 12, height: 12)
                    .frame(minWidth: 22, alignment: .trailing)
                    .help(status.label)
            } else {
                Text(relativeAge(workspace.lastActivity(tab), now: now))
                    .font(.system(size: 11, weight: status == .needsYou ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(status == .needsYou ? Palette.amber : status == .working ? Palette.working : .secondary)
                    .frame(minWidth: 22, alignment: .trailing)
            }
        }
        .padding(.leading, 26)
        .padding(.trailing, 8)
        .frame(height: 28)
        .background {
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            ZStack {
                shape.fill(selected ? Palette.selection : hovering ? Palette.hover : .clear)
                if status == .needsYou { shape.fill(Palette.amber.opacity(0.1)) }
            }
        }
        .overlay(alignment: .leading) {
            // Needs you is the one state that also marks the row's edge.
            if status == .needsYou {
                RoundedRectangle(cornerRadius: 1.5).fill(Palette.amber).frame(width: 3, height: 16).padding(.leading, 8)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // The first click selects at once; the second of a double-click renames.
        .onTapGesture(count: 2) { actions.rename(tab.id) }
        .simultaneousGesture(TapGesture().onEnded { workspace.select(tab.id) })
        .help(helpText)
    }

    private var helpText: String {
        let s = workspace.sessions[tab.focusedPane]
        let facts = [s?.process, s?.cwd.map(abbreviateHome), s?.branch].compactMap { $0 }.joined(separator: " · ")
        return [workspace.agentMessage(tab), facts].compactMap { $0 }.joined(separator: "\n")
    }
}

/// A tab's name being edited in place: ↩ saves, Esc cancels, clicking elsewhere saves.
/// Saving it empty names the tab after what runs in it again.
private struct RenameField: View {
    let finish: (String?) -> Void
    @State private var text: String
    @State private var done = false
    @FocusState private var focused: Bool

    init(initial: String, finish: @escaping (String?) -> Void) {
        self.finish = finish
        _text = State(initialValue: initial)
    }

    var body: some View {
        TextField("Name after what's running", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 4)
            .frame(height: 22)
            .background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Palette.working, lineWidth: 1))
            .focused($focused)
            .onSubmit { end(text) }
            .onExitCommand { end(nil) }
            .onChange(of: focused) { _, now in if !now { end(text) } }
            // Wait a turn: the click that started this may still be handing focus to the terminal.
            .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func end(_ name: String?) {
        guard !done else { return }
        done = true
        finish(name)
    }
}

/// A shortcut shown while its modifier is held.
private struct KeyBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(.primary)
            .padding(.horizontal, 5)
            .frame(height: 18)
            .background(Palette.chip, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Palette.border))
            .fixedSize()
    }
}

/// Session state as one 12pt glyph. Its shape says who: the agent's mark, a rounded square for
/// another program that reports its own status (OSC 7501), or a circle for a shell. Colour says
/// what: amber when it needs you, red when it failed, the working colour while it works, text
/// colour when done and unread, grey when idle, fainter when dormant. Solid means there's
/// something for you to see.
struct StatusIcon: View {
    let status: SessionStatus
    var agent: String?
    /// The program that reported its status, shown when no agent runs.
    var program: String?
    /// Turn while working; otherwise the glyph holds still and a Spinner shows elsewhere.
    var turning = false

    var body: some View {
        let mark = program == nil || agent != nil ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        Group {
            if let agent, status != .starting {
                AgentGlyph(agent: agent, color: color, turning: turning && status == .working)
            } else {
                switch status {
                case .needsYou, .failed, .doneUnread:
                    mark.fill(color).frame(width: 8, height: 8)
                case .working, .starting:
                    if turning {
                        Spinner(color: color)
                    } else {
                        mark.stroke(color, lineWidth: 1.5).frame(width: 7, height: 7)
                    }
                case .idle, .dormant:
                    mark.stroke(color, lineWidth: 1.25).frame(width: 6.25, height: 6.25)
                }
            }
        }
        .frame(width: 12, height: 12)
        .help((agent.map(agentName) ?? program).map { "\($0) · \(status.label)" } ?? status.label)
    }

    private var color: Color {
        switch status {
        case .needsYou: Palette.amber
        case .failed: Palette.failed
        case .working: Palette.working
        case .doneUnread: Palette.text
        case .starting, .idle: Palette.ring
        case .dormant: Palette.ring.opacity(0.45)
        }
    }
}

/// A ring filled to the percentage a program reported, in place of a Spinner.
struct ProgressRing: View {
    let progress: Int
    let color: Color

    var body: some View {
        ZStack {
            Circle().stroke(Palette.border, lineWidth: 1.5)
            Circle().trim(from: 0, to: CGFloat(min(max(progress, 0), 100)) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(0.75)
        .animation(Motion.animation(), value: progress)
    }
}

/// A turning arc on a faint ring, filling its frame.
struct Spinner: View {
    let color: Color
    @State private var turning = false

    var body: some View {
        ZStack {
            Circle().stroke(Palette.border, lineWidth: 1.5)
            Circle().trim(from: 0, to: 0.28)
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(turning ? 360 : 0))
                .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: turning)
        }
        .padding(0.75)
        .onAppear { turning = true }
    }
}

nonisolated func abbreviateHome(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}
