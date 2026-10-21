import CoreGraphics
import Foundation
import Observation

enum SplitAxis: String, Codable {
    /// Panes side by side (split right).
    case horizontal
    /// Panes stacked (split down).
    case vertical
}

/// A tab's pane layout. Each leaf is a ternd session id.
indirect enum SplitNode: Codable, Equatable {
    case pane(String)
    case split(SplitAxis, ratio: Double, SplitNode, SplitNode)

    var panes: [String] {
        switch self {
        case .pane(let id): [id]
        case .split(_, _, let a, let b): a.panes + b.panes
        }
    }

    func replacing(_ id: String, with node: SplitNode) -> SplitNode {
        switch self {
        case .pane(let p): p == id ? node : self
        case .split(let axis, let ratio, let a, let b):
            .split(axis, ratio: ratio, a.replacing(id, with: node), b.replacing(id, with: node))
        }
    }

    /// The tree without `id`, or nil if nothing is left.
    func removing(_ id: String) -> SplitNode? {
        switch self {
        case .pane(let p): return p == id ? nil : self
        case .split(let axis, let ratio, let a, let b):
            let a2 = a.removing(id), b2 = b.removing(id)
            switch (a2, b2) {
            case let (a2?, b2?): return .split(axis, ratio: ratio, a2, b2)
            case let (a2?, nil): return a2
            case let (nil, b2?): return b2
            case (nil, nil): return nil
            }
        }
    }

    /// Frames of every pane inside `rect`.
    func frames(in rect: CGRect) -> [(String, CGRect)] {
        switch self {
        case .pane(let id): return [(id, rect)]
        case .split(let axis, let ratio, let a, let b):
            let (ra, rb) = Self.divide(rect, axis: axis, ratio: ratio)
            return a.frames(in: ra) + b.frames(in: rb)
        }
    }

    static func divide(_ rect: CGRect, axis: SplitAxis, ratio: Double) -> (CGRect, CGRect) {
        switch axis {
        case .horizontal:
            let w = (rect.width * ratio).rounded()
            return (CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height),
                    CGRect(x: rect.minX + w, y: rect.minY, width: rect.width - w, height: rect.height))
        case .vertical:
            // AppKit's y axis points up: the first pane goes on top.
            let h = (rect.height * ratio).rounded()
            return (CGRect(x: rect.minX, y: rect.maxY - h, width: rect.width, height: h),
                    CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - h))
        }
    }
}

struct Tab: Codable, Identifiable, Equatable {
    var id: String
    /// Set by the user with Rename; otherwise the title is derived from the session.
    var name: String?
    var root: SplitNode
    var focusedPane: String
    var zoomed = false
    /// The worktree tern made for this tab, offered for removal when the tab closes.
    var worktree: String?
    /// "Tab 3": the lowest number free in its folder when it opened, kept for life.
    var number: Int?
}

/// A folder header in the sidebar. Its tabs start in the folder; it goes away with its last tab.
struct Project: Codable, Identifiable, Equatable {
    var id: String { path }
    var path: String
    var tabs: [Tab]
    var collapsed = false
    /// The tab last selected here, which ⌘1–9 and reopening the folder return to.
    var lastTab: String?

    var name: String {
        path == NSHomeDirectory() ? "Home" : (path as NSString).lastPathComponent
    }

    /// The lowest tab number not in use here.
    var freeNumber: Int {
        let used = Set(tabs.compactMap(\.number))
        return (1...).first { !used.contains($0) }!
    }

    /// Numbers tabs saved before tabs had them.
    mutating func numberTabs() {
        for i in tabs.indices where tabs[i].number == nil { tabs[i].number = freeNumber }
    }
}

/// How the sidebar orders folders.
enum FolderOrder: String {
    /// As opened, then dragged: positions stay put, for muscle memory.
    case manual
    /// The folder used last on top.
    case recent
}

enum FocusDirection { case left, right, up, down }

