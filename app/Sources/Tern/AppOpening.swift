import AppKit

nonisolated struct AppOpenRequest: Codable, Sendable, Equatable {
    var directory: String
    var command: String?
    var split: String?
    var window = false

    /// External URLs can open directories, but cannot execute commands.
    static func from(url: URL) -> Self? {
        if url.isFileURL {
            return Self(directory: url.path)
        }
        guard url.scheme == "tern", url.host == "open", let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = parts.queryItems?.first(where: { $0.name == "path" })?.value, path.hasPrefix("/") else { return nil }
        return Self(directory: path, window: parts.queryItems?.contains(where: { $0.name == "window" && $0.value == "true" }) == true)
    }
}

/// The CLI queues complete JSON files atomically. Work stays off the UI thread;
/// each file is consumed once, and startup also drains requests from a cold launch.
final class AppOpenMonitor {
    private let source: DispatchSourceTimer
    init(receive: @escaping @MainActor @Sendable (AppOpenRequest) -> Void) {
        let directory = Workspace.layoutURL.deletingLastPathComponent().appendingPathComponent("open-requests")
        source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        source.setEventHandler { @Sendable in
            let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for file in files {
                // Refuse symlinks and unexpectedly large files, including before decoding.
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                      attributes[.type] as? FileAttributeType == .typeRegular,
                      (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 1 << 20 else { continue }
                let data = try? Data(contentsOf: file)
                try? FileManager.default.removeItem(at: file)
                guard let data, let request = try? JSONDecoder().decode(AppOpenRequest.self, from: data) else { continue }
                DispatchQueue.main.async { receive(request) }
            }
        }
        source.schedule(deadline: .now(), repeating: .milliseconds(250))
        source.resume()
    }
    deinit { source.cancel() }
}

extension MainWindowController {
    func open(_ request: AppOpenRequest) {
        var isDirectory: ObjCBool = false
        guard request.directory.hasPrefix("/"), FileManager.default.fileExists(atPath: request.directory, isDirectory: &isDirectory), isDirectory.boolValue,
              request.command?.contains("\0") != true, request.split == nil || ["right", "down"].contains(request.split!) else { return }
        if let split = request.split, workspace.selectedTab != nil {
            workspace.split(split == "down" ? .vertical : .horizontal, directory: request.directory, command: request.command)
        } else if let command = request.command {
            workspace.run(command, in: request.directory)
        } else {
            workspace.newTab(projectPath: request.directory, cwd: request.directory)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
