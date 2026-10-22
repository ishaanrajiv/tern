import AppKit
import SwiftUI

/// A folder the picker can open.
struct FolderCandidate: Identifiable, Equatable {
    enum Source: Int { case open, recent, repo, path }

    var id: String { path }
    let path: String
    let source: Source
    /// "4 tabs", "2h ago".
    var note = ""

    var name: String {
        path == NSHomeDirectory() ? "Home" : (path as NSString).lastPathComponent
    }
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
}

/// The ⌘N picker's state. The controller owns it so menu shortcuts that reach the
/// window first (⌘↩, ⌘O) can still act on it.
@Observable
final class FolderPickerModel {
    var query = "" { didSet { if query != oldValue { selection = 0 } } }
    var selection = 0
    private var zoxide = FolderSources.cachedZoxide
    private var repos = FolderSources.cachedRepos
    private let workspace: Workspace
    /// (path, in a new worktree)
    @ObservationIgnored var onOpen: ((String, Bool) -> Void)?
    @ObservationIgnored var onDismiss: (() -> Void)?

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
            return [Section(title: "Open in tern", items: open),
                    Section(title: "Recent", items: recent),
                    Section(title: "Repositories in \(repoLabel)", items: repos)].filter { !$0.items.isEmpty }
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
        for (path, date) in workspace.recents.sorted(by: { $0.value > $1.value }) where FolderSources.isDirectory(path) {
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
        query = abbreviateHome(r[selection].path) + "/"
    }

    func submit(worktree: Bool) {
        let r = results
        guard r.indices.contains(selection) else { return NSSound.beep() }
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
                    TextField("Open a folder: name or path", text: $model.query)
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
                            if sections.isEmpty {
                                Text(model.query.isEmpty ? "No folders yet. Type a path, or press ⌘O to browse."
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
                    KeyHint(key: "⌘↩", label: "Open in a new worktree")
                    KeyHint(key: "⇥", label: "Complete path")
                    Spacer()
                    KeyHint(key: "⌘O", label: "Browse…")
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
            Text(abbreviateHome(item.path))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 8)
            if let branch = Worktree.headBranch(at: item.path) {
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
