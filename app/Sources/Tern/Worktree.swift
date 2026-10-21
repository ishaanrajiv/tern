import Foundation

/// Git worktrees for sessions, so parallel agents don't edit the same checkout.
/// A session's worktree lives next to the repository, in `<repo>-worktrees/<name>`,
/// on a new branch `tern/<name>` cut from the repository's current HEAD.
enum Worktree {
    struct Created {
        let path: String
        let branch: String
    }

    enum Failure: Error, CustomStringConvertible {
        case notARepo(String)
        case git(String)

        var description: String {
            switch self {
            case .notARepo(let dir): "\(abbreviateHome(dir)) is not in a git repository."
            case .git(let message): message
            }
        }
    }

    /// The main checkout for `dir`, even when `dir` is itself inside a worktree.
    static func mainRoot(of dir: String) -> String? {
        guard let common = try? git(["-C", dir, "rev-parse", "--path-format=absolute", "--git-common-dir"]) else { return nil }
        let url = URL(fileURLWithPath: common)
        // A bare or unusual layout: fall back to the work tree that contains dir.
        guard url.lastPathComponent == ".git" else { return try? git(["-C", dir, "rev-parse", "--show-toplevel"]) }
        return url.deletingLastPathComponent().path
    }

    static func create(from dir: String) -> Result<Created, Failure> {
        guard let root = mainRoot(of: dir) else { return .failure(.notARepo(dir)) }
        let repo = URL(fileURLWithPath: root)
        let parent = repo.deletingLastPathComponent().appendingPathComponent("\(repo.lastPathComponent)-worktrees")
        let branches = Set(((try? git(["-C", root, "branch", "--list", "tern/*", "--format=%(refname:short)"])) ?? "")
            .split(separator: "\n").map(String.init))
        let name = (1...).lazy.map { "session-\($0)" }.first { n in
            !branches.contains("tern/\(n)") && !FileManager.default.fileExists(atPath: parent.appendingPathComponent(n).path)
        }!
        let path = parent.appendingPathComponent(name).path
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            _ = try git(["-C", root, "worktree", "add", "-b", "tern/\(name)", path])
            return .success(Created(path: path, branch: "tern/\(name)"))
        } catch let e as Failure {
            return .failure(e)
        } catch {
            return .failure(.git(error.localizedDescription))
        }
    }

    /// Uncommitted or untracked files in the worktree, as `git status --short` lines.
    static func changes(in path: String) -> [String] {
        ((try? git(["-C", path, "status", "--porcelain"])) ?? "").split(separator: "\n").map(String.init)
    }

    static func branch(of path: String) -> String? {
        try? git(["-C", path, "symbolic-ref", "--short", "-q", "HEAD"])
    }

    /// Removes the worktree's directory and git's record of it. The branch stays.
    static func remove(_ path: String, force: Bool) -> Failure? {
        guard let root = mainRoot(of: path) else { return .notARepo(path) }
        do {
            try git(["-C", root, "worktree", "remove"] + (force ? ["--force"] : []) + [path])
            return nil
        } catch let e as Failure {
            return e
        } catch {
            return .git(error.localizedDescription)
        }
    }

    @discardableResult
    private static func git(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw Failure.git(String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Worktree {
    /// The checked-out branch at `path`, read from git's HEAD file (cheap enough for
    /// every redraw); nil outside a repository's top level or on a detached HEAD.
    static func headBranch(at path: String) -> String? {
        var gitDir = path + "/.git"
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitDir, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue {
            // A worktree: ".git" names its real git directory.
            guard let link = try? String(contentsOfFile: gitDir, encoding: .utf8),
                  link.hasPrefix("gitdir: ") else { return nil }
            let target = link.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDir = target.hasPrefix("/") ? target : path + "/" + target
        }
        guard let head = try? String(contentsOfFile: gitDir + "/HEAD", encoding: .utf8),
              head.hasPrefix("ref: refs/heads/") else { return nil }
        return head.dropFirst(16).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
