import AppKit
import SwiftUI

/// A folder the picker can open.
struct FolderCandidate: Identifiable, Equatable {
    /// `device` is a device itself (`host:`), which lists its folders when chosen.
    enum Source: Int { case open, recent, repo, path, device }

    var id: String { path }
    /// A path on this Mac, or `host:/path` on a device.
    let path: String
    let source: Source
    /// "4 tabs", "2h ago".
    var note = ""

    var location: FolderLocation { FolderLocation(path) }
    var name: String { source == .device ? location.host ?? path : location.name }
    /// Where it is, as the row shows it.
    var place: String { source == .device ? "Folders on \(location.host ?? path)" : location.label }
}

/// Where folder candidates come from: tern's own history, zoxide's, and git
/// repositories under the configured roots. The slow ones run off the main thread.
enum FolderSources {
    /// zoxide's database, best first, or nothing if zoxide isn't installed.
    nonisolated static func zoxide() -> [(path: String, score: Double)] {
        let candidates = ["/opt/homebrew/bin/zoxide", "/usr/local/bin/zoxide",
                          NSHomeDirectory() + "/.cargo/bin/zoxide", NSHomeDirectory() + "/.local/bin/zoxide",
                          "/run/current-system/sw/bin/zoxide", NSHomeDirectory() + "/.nix-profile/bin/zoxide"]
        guard let binary = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else { return [] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["query", "--list", "--score"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let score = Double(parts[0]) else { return nil }
            return (String(parts[1]), score)
        }
    }

    /// Git repositories up to three levels under each root, not descending into them.
    nonisolated static func repos(roots: [String], limit: Int = 400) -> [String] {
        var found: [String] = []
        let fm = FileManager.default
        let skip: Set<String> = ["node_modules", "target", "build", "dist", "vendor", "Library", "Pods"]
        func walk(_ dir: String, depth: Int) {
            guard found.count < limit, let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for name in names.sorted() where !name.hasPrefix(".") && !skip.contains(name) {
                let path = dir + "/" + name
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
                var gitIsDir: ObjCBool = false
                if fm.fileExists(atPath: path + "/.git", isDirectory: &gitIsDir) {
                    // A .git file is a worktree (or submodule): it opens from its repository.
                    if gitIsDir.boolValue { found.append(path) }
                    continue
                }
                if depth < 3 { walk(path, depth: depth + 1) }
            }
        }
        for root in roots {
            walk(Workspace.normalize(root), depth: 1)
        }
        return found
    }

    static var roots: [String] { Prefs.repoRootList }

    static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    // Results from the last open, shown at once while fresh ones load.
    static var cachedZoxide: [(path: String, score: Double)] = []
    static var cachedRepos: [String] = []
    /// Each device's folders from the last time the picker asked it.
    static var cachedRemote: [String: RemoteFolders] = [:]

    /// `host:rest` for a device, when the query names one; nil for a path or a name.
    static func deviceQuery(_ q: String) -> (host: String, rest: String)? {
        guard !q.hasPrefix("/"), !q.hasPrefix("~"), !q.hasPrefix("."), let colon = q.firstIndex(of: ":") else { return nil }
        let host = String(q[..<colon])
        guard Device.validHost(host) else { return nil }
        return (host, String(q[q.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
    }

    /// A typed path on a device split into the folder to list and the start of a name in it.
    static func splitRemotePath(_ rest: String) -> (dir: String, prefix: String) {
        if rest == "~" || rest == "/" || rest.hasSuffix("/") { return (rest, "") }
        guard let slash = rest.lastIndex(of: "/") else { return ("~", rest) }
        let dir = String(rest[..<slash])
        return (dir.isEmpty ? "/" : dir, String(rest[rest.index(after: slash)...]))
    }
}

/// The ⌘N picker's state. The controller owns it so menu shortcuts that reach the
/// window first (⌘↩, ⌘O) can still act on it.
@Observable
final class FolderPickerModel {
    var query = "" { didSet { if query != oldValue { selection = 0; askDevice() } } }
    var selection = 0
    private var zoxide = FolderSources.cachedZoxide
    private var repos = FolderSources.cachedRepos
    private let workspace: Workspace
    /// What devices answered: their folders, and folder listings by "host:dir".
    private var remote = FolderSources.cachedRemote
    private var remoteDirs: [String: RemoteDirs] = [:]
    /// Why a device's folders aren't there, when it isn't just connecting.
    private var remoteProblem: [String: String] = [:]
    @ObservationIgnored private var asking: Set<String> = []
    /// (path, in a new worktree)
    @ObservationIgnored var onOpen: ((String, Bool) -> Void)?
    @ObservationIgnored var onDismiss: (() -> Void)?
    /// Opens a tab that signs in to the device.
    @ObservationIgnored var onSignIn: ((String) -> Void)?

    init(workspace: Workspace) {
        self.workspace = workspace
        let roots = FolderSources.roots
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let z = FolderSources.zoxide()
            let r = FolderSources.repos(roots: roots)
            DispatchQueue.main.async {
                FolderSources.cachedZoxide = z
                FolderSources.cachedRepos = r
                self?.zoxide = z
                self?.repos = r
            }
        }
    }

    struct Section: Identifiable {
        var id: String { title }
        let title: String
        let items: [FolderCandidate]
    }

    /// With no query: open folders, then recent ones, then repositories. Typing ranks
    /// them all by match; a path (/, ~, .) lists what's there instead.
    var sections: [Section] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if let (host, rest) = FolderSources.deviceQuery(q) {
            return deviceSections(host, rest)
        }
        if q.hasPrefix("/") || q.hasPrefix("~") || q.hasPrefix(".") {
            return [Section(title: "", items: pathMatches(q))]
        }
        let all = candidates
        if q.isEmpty {
            let open = all.filter { $0.source == .open }
            // Dot-folders (configs, other tools' worktrees) stay findable by typing, not suggested.
            let recent = Array(all.filter { $0.source == .recent && !$0.path.contains("/.") }.prefix(6))
            let repoLabel = FolderSources.roots.map { abbreviateHome(Workspace.normalize($0)) }.joined(separator: ", ")
            let repos = Array(all.filter { $0.source == .repo }.prefix(max(3, 10 - open.count - recent.count)))
            let devices = Prefs.deviceList.map {
                FolderCandidate(path: $0 + ":", source: .device, note: DeviceCenter.shared.statuses[$0]?.summary ?? "")
            }
            return [Section(title: "Open in tern", items: open),
                    Section(title: "Recent", items: recent),
                    Section(title: "Repositories in \(repoLabel)", items: repos),
                    Section(title: "Devices", items: devices)].filter { !$0.items.isEmpty }
        }
        let ranked = all.enumerated().compactMap { i, c -> (FolderCandidate, Int, Int)? in
            let scores = [matchScore(c.name, q), matchScore(abbreviateHome(c.path), q).map { $0 + 4 }].compactMap { $0 }
            return scores.min().map { (c, $0, i) }
        }
        .sorted { ($0.1, $0.2) < ($1.1, $1.2) }
        .prefix(40)
        .map(\.0)
        return [Section(title: "", items: Array(ranked))]
    }

    var results: [FolderCandidate] { sections.flatMap(\.items) }

    /// Every source, deduplicated, in source order: open folders, tern's recents
    /// (newest first), zoxide (by score), then repositories.
    private var candidates: [FolderCandidate] {
        var seen = Set<String>()
        var out: [FolderCandidate] = []
        func add(_ c: FolderCandidate) {
            guard seen.insert(c.path).inserted else { return }
            out.append(c)
        }
        let now = Date()
        for p in workspace.orderedProjects {
            add(FolderCandidate(path: p.path, source: .open, note: "\(p.tabs.count) tab\(p.tabs.count == 1 ? "" : "s")"))
        }
        for (path, date) in workspace.recents.sorted(by: { $0.value > $1.value })
        where FolderLocation(path).host != nil || FolderSources.isDirectory(path) {
            add(FolderCandidate(path: path, source: .recent, note: Self.ago(date, now: now)))
        }
        for z in zoxide where z.path != NSHomeDirectory() && FolderSources.isDirectory(z.path) {
            add(FolderCandidate(path: z.path, source: .recent))
        }
        for r in repos { add(FolderCandidate(path: r, source: .repo)) }
        return out
    }

    /// Directories at a typed path: the path itself if it exists, then what's in it
    /// whose name starts with the last component.
    private func pathMatches(_ q: String) -> [FolderCandidate] {
        let base = workspace.currentProject?.path ?? NSHomeDirectory()
        let expanded = q.hasPrefix(".") ? base + "/" + q : (q as NSString).expandingTildeInPath
        let dir: String, prefix: String
        if q.hasSuffix("/") {
            dir = expanded
            prefix = ""
        } else {
            dir = (expanded as NSString).deletingLastPathComponent
            prefix = (expanded as NSString).lastPathComponent.lowercased()
        }
        var out: [FolderCandidate] = []
        if !q.hasSuffix("/"), FolderSources.isDirectory(expanded) {
            out.append(FolderCandidate(path: Workspace.normalize(expanded), source: .path))
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Workspace.normalize(dir))) ?? []
        let dirPath = Workspace.normalize(dir)
        for name in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
        where name.lowercased().hasPrefix(prefix) && (prefix.hasPrefix(".") || !name.hasPrefix(".")) {
            let path = (dirPath == "/" ? "" : dirPath) + "/" + name
            guard FolderSources.isDirectory(path), !out.contains(where: { $0.path == path }) else { continue }
            out.append(FolderCandidate(path: path, source: .path))
            if out.count >= 40 { break }
        }
        return out
    }

    // MARK: Devices

    /// `host:` alone: the device's open, recent and repository folders. `host:name` ranks them;
    /// `host:/path` and `host:~/path` list what's there.
    private func deviceSections(_ host: String, _ rest: String) -> [Section] {
        if rest.hasPrefix("/") || rest.hasPrefix("~") {
            return [Section(title: "", items: remotePathMatches(host, rest))].filter { !$0.items.isEmpty }
        }
        let open = workspace.orderedProjects.filter { $0.host == host }.map {
            FolderCandidate(path: $0.path, source: .open, note: "\($0.tabs.count) tab\($0.tabs.count == 1 ? "" : "s")")
        }
        let found = remote[host]
        let known = Set(open.map(\.path))
        let recent = (found?.recent ?? []).map { FolderCandidate(path: "\(host):\($0)", source: .recent) }.filter { !known.contains($0.path) }
        let repos = (found?.repos ?? []).map { FolderCandidate(path: "\(host):\($0)", source: .repo) }.filter { !known.contains($0.path) }
        if rest.isEmpty {
            return [Section(title: "Open on \(host)", items: open),
                    Section(title: "Recent on \(host)", items: Array(recent.prefix(8))),
                    Section(title: "Repositories on \(host)", items: repos)].filter { !$0.items.isEmpty }
        }
        var seen = Set<String>()
        let ranked = (open + recent + repos).filter { seen.insert($0.path).inserted }.enumerated().compactMap { i, c -> (FolderCandidate, Int, Int)? in
            let scores = [matchScore(c.name, rest), matchScore(c.location.shortPath, rest).map { $0 + 4 }].compactMap { $0 }
            return scores.min().map { (c, $0, i) }
        }
        .sorted { ($0.1, $0.2) < ($1.1, $1.2) }
        .prefix(40)
        .map(\.0)
        return [Section(title: "", items: Array(ranked))].filter { !$0.items.isEmpty }
    }

    private func remotePathMatches(_ host: String, _ rest: String) -> [FolderCandidate] {
        let (dir, prefix) = FolderSources.splitRemotePath(rest)
        guard let listing = remoteDirs["\(host):\(dir)"], listing.ok else { return [] }
        let base = listing.path == "/" ? "" : listing.path
        var out: [FolderCandidate] = []
        // The folder typed so far is itself a choice: `host:~` opens home.
        if prefix.isEmpty, !rest.hasSuffix("/") || rest == "/" {
            out.append(FolderCandidate(path: "\(host):\(listing.path)", source: .path))
        }
        let lower = prefix.lowercased()
        let names = listing.dirs.filter { $0.lowercased().hasPrefix(lower) && (lower.hasPrefix(".") || !$0.hasPrefix(".")) }
        // An exact name first, so ↩ opens what was typed.
        let exact = names.filter { $0.lowercased() == lower }
        let others = names.filter { $0.lowercased() != lower }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for name in (exact + others).prefix(40) {
            out.append(FolderCandidate(path: "\(host):\(base)/\(name)", source: .path))
        }
        return out
    }

    /// What to say instead of results while a device's folders aren't there.
    var deviceMessage: String? {
        guard let (host, rest) = FolderSources.deviceQuery(query.trimmingCharacters(in: .whitespaces)) else { return nil }
        let status = DeviceCenter.shared.statuses[host] ?? .stopped
        if status.needsSignIn { return "\(host) needs you to sign in. Press ↩ to sign in in a new tab." }
        if let problem = remoteProblem[host] { return problem }
        if !status.connected { return status.state == "installing" ? "Installing tern on \(host)…" : "Connecting to \(host)…" }
        if rest.hasPrefix("/") || rest.hasPrefix("~") {
            let (dir, _) = FolderSources.splitRemotePath(rest)
            if let listing = remoteDirs["\(host):\(dir)"], !listing.ok { return listing.error ?? "Can't list \(dir) on \(host)." }
            return remoteDirs["\(host):\(dir)"] == nil ? "Listing \(dir) on \(host)…" : nil
        }
        return remote[host] == nil ? "Finding folders on \(host)…" : nil
    }

    /// Asks the device in the query for what the picker needs, starting its link first.
    private func askDevice() {
        guard let (host, rest) = FolderSources.deviceQuery(query.trimmingCharacters(in: .whitespaces)) else { return }
        DeviceCenter.shared.ensure(host)
        if rest.hasPrefix("/") || rest.hasPrefix("~") {
            let dir = FolderSources.splitRemotePath(rest).dir
            fetch("\(host):\(dir)", host: host) { TernClient.listDirs(host: host, path: dir) } done: { [weak self] in self?.remoteDirs["\(host):\(dir)"] = $0 }
        } else {
            let roots = FolderSources.roots
            fetch(host, host: host) { TernClient.folders(host: host, roots: roots) } done: { [weak self] in
                FolderSources.cachedRemote[host] = $0
                self?.remote[host] = $0
            }
        }
    }

    /// Runs `ask` off the main thread once the device is connected, giving up after a minute or
    /// when its link reports a problem only the user can fix.
    private func fetch<T: Sendable>(_ key: String, host: String, _ ask: @escaping @Sendable () -> T?, done: @escaping @MainActor @Sendable (T) -> Void) {
        guard !asking.contains(key) else { return }
        asking.insert(key)
        remoteProblem[host] = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let deadline = Date().addingTimeInterval(60)
            var result: T?, problem: String?
            while result == nil, problem == nil, Date() < deadline {
                let status = DeviceStatus.read(host)
                if status.connected { result = ask() }
                if result == nil {
                    if status.failed && !status.needsSignIn { problem = status.summary }
                    Thread.sleep(forTimeInterval: 0.3)
                }
            }
            let answer = result, failure = problem ?? (result == nil ? "\(host) didn't answer." : nil)
            DispatchQueue.main.async {
                guard let self else { return }
                self.asking.remove(key)
                if let answer { done(answer) }
                if let failure, !(DeviceCenter.shared.statuses[host]?.needsSignIn ?? false) { self.remoteProblem[host] = failure }
            }
        }
    }

