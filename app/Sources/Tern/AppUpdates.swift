import AppKit
import CryptoKit
import SwiftUI

nonisolated struct AppVersion: Comparable, Equatable, Sendable {
    let numbers: [Int]
    let prerelease: [String]
    init?(_ text: String) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let components = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3, components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              components.compactMap({ Int($0) }).count == 3 else { return nil }
        numbers = components.compactMap { Int($0) }
        prerelease = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
        if parts.count > 1 && (prerelease.isEmpty || !parts[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })) { return nil }
    }
    static func < (a: Self, b: Self) -> Bool {
        if a.numbers != b.numbers { return a.numbers.lexicographicallyPrecedes(b.numbers) }
        if a.prerelease.isEmpty { return false }
        if b.prerelease.isEmpty { return true }
        for (left, right) in zip(a.prerelease, b.prerelease) where left != right {
            if let l = Int(left), let r = Int(right) { return l < r }
            if Int(left) != nil { return true }
            if Int(right) != nil { return false }
            return left < right
        }
        return a.prerelease.count < b.prerelease.count
    }
}

nonisolated struct AppRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable { let name: String; let browser_download_url: URL; let size: Int }
    let tag_name: String
    let html_url: URL
    let body: String?
    let draft: Bool
    let assets: [Asset]
    var version: AppVersion? { AppVersion(tag_name) }
    var archiveName: String { "Tern-\(tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name)-macos-arm64.zip" }
    var archive: Asset? { assets.first { $0.name == archiveName } }
    var checksum: Asset? { assets.first { $0.name == archiveName + ".sha256" } }
}

nonisolated enum UpdateError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): text } }
}

/// Validate the central directory before extraction. Distribution bundles contain
/// no symlinks; refusing them also prevents an archive from extracting through one.
nonisolated enum UpdateArchive {
    static func validate(_ data: Data) throws {
        func number(_ offset: Int, _ bytes: Int) throws -> UInt64 {
            guard offset >= 0, offset + bytes <= data.count else { throw UpdateError.message("Incomplete update archive.") }
            return (0..<bytes).reduce(0) { $0 | (UInt64(data[offset + $1]) << ($1 * 8)) }
        }
        guard data.count >= 22 else { throw UpdateError.message("Invalid update archive.") }
        var end: Int?
        for i in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
            if try number(i, 4) == 0x06054b50, i + 22 + Int(try number(i + 20, 2)) == data.count { end = i; break }
        }
        guard let end, try number(end + 4, 2) == 0, try number(end + 6, 2) == 0 else { throw UpdateError.message("Unsupported update archive.") }
        let count = Int(try number(end + 10, 2))
        guard count > 0, count < 65535 else { throw UpdateError.message("Unsupported update archive size.") }
        var offset = Int(try number(end + 16, 4)), total: UInt64 = 0
        let directoryStart = offset
        guard end - directoryStart == Int(try number(end + 12, 4)), try number(end + 8, 2) == UInt64(count) else { throw UpdateError.message("Invalid archive directory bounds.") }
        var paths = Set<String>()
        for _ in 0..<count {
            guard try number(offset, 4) == 0x02014b50 else { throw UpdateError.message("Invalid archive directory.") }
            let flags = try number(offset + 8, 2), size = try number(offset + 24, 4)
            let length = Int(try number(offset + 28, 2))
            let extra = Int(try number(offset + 30, 2)), comment = Int(try number(offset + 32, 2))
            let mode = (try number(offset + 38, 4)) >> 16
            guard offset + 46 + length <= end, let path = String(data: data[(offset + 46)..<(offset + 46 + length)], encoding: .utf8),
                  !path.hasPrefix("/"), !path.contains("\\"), !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }),
                  path.hasPrefix("Tern.app/") || path.hasPrefix("__MACOSX/") || path == "Tern.app",
                  mode & 0xf000 != 0xa000, flags & 1 == 0, size < 512 << 20 else {
                throw UpdateError.message("The update archive contains an unsafe or unsupported entry.")
            }
            let key = path.precomposedStringWithCanonicalMapping.lowercased()
            guard paths.insert(key).inserted else { throw UpdateError.message("The update archive contains duplicate paths.") }
            let local = Int(try number(offset + 42, 4))
            guard try number(local, 4) == 0x04034b50 else { throw UpdateError.message("Invalid local archive header.") }
            let localName = Int(try number(local + 26, 2)), localExtra = Int(try number(local + 28, 2))
            let compressed = Int(try number(offset + 20, 4))
            guard local + 30 + localName + localExtra + compressed <= directoryStart,
                  try number(local + 6, 2) == flags,
                  data[(local + 30)..<(local + 30 + localName)] == data[(offset + 46)..<(offset + 46 + length)] else { throw UpdateError.message("The archive's file headers do not agree.") }
            total += size
            guard total <= 1 << 30 else { throw UpdateError.message("The extracted update is too large.") }
            offset += 46 + length + extra + comment
        }
        guard offset == end else { throw UpdateError.message("Invalid archive directory length.") }
    }
}