/// Ordered by urgency: a tab shows its most urgent pane.
enum SessionStatus: Int, Comparable {
    case needsYou, working, doneUnread, starting, idle, dormant

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .needsYou: "Needs you"
        case .working: "Working"
        case .doneUnread: "Done"
        case .starting: "Starting"
        case .idle: "Idle"
        case .dormant: "Dormant"
        }
    }
}

/// "now", "4m", "2h", "3d".
func relativeAge(_ date: Date?, now: Date) -> String {
    guard let date else { return "" }
    let s = max(0, now.timeIntervalSince(date))
    if s < 60 { return "now" }
    if s < 3600 { return "\(Int(s / 60))m" }
    if s < 86400 { return "\(Int(s / 3600))h" }
    return "\(Int(s / 86400))d"
}

/// An agent conversation: which agent, and its own session id.
struct AgentRef: Codable, Equatable {
    var agent: String
    var session: String
}

/// UserDefaults keys for the settings window.
enum Prefs {
    static let notifyNeedsYou = "notifyNeedsYou"
    static let notifyDone = "notifyDone"
    static let worktrees = "worktreePerSession"
    static let resumeAgents = "resumeAgents"
    static let hooksPromptDismissed = "hooksPromptDismissed"
    static let folderOrder = "folderOrder"
    /// Folders searched for git repositories to offer in the folder picker, comma-separated.
    static let repoRoots = "repoRoots"
    static let theme = "theme"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            notifyNeedsYou: true, notifyDone: true, worktrees: false, resumeAgents: true,
            folderOrder: FolderOrder.manual.rawValue, repoRoots: "~/dev", theme: Theme.defaultID,
        ])
    }

    static var order: FolderOrder {
        FolderOrder(rawValue: UserDefaults.standard.string(forKey: folderOrder) ?? "") ?? .manual
    }
}

@Observable
final class Workspace {
    private(set) var projects: [Project] = []
    var selectedTabID: String?
    /// Live session state from ternd, keyed by pane (session) id.
    private(set) var sessions: [String: SessionInfo] = [:]
    /// Last known working directory per pane, so a pane whose session is gone
    /// (after a reboot) starts a fresh shell in the same place.
    private var paneCwd: [String: String] = [:]
    /// Output, bell and agent-report times already seen per pane, for unread marks.
    private var seen: [String: Seen] = [:]
    private struct Seen { var output: UInt64; var bells: UInt64; var agent: UInt64 }
    /// The agent conversation last seen in each pane, so it can be resumed after a reboot.
    private var paneAgent: [String: AgentRef] = [:]
    /// When each folder was last used in tern, for the folder picker and recent-first order.
    private(set) var recents: [String: Date] = [:]
    /// When each pane was last resized: the shell redraws its prompt then, which isn't news.
    @ObservationIgnored private var resizedAt: [String: Date] = [:]
    private var adoptedOrphans = false
    /// Whether the user can see the window; nothing is "seen" while tern is in the background.
    var isActive = true {
        didSet { if isActive { markSeen() } }
    }

    /// An agent in a pane changed state: (tab, pane, session info).
    @ObservationIgnored var onAgentEvent: ((Tab, SessionInfo) -> Void)?

    @ObservationIgnored var onChange: (() -> Void)?

    /// A tab that had its own worktree is gone; the worktree may be left behind.
    @ObservationIgnored var onWorktreeClosed: ((String) -> Void)?

    // MARK: Lookup

    /// Folders in sidebar order.
    var orderedProjects: [Project] {
        guard Prefs.order == .recent else { return projects }
        let indexed = projects.enumerated().map { ($0.offset, $0.element) }
        return indexed.sorted { a, b in
            let ra = recents[a.1.path] ?? .distantPast, rb = recents[b.1.path] ?? .distantPast
            return ra != rb ? ra > rb : a.0 < b.0
        }.map(\.1)
    }

    var allTabs: [Tab] { orderedProjects.flatMap(\.tabs) }

    var selectedTab: Tab? { allTabs.first { $0.id == selectedTabID } }

    func project(containing tabID: String) -> Project? {
        projects.first { $0.tabs.contains { $0.id == tabID } }
    }

    func project(at path: String) -> Project? {
        projects.first { $0.path == path }
    }