    private func matchScore(_ text: String, _ q: String) -> Int? {
        let t = text.lowercased(), q = q.lowercased()
        if t == q { return 0 }
        if t.hasPrefix(q) { return 1 }
        if t.contains("/" + q) || t.contains("-" + q) || t.contains("_" + q) { return 2 }
        if t.contains(q) { return 3 }
        var it = t.makeIterator()
        for c in q {
            var found = false
            while let n = it.next() { if n == c { found = true; break } }
            if !found { return nil }
        }
        return 4
    }

    static func ago(_ date: Date, now: Date) -> String {
        let age = relativeAge(date, now: now)
        return age == "now" ? "just now" : "\(age) ago"
    }

    func move(_ delta: Int) {
        let n = results.count
        guard n > 0 else { return }
        selection = (selection + delta + n) % n
    }

    /// ⇥: fills in the selected folder's path, to open something inside it.
    func complete() {
        let r = results
        guard r.indices.contains(selection) else { return }
        let item = r[selection]
        if item.source == .device { query = item.path; return }
        query = item.location.label + (item.location.path == "/" ? "" : "/")
    }

    func submit(worktree: Bool) {
        let r = results
        if r.isEmpty, let (host, _) = FolderSources.deviceQuery(query.trimmingCharacters(in: .whitespaces)),
           DeviceCenter.shared.statuses[host]?.needsSignIn == true {
            return onSignIn?(host) ?? ()
        }
        guard r.indices.contains(selection) else { return NSSound.beep() }
        // A device lists its folders rather than opening.
        if r[selection].source == .device { query = r[selection].path; return }
        onOpen?(r[selection].path, worktree)
    }
}