nonisolated enum UpdateInstaller {
    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw UpdateError.message(text.isEmpty ? "Update verification failed." : text) }
        return text
    }
    static func trustedAsset(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.path.hasPrefix("/ishaanrajiv/tern/releases/download/")
    }
    static func team(_ bundle: URL) throws -> String {
        let info = try run("/usr/bin/codesign", ["-dv", "--verbose=4", bundle.path])
        guard let line = info.components(separatedBy: "\n").first(where: { $0.hasPrefix("TeamIdentifier=") }) else { throw UpdateError.message("This copy of tern has no signing team. Install a signed release manually first.") }
        let team = String(line.dropFirst("TeamIdentifier=".count))
        guard !team.isEmpty, team != "not set", team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw UpdateError.message("This copy of tern has no signing team. Install a signed release manually first.") }
        return team
    }
    static func stage(_ release: AppRelease, current: URL, directory: URL) async throws -> URL {
        guard let archive = release.archive, let checksum = release.checksum,
              trustedAsset(archive.browser_download_url), trustedAsset(checksum.browser_download_url),
              archive.size > 0, archive.size <= 512 << 20, checksum.size <= 4096 else { throw UpdateError.message("No supported Apple Silicon update assets were found.") }
        let signingTeam = try team(current)
        let session = URLSession(configuration: .ephemeral)
        let (expectedData, response) = try await session.data(from: checksum.browser_download_url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, expectedData.count <= 4096,
              let expected = String(data: expectedData, encoding: .utf8)?.split(whereSeparator: \.isWhitespace).first,
              expected.count == 64, expected.allSatisfy(\.isHexDigit) else { throw UpdateError.message("The release checksum is invalid.") }
        let (download, archiveResponse) = try await session.download(from: archive.browser_download_url)
        defer { try? FileManager.default.removeItem(at: download) }
        guard (archiveResponse as? HTTPURLResponse)?.statusCode == 200,
              (try download.resourceValues(forKeys: [.fileSizeKey]).fileSize) == archive.size else { throw UpdateError.message("The update download is incomplete.") }
        let bytes = try Data(contentsOf: download, options: .mappedIfSafe)
        let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard actual == expected.lowercased() else { throw UpdateError.message("The update checksum does not match.") }
        try UpdateArchive.validate(bytes)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = try run("/usr/bin/ditto", ["-x", "-k", download.path, directory.path])
        let bundle = directory.appendingPathComponent("Tern.app")
        let info = try Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        guard let plist = try PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == "dev.tern.Tern",
              let version = plist["CFBundleShortVersionString"] as? String, AppVersion(version) == release.version else { throw UpdateError.message("The downloaded application does not match this release.") }
        let requirement = "anchor apple generic and identifier \"dev.tern.Tern\" and certificate leaf[subject.OU] = \"\(signingTeam)\""
        _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", requirement, bundle.path])
        _ = try run("/usr/sbin/spctl", ["--assess", "--type", "execute", bundle.path])
        return bundle
    }

    static func install(staged: URL, current: URL, runtime: URL, pid: Int32) throws {
        guard ProcessInfo.processInfo.environment["TERN_RUNTIME_DIR"] == nil else { throw UpdateError.message("Installing updates is disabled in a private test instance.") }
        guard FileManager.default.isWritableFile(atPath: current.deletingLastPathComponent().path) else { throw UpdateError.message("Move tern to a writable Applications folder before installing updates.") }
        let script = runtime.appendingPathComponent("install-update-" + UUID().uuidString + ".sh")
        // All paths arrive as positional parameters. The old app remains as a backup
        // until replacement succeeds. launchd owns the helper while this app exits.
        let source = #"""
        #!/bin/sh
        set -eu
        target=$1
        staged=$2
        oldpid=$3
        temporary="${target%.app}.update-$$.app"
        backup="${target%.app}.previous-$$.app"
        tries=0
        while kill -0 "$oldpid" 2>/dev/null; do
            tries=$((tries + 1))
            [ "$tries" -lt 300 ] || exit 1
            sleep 0.2
        done
        /usr/bin/ditto "$staged" "$temporary"
        /usr/bin/codesign --verify --deep --strict "$temporary"
        /bin/mv "$target" "$backup"
        if /bin/mv "$temporary" "$target"; then
            /usr/bin/open "$target"
            /bin/rm -rf "$backup"
        else
            /bin/mv "$backup" "$target"
            /usr/bin/open "$target"
            exit 1
        fi
        /bin/rm -f "$0"
        """#
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        _ = try run("/bin/launchctl", ["submit", "-l", "dev.tern.update." + UUID().uuidString, "--", "/bin/sh", script.path, current.path, staged.path, String(pid)])
    }
}

@Observable final class AppUpdates {
    static let shared = AppUpdates()
    var release: AppRelease?
    var staged: URL?
    var busy = false
    var message = "Check for signed Apple Silicon releases, including alpha prereleases."
    var notes: String { release?.body ?? "" }
    func check() {
        guard !busy else { return }
        busy = true; staged = nil; message = "Checking GitHub releases…"
        Task {
            defer { busy = false }
            do {
                var request = URLRequest(url: URL(string: "https://api.github.com/repos/ishaanrajiv/tern/releases?per_page=20")!)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("tern", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 30
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.message("GitHub could not return the releases. Try again later.") }
                let releases = try JSONDecoder().decode([AppRelease].self, from: data)
                let current = AppVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0")!
                let newest = releases.filter { !$0.draft && $0.version != nil && $0.archive != nil && $0.checksum != nil }.max { $0.version! < $1.version! }
                if let newest, newest.version! > current { release = newest; message = "\(newest.tag_name) is available." }
                else { release = nil; message = "You have the newest supported release." }
            } catch { message = error.localizedDescription }
        }
    }
    func download() {
        guard !busy, let release else { return }
        busy = true; staged = nil; message = "Downloading and verifying the update…"
        let current = Bundle.main.bundleURL
        let directory = Workspace.layoutURL.deletingLastPathComponent().appendingPathComponent("updates/" + UUID().uuidString)
        Task {
            defer { busy = false }
            do {
                staged = try await Task.detached(priority: .userInitiated) { try await UpdateInstaller.stage(release, current: current, directory: directory) }.value
                message = "Verified and ready. Installing relaunches tern. Running terminal processes stay in ternd."
            } catch { message = error.localizedDescription }
        }
    }
    func install() {
        guard !busy, let staged else { return }
        let alert = NSAlert()
        alert.messageText = "Install the verified update and relaunch tern?"
        alert.informativeText = "Your layout will be saved. The daemon and its running processes stay alive. If a daemon upgrade is required, tern will ask separately."
        alert.addButton(withTitle: "Install and Relaunch"); alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = true
        let current = Bundle.main.bundleURL, runtime = Workspace.layoutURL.deletingLastPathComponent(), pid = ProcessInfo.processInfo.processIdentifier
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try UpdateInstaller.install(staged: staged, current: current, runtime: runtime, pid: pid)
                DispatchQueue.main.async { NSApp.terminate(nil) }
            } catch { let text = error.localizedDescription; DispatchQueue.main.async { self.message = text; self.busy = false } }
        }
    }
}

struct AppUpdatesView: View {
    @State private var updates = AppUpdates.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(updates.message).textSelection(.enabled)
            HStack {
                Button("Check for Updates") { updates.check() }.disabled(updates.busy)
                if updates.release != nil { Button("Download and Verify") { updates.download() }.disabled(updates.busy) }
                if updates.staged != nil { Button("Install and Relaunch…") { updates.install() }.disabled(updates.busy) }
                if updates.busy { ProgressView().controlSize(.small) }
            }
            if let release = updates.release { Link("View release on GitHub", destination: release.html_url) }
            ScrollView { Text(updates.notes).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }.padding(20).frame(minWidth: 680, minHeight: 440)
    }
}