    /// The agent a tab runs (or ran, if it hasn't been reopened since a restart).
    func agent(for tab: Tab) -> String? {
        let panes = [tab.focusedPane] + tab.root.panes.filter { $0 != tab.focusedPane }
        return panes.lazy.compactMap { self.sessions[$0]?.agent }.first
            ?? panes.lazy.compactMap { self.sessions[$0] == nil ? self.paneAgent[$0]?.agent : nil }.first
    }

    /// Where the tab is, when that's not the folder (or worktree) it started in:
    /// relative inside the folder, otherwise from home.
    func strayCwd(_ tab: Tab) -> String? {
        guard let cwd = sessions[tab.focusedPane]?.cwd, let project = project(containing: tab.id) else { return nil }
        let base = tab.worktree ?? project.path
        if cwd == base { return nil }
        if cwd.hasPrefix(base + "/") { return String(cwd.dropFirst(base.count + 1)) }
        return abbreviateHome(cwd)
    }

    func cwd(for pane: String) -> String {
        sessions[pane]?.cwd ?? paneCwd[pane] ?? NSHomeDirectory()
    }

    func isUnread(_ tab: Tab) -> Bool {
        guard !isVisible(tab) else { return false }
        return tab.root.panes.contains { pane in
            guard let s = sessions[pane], let seen = seen[pane] else { return false }
            return s.lastOutputMs > seen.output || s.bells > seen.bells
        }
    }

    func isVisible(_ tab: Tab) -> Bool { isActive && tab.id == selectedTabID }

    /// What a session is doing, most urgent across its panes.
    func status(for tab: Tab, now: Date = Date()) -> SessionStatus {
        tab.root.panes.map { status(pane: $0, visible: isVisible(tab), now: now) }.min() ?? .starting
    }

    private func status(pane: String, visible: Bool, now: Date) -> SessionStatus {
        // No session: being started if it's on screen, otherwise waiting to be opened.
        guard let s = sessions[pane] else { return selectedTab?.root.panes.contains(pane) == true ? .starting : .dormant }
        let seen = seen[pane]
        let nowMs = UInt64(max(0, now.timeIntervalSince1970 * 1000))
        let quiet = Double(nowMs &- min(nowMs, s.lastOutputMs)) / 1000

        // Agents with hooks say what they're doing.
        if let state = s.agentState, let at = s.agentStateMs {
            let unseen = !visible && (seen.map { at > $0.agent } ?? false)
            switch state {
            case "needs_you":
                return .needsYou
            case "working":
                // A turn that ends without a Stop hook (an error, an interrupt) goes quiet: trust the silence.
                if quiet < 5 || Double(nowMs &- min(nowMs, at)) / 1000 < 5 { return .working }
                return unseen ? .doneUnread : .idle
            case "done":
                return unseen ? .doneUnread : .idle
            default:
                return .idle
            }
        }

        if !visible, let seen, s.bells > seen.bells { return .needsYou }
        if !Self.shells.contains(s.process), quiet < 4 { return .working }
        if !visible, let seen, s.lastOutputMs > seen.output { return .doneUnread }
        if quiet > 24 * 3600 { return .dormant }
        return .idle
    }

