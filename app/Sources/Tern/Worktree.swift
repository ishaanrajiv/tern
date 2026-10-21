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