struct FolderPickerView: View {
    @Bindable var model: FolderPickerModel
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.25)
                .contentShape(Rectangle())
                .onTapGesture { model.onDismiss?() }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    TextField("Open a folder: name, path, or device:path", text: $model.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($focused)
                        .onSubmit { model.submit(worktree: false) }
                        .onKeyPress(.downArrow) { model.move(1); return .handled }
                        .onKeyPress(.upArrow) { model.move(-1); return .handled }
                        .onKeyPress(.tab) { model.complete(); return .handled }
                        .onKeyPress(.escape) { model.onDismiss?(); return .handled }
                        .onExitCommand { model.onDismiss?() }
                }
                .padding(.horizontal, 16)
                .frame(height: 48)

                Rectangle().fill(Palette.border).frame(height: 1)

                let sections = model.sections
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(sections) { section in
                                if !section.title.isEmpty {
                                    Text(section.title)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 14)
                                        .padding(.top, 10)
                                        .padding(.bottom, 4)
                                }
                                let start = sections.prefix { $0.id != section.id }.reduce(0) { $0 + $1.items.count }
                                ForEach(Array(section.items.enumerated()), id: \.element.id) { offset, item in
                                    FolderRow(item: item, selected: start + offset == model.selection)
                                        .id(start + offset)
                                        .onTapGesture {
                                            model.selection = start + offset
                                            model.submit(worktree: false)
                                        }
                                }
                            }
                            if let message = model.deviceMessage, sections.isEmpty {
                                Text(message)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .padding(16)
                            } else if sections.isEmpty {
                                Text(model.query.isEmpty ? "No folders yet. Type a path, or press \(ShortcutRegistry.label("folder.browse")) to browse."
                                                         : "No matching folders")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .padding(16)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .frame(maxHeight: 420)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: model.selection) { _, i in proxy.scrollTo(i) }
                }

                Rectangle().fill(Palette.border).frame(height: 1)

                HStack(spacing: 14) {
                    KeyHint(key: "↩", label: "Open")
                    // Any of Zoom Pane's keys does this while the picker is up; the last is ⌘↩ by default.
                    // Worktrees are made on this Mac, so not for a device's folders.
                    if FolderSources.deviceQuery(model.query) == nil {
                        KeyHint(key: ShortcutRegistry.bindings["pane.zoom"]?.last?.label ?? "", label: "Open in a new worktree")
                    }
                    KeyHint(key: "⇥", label: "Complete path")
                    Spacer()
                    KeyHint(key: ShortcutRegistry.label("folder.browse"), label: "Browse…")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
            }
            .frame(width: 600)
            .background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border))
            .themedText()
            .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
            .padding(.top, 80)
        }
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

private struct FolderRow: View {
    let item: FolderCandidate
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(item.name)
                .font(.system(size: 13.5, weight: .semibold))
                .lineLimit(1)
                .layoutPriority(1)
            Text(item.place)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 8)
            if item.location.host == nil, let branch = Worktree.headBranch(at: item.path) {
                Chip(text: branch)
            }
            if !item.note.isEmpty {
                Text(item.source == .open ? "\(item.note) · jump" : item.note)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(selected ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }
}

private struct KeyHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10.5))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Palette.chip, in: RoundedRectangle(cornerRadius: 4))
            Text(label)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
    }
}

/// A small grey label: a branch, a worktree.
struct Chip: View {
    let text: String

    var body: some View {
        // Long branch names keep their start and end; the chip never squeezes the name beside it.
        let shown = text.count > 26 ? text.prefix(12) + "…" + text.suffix(12) : Substring(text)
        Text(shown)
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Palette.chip, in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
            .help(text)
    }
}