    /// Since when the tab's agent has been in its current state (working, waiting).
    func stateSince(_ tab: Tab) -> Date? {
        tab.root.panes.compactMap { sessions[$0]?.agentStateMs }.max()
            .map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    func noteResize(_ pane: String) { resizedAt[pane] = Date() }

    /// What the agent in this tab last said, if it's waiting on you or just finished.
    func agentMessage(_ tab: Tab) -> String? {
        let infos = tab.root.panes.compactMap { sessions[$0] }
        return (infos.first { $0.agentState == "needs_you" } ?? infos.first { $0.id == tab.focusedPane })?.agentMessage
    }

    /// Time of the latest output in any of the tab's panes.
    func lastActivity(_ tab: Tab) -> Date? {
        tab.root.panes.compactMap { sessions[$0]?.lastOutputMs }.max()
            .map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    /// The session's name, numbered when another session in its project would show the same one.
    /// A tab goes by what it runs: an agent's task, the command in the foreground, or the
    /// last one that ran ("npm run dev"). A shell that has run nothing yet is "Tab 2".
    func title(for tab: Tab) -> String {
        if let name = tab.name, !name.isEmpty { return name }
        guard let s = sessions[tab.focusedPane] else {
            // Not running yet (say, after a reboot): name it after what it was.
            return paneAgent[tab.focusedPane]?.agent ?? fallbackTitle(tab)
        }
        // Agents title the terminal after the task ("✳ Fix login redirect"); that names the session best.
        if s.agent != nil, let task = Self.cleanTitle(s.title), !task.isEmpty, !Self.agents.contains(task.lowercased()) {
            return task
        }
        if let agent = s.agent { return agent }
        if let command = s.command, !command.isEmpty { return command }
        // The folder header says where; a stray directory shows beside the name.
        return Self.shells.contains(s.process) ? fallbackTitle(tab) : s.process
    }

    private func fallbackTitle(_ tab: Tab) -> String {
        "Tab \(tab.number ?? 1)"
    }

    /// Drops the spinner or status glyphs agents put in front of the title.
    static func cleanTitle(_ title: String) -> String? {
        let t = title.drop { !($0.isLetter || $0.isNumber) }.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("Claude Code") || t == "Codex" { return nil }
        return t.isEmpty ? nil : t
    }

    static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "nu", "login", "tern"]
    static let agents: Set<String> = ["claude", "codex"]

    // MARK: Mutations

    private func mutateTab(_ id: String, _ body: (inout Tab) -> Void) {
        for p in projects.indices {
            if let t = projects[p].tabs.firstIndex(where: { $0.id == id }) {
                body(&projects[p].tabs[t])
                changed()
                return
            }
        }
    }

    private func changed() { onChange?() }

    static func newID(_ prefix: String) -> String {
        prefix + "-" + UUID().uuidString.prefix(8).lowercased()
    }

    /// Adds a tab with one fresh pane to the project at `path` (created if needed).
    @discardableResult
    func newTab(projectPath: String, cwd: String, paneID: String? = nil) -> Tab {
        let pane = paneID ?? Self.newID("p")
        paneCwd[pane] = cwd
        var tab = Tab(id: Self.newID("t"), root: .pane(pane), focusedPane: pane, number: 1)
        if let i = projects.firstIndex(where: { $0.path == projectPath }) {
            tab.number = projects[i].freeNumber
            projects[i].tabs.append(tab)
            projects[i].collapsed = false
            projects[i].lastTab = tab.id
        } else {
            projects.append(Project(path: projectPath, tabs: [tab], lastTab: tab.id))
        }
        selectedTabID = tab.id
        recents[projectPath] = Date()
        changed()
        return tab
    }

    /// Opens a folder: back to it if it's already in the sidebar, otherwise a new header
    /// with one tab there (in a fresh worktree with `worktree`).
    @discardableResult
    func openFolder(_ path: String, worktree: Bool = false) -> Worktree.Failure? {
        let path = Self.normalize(path)
        if !worktree, let project = project(at: path) {
            if project.collapsed { setCollapsed(path, false) }
            if let id = project.lastTab ?? project.tabs.first?.id { select(id) }
            return nil
        }
        return newSession(projectPath: path, cwd: path, worktree: worktree)
    }

    static func normalize(_ path: String) -> String {
        let p = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        return p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p
    }

    /// The folder of the selected tab.
    var currentProject: Project? { selectedTabID.flatMap { project(containing: $0) } }

    /// A new tab in the current folder, starting in the folder itself. With `worktree`
    /// (or the setting on, in a git project) it gets its own worktree; failures come back
    /// for the caller to show.
    @discardableResult
    func newTabInCurrentProject(worktree: Bool? = nil) -> Worktree.Failure? {
        guard let project = currentProject else { return nil }
        return newSession(projectPath: project.path, cwd: project.path, worktree: worktree)
    }

    @discardableResult
    func newSession(projectPath: String, cwd: String, worktree: Bool? = nil) -> Worktree.Failure? {
        let wanted = worktree ?? UserDefaults.standard.bool(forKey: Prefs.worktrees)
        // The setting applies only where it can: inside a git repository.
        guard wanted, worktree == true || Worktree.mainRoot(of: cwd) != nil else {
            newTab(projectPath: projectPath, cwd: cwd)
            return nil
        }
        switch Worktree.create(from: cwd) {
        case .success(let created):
            let tab = newTab(projectPath: projectPath, cwd: created.path)
            mutateTab(tab.id) { $0.worktree = created.path }
            return nil
        case .failure(let failure):
            return failure
        }
    }

    func split(_ axis: SplitAxis) {
        guard let tab = selectedTab else { return }
        let pane = Self.newID("p")
        paneCwd[pane] = cwd(for: tab.focusedPane)
        mutateTab(tab.id) { t in
            t.root = t.root.replacing(t.focusedPane, with: .split(axis, ratio: 0.5, .pane(t.focusedPane), .pane(pane)))
            t.focusedPane = pane
            t.zoomed = false
        }
    }

    func setRatio(tabID: String, path: [Bool], ratio: Double) {
        func update(_ node: SplitNode, _ path: ArraySlice<Bool>) -> SplitNode {
            guard case .split(let axis, let r, let a, let b) = node else { return node }
            guard let first = path.first else { return .split(axis, ratio: ratio, a, b) }
            return first ? .split(axis, ratio: r, a, update(b, path.dropFirst()))
                         : .split(axis, ratio: r, update(a, path.dropFirst()), b)
        }
        mutateTab(tabID) { $0.root = update($0.root, path[...]) }
    }

    /// Removes a pane from the layout (its session has ended or is being closed).
    func removePane(_ pane: String) {
        for p in projects.indices {
            guard let t = projects[p].tabs.firstIndex(where: { $0.root.panes.contains(pane) }) else { continue }
            let tabID = projects[p].tabs[t].id
            if let root = projects[p].tabs[t].root.removing(pane) {
                projects[p].tabs[t].root = root
                if projects[p].tabs[t].focusedPane == pane {
                    projects[p].tabs[t].focusedPane = root.panes.first!
                }
                projects[p].tabs[t].zoomed = false
            } else {
                let order = allTabs.map(\.id)
                let worktree = projects[p].tabs[t].worktree
                projects[p].tabs.remove(at: t)
                if projects[p].lastTab == tabID { projects[p].lastTab = nil }
                if let worktree { DispatchQueue.main.async { self.onWorktreeClosed?(worktree) } }
                // The neighbour in the same folder takes over, else the next tab in the sidebar.
                let sibling = projects[p].tabs.isEmpty ? nil : projects[p].tabs[min(t, projects[p].tabs.count - 1)].id
                // A folder lasts as long as its tabs.
                if projects[p].tabs.isEmpty { projects.remove(at: p) }
                if selectedTabID == tabID {
                    let i = order.firstIndex(of: tabID) ?? 0
                    let remaining = allTabs.map(\.id)
                    selectedTabID = sibling ?? (remaining.isEmpty ? nil : remaining[min(i, remaining.count - 1)])
                    if let id = selectedTabID, let q = projects.firstIndex(where: { $0.tabs.contains { $0.id == id } }) {
                        projects[q].lastTab = id
                    }
                }
            }
            paneCwd[pane] = nil
            paneAgent[pane] = nil
            seen[pane] = nil
            changed()
            return
        }
    }

    func focus(pane: String) {
        guard let tab = allTabs.first(where: { $0.root.panes.contains(pane) }) else { return }
        if tab.focusedPane != pane { mutateTab(tab.id) { $0.focusedPane = pane } }
        if selectedTabID != tab.id { select(tab.id) }
    }

    func select(_ tabID: String) {
        selectedTabID = tabID
        if let p = projects.firstIndex(where: { $0.tabs.contains { $0.id == tabID } }) {
            projects[p].lastTab = tabID
            recents[projects[p].path] = Date()
        }
        markSeen()
        changed()
    }

    /// ⌘1–9: the nth folder, at the tab last used there.
    func selectFolder(index: Int) {
        let folders = orderedProjects
        guard folders.indices.contains(index) else { return }
        let folder = folders[index]
        if folder.collapsed { setCollapsed(folder.path, false) }
        if let id = folder.lastTab ?? folder.tabs.first?.id { select(id) }
    }

    /// ⌘⇧1–9: the nth tab in the current folder.
    func selectTabInFolder(index: Int) {
        guard let tabs = currentProject?.tabs, tabs.indices.contains(index) else { return }
        select(tabs[index].id)
    }

    /// Drag to reorder: puts the folder at `path` just before `target` (or last).
    func moveProject(_ path: String, before target: String?) {
        guard path != target, let from = projects.firstIndex(where: { $0.path == path }) else { return }
        let project = projects.remove(at: from)
        let to = target.flatMap { t in projects.firstIndex { $0.path == t } } ?? projects.endIndex
        projects.insert(project, at: to)
        changed()
    }

    func cycleTab(_ delta: Int) {
        let tabs = allTabs
        guard !tabs.isEmpty else { return }
        let i = tabs.firstIndex { $0.id == selectedTabID } ?? 0
        select(tabs[(i + delta + tabs.count) % tabs.count].id)
    }

    /// Selects the next tab that wants attention: an agent waiting on you first,
    /// then one that finished, then any unread output. Searches after the current tab, wrapping.
    @discardableResult
    func jumpToNextUnread() -> Bool {
        let tabs = allTabs
        guard !tabs.isEmpty else { return false }
        let start = tabs.firstIndex { $0.id == selectedTabID } ?? -1
        let order = (1...tabs.count).map { tabs[(start + $0 + tabs.count) % tabs.count] }.filter { $0.id != selectedTabID }
        let now = Date()
        let pick = order.first { status(for: $0, now: now) == .needsYou }
            ?? order.first { status(for: $0, now: now) == .doneUnread }
            ?? order.first { isUnread($0) }
        guard let pick else { return false }
        select(pick.id)
        return true
    }

    var needsYouCount: Int {
        let now = Date()
        return allTabs.filter { status(for: $0, now: now) == .needsYou }.count
    }

    func cyclePane(_ delta: Int) {
        guard let tab = selectedTab else { return }
        let panes = tab.root.panes
        let i = panes.firstIndex(of: tab.focusedPane) ?? 0
        mutateTab(tab.id) { $0.focusedPane = panes[(i + delta + panes.count) % panes.count] }
    }

    func moveFocus(_ dir: FocusDirection) {
        guard let tab = selectedTab else { return }
        let frames = tab.root.frames(in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let current = frames.first(where: { $0.0 == tab.focusedPane })?.1 else { return }
        let candidates = frames.filter { id, r in
            guard id != tab.focusedPane else { return false }
            switch dir {
            case .left: return r.maxX <= current.minX + 0.001 && r.maxY > current.minY && r.minY < current.maxY
            case .right: return r.minX >= current.maxX - 0.001 && r.maxY > current.minY && r.minY < current.maxY
            case .up: return r.minY >= current.maxY - 0.001 && r.maxX > current.minX && r.minX < current.maxX
            case .down: return r.maxY <= current.minY + 0.001 && r.maxX > current.minX && r.minX < current.maxX
            }
        }
        let best = candidates.min { a, b in
            hypot(a.1.midX - current.midX, a.1.midY - current.midY) < hypot(b.1.midX - current.midX, b.1.midY - current.midY)
        }
        if let best { mutateTab(tab.id) { $0.focusedPane = best.0 } }
    }

    func toggleZoom() {
        guard let tab = selectedTab, tab.root.panes.count > 1 else { return }
        mutateTab(tab.id) { $0.zoomed.toggle() }
    }

    func rename(_ tabID: String, to name: String) {
        mutateTab(tabID) { $0.name = name.isEmpty ? nil : name }
    }

    func setCollapsed(_ path: String, _ collapsed: Bool) {
        guard let i = projects.firstIndex(where: { $0.path == path }) else { return }
        projects[i].collapsed = collapsed
        changed()
    }

    // MARK: Live session updates

    func update(sessions list: [SessionInfo]) {
        let previous = sessions
        let agentsBefore = paneAgent
        defer { if paneAgent != agentsBefore { save() } }
        sessions = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for s in list {
            if let cwd = s.cwd { paneCwd[s.id] = cwd }
            if seen[s.id] == nil { seen[s.id] = Seen(output: s.lastOutputMs, bells: s.bells, agent: s.agentStateMs ?? 0) }
            if let at = resizedAt[s.id], -at.timeIntervalSinceNow < 2, var mark = seen[s.id] {
                mark.output = max(mark.output, s.lastOutputMs)
                seen[s.id] = mark
            }
            if let agent = s.agent, let id = s.agentSession { paneAgent[s.id] = AgentRef(agent: agent, session: id) }
            if s.agent == nil, s.agentState == nil, previous[s.id]?.agentState != nil { paneAgent[s.id] = nil }
            if let old = previous[s.id], s.agentStateMs != old.agentStateMs, s.agentState != old.agentState,
               let tab = allTabs.first(where: { $0.root.panes.contains(s.id) }) {
                onAgentEvent?(tab, s)
            }
        }
        markSeen()
        if !adoptedOrphans {
            adoptedOrphans = true
            adoptOrphans(list)
        }
    }

    /// Visible panes are always "seen".
    private func markSeen() {
        guard isActive, let tab = selectedTab else { return }
        for pane in tab.root.panes {
            if let s = sessions[pane] { seen[pane] = Seen(output: s.lastOutputMs, bells: s.bells, agent: s.agentStateMs ?? 0) }
        }
    }

    /// The command that resumes the agent conversation a pane had before its session ended
    /// (after a reboot), typed into the fresh shell.
    func resumeCommand(for pane: String) -> String? {
        guard sessions[pane] == nil, let ref = paneAgent[pane], UserDefaults.standard.bool(forKey: Prefs.resumeAgents) else { return nil }
        switch ref.agent {
        case "claude": return "claude --resume \(ref.session)"
        case "codex": return "codex resume \(ref.session)"
        default: return nil
        }
    }

    /// Sessions running in ternd that no tab knows about (started from the CLI,
    /// or left from an older layout) become tabs, grouped by git root.
    private func adoptOrphans(_ list: [SessionInfo]) {
        let known = Set(allTabs.flatMap { $0.root.panes })
        let selected = selectedTabID
        for s in list where !known.contains(s.id) && !s.id.hasPrefix("bench-") {
            let cwd = s.cwd ?? NSHomeDirectory()
            newTab(projectPath: s.gitRoot ?? cwd, cwd: cwd, paneID: s.id)
        }
        if let selected { selectedTabID = selected }
        if selectedTabID == nil { selectedTabID = allTabs.first?.id }
    }

    // MARK: Persistence

    private struct Saved: Codable {
        var projects: [Project]
        var selectedTabID: String?
        var paneCwd: [String: String]
        var paneAgent: [String: AgentRef]?
        var recents: [String: Date]?
    }

    static let layoutURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/tern", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("layout.json")
    }()

    func load() {
        guard let data = try? Data(contentsOf: Self.layoutURL),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        projects = saved.projects.filter { !$0.tabs.isEmpty }
        for i in projects.indices { projects[i].numberTabs() }
        selectedTabID = saved.selectedTabID ?? projects.first?.tabs.first?.id
        paneCwd = saved.paneCwd
        paneAgent = saved.paneAgent ?? [:]
        // Folders not used for 90 days drop out of the picker's recents.
        recents = (saved.recents ?? [:]).filter { $0.value.timeIntervalSinceNow > -90 * 86400 }
        for p in projects.indices {
            for t in projects[p].tabs.indices { projects[p].tabs[t].zoomed = false }
        }
    }

    func save() {
        let saved = Saved(projects: projects, selectedTabID: selectedTabID, paneCwd: paneCwd, paneAgent: paneAgent, recents: recents)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(saved) else { return }
        try? data.write(to: Self.layoutURL, options: .atomic)
    }
}
