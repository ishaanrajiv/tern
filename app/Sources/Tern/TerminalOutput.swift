import AppKit
import SwiftUI

nonisolated struct TerminalOutput: Decodable, Sendable {
    let ok: Bool
    let text: String?
    let truncated: Bool?
    let error: String?
}

nonisolated struct OutputSource: Sendable {
    let id: String
    let title: String
}

nonisolated struct OutputMatch: Identifiable, Sendable {
    var id: String { source.id + ":" + String(line) }
    let source: OutputSource
    let line: Int
    let text: String
}

nonisolated enum OutputMatcher {
    static func matches(_ text: String, source: OutputSource, query: String, regex: Bool, caseSensitive: Bool) throws -> [OutputMatch] {
        guard !query.isEmpty else { return [] }
        let expression = try NSRegularExpression(pattern: regex ? query : NSRegularExpression.escapedPattern(for: query), options: caseSensitive ? [] : [.caseInsensitive])
        return text.components(separatedBy: "\n").enumerated().compactMap { index, line in
            let range = NSRange(line.startIndex..., in: line)
            return expression.firstMatch(in: line, range: range) == nil ? nil : OutputMatch(source: source, line: index + 1, text: String(line.prefix(1000)))
        }
    }
}

@Observable final class OutputSearchModel {
    var query = ""
    var regex = false
    var caseSensitive = false
    var results: [OutputMatch] = []
    var message = "Search retained output, including detached sessions."
    private var generation = 0
    private var searchTask: Task<Void, Never>?

    func search(_ sources: [OutputSource]) {
        searchTask?.cancel()
        generation += 1
        let revision = generation, query = query, regex = regex, caseSensitive = caseSensitive
        results = []
        guard !query.isEmpty else { message = "Enter text to search."; return }
        message = "Searching…"
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                var matches: [OutputMatch] = []
                var unavailable = 0, truncated = false
                for source in sources {
                    guard !Task.isCancelled else { return }
                    guard let output = TernClient.output(source.id), output.ok, let text = output.text else { unavailable += 1; continue }
                    truncated = truncated || output.truncated == true
                    matches += try OutputMatcher.matches(text, source: source, query: query, regex: regex, caseSensitive: caseSensitive)
                    if matches.count >= 2000 { matches = Array(matches.prefix(2000)); truncated = true; break }
                }
                let found = matches, missing = unavailable, limited = truncated
                DispatchQueue.main.async {
                    guard let self, self.generation == revision else { return }
                    self.results = found
                    self.message = "\(found.count) matching lines" + (limited ? ". Results limited." : "") + (missing > 0 ? ". \(missing) sessions unavailable." : "")
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    guard let self, self.generation == revision else { return }
                    self.message = message
                }
            }
        }
    }
}

struct OutputSearchView: View {
    let sources: [OutputSource]
    let select: (OutputMatch) -> Void
    @State private var model = OutputSearchModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Search terminal output", text: $model.query).onSubmit { model.search(sources) }
                Button("Search") { model.search(sources) }.keyboardShortcut(.return)
            }
            HStack {
                Toggle("Regular expression", isOn: $model.regex)
                Toggle("Match case", isOn: $model.caseSensitive)
            }
            Text(model.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            List(model.results) { match in
                Button { select(match) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(match.source.title) · line \(match.line)").font(.caption).foregroundStyle(.secondary)
                        Text(match.text).font(.system(.body, design: .monospaced)).lineLimit(2)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
            }
        }.padding(16).frame(minWidth: 680, minHeight: 460)
    }
}

/// Native, selectable output with macOS find, copy and export. A captured command's
/// output can be selected without disturbing the terminal's live cursor or input.
final class OutputDocumentController: NSWindowController {
    private let textView = NSTextView()
    private let text: String
    init(title: String, text: String, truncated: Bool) {
        self.text = text
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 560), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.identifier = NSUserInterfaceItemIdentifier("tern.output")
        window.title = title + (truncated ? " · truncated" : "")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        textView.isEditable = false
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = text
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel(title)
        scroll.documentView = textView
        let copy = NSButton(title: "Copy All", target: self, action: #selector(copyAll))
        let save = NSButton(title: "Save…", target: self, action: #selector(saveOutput))
        let editor = NSButton(title: "Open in Editor", target: self, action: #selector(openEditor))
        let buttons = NSStackView(views: [copy, save, editor])
        buttons.spacing = 8
        let stack = NSStackView(views: [scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -12),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        window.center()
        window.makeFirstResponder(textView)
        textView.selectAll(nil)
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
    func find(_ action: NSTextFinder.Action) {
        let sender = NSMenuItem(); sender.tag = action.rawValue
        textView.performTextFinderAction(sender)
    }
    @objc private func copyAll() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    @objc private func saveOutput() {
        guard let window else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "terminal-output.txt"
        panel.beginSheetModal(for: window) { [text] response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.global(qos: .utility).async {
                do { try text.write(to: url, atomically: true, encoding: .utf8) }
                catch { let message = error.localizedDescription; DispatchQueue.main.async { NSAlert(error: NSError(domain: "tern", code: 1, userInfo: [NSLocalizedDescriptionKey: message])).runModal() } }
            }
        }
    }
    @objc private func openEditor() {
        let url = Workspace.layoutURL.deletingLastPathComponent().appendingPathComponent("output-" + UUID().uuidString + ".txt")
        let text = text
        DispatchQueue.global(qos: .utility).async {
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                DispatchQueue.main.async { FileEditor.open(FileReference(path: url.path, line: nil, column: nil)) }
            } catch { NSLog("tern: couldn't export output: %@", error.localizedDescription) }
        }
    }
}

extension MainWindowController {
    func showOutput(lastCommand: Bool, copy: Bool = false) {
        guard let tab = workspace.selectedTab else { return }
        let pane = tab.focusedPane, title = workspace.title(for: tab)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let output = TernClient.output(pane, lastCommand: lastCommand)
            DispatchQueue.main.async {
                guard let self else { return }
                guard let output, output.ok, let text = output.text else {
                    let alert = NSAlert(); alert.messageText = "Output unavailable"
                    alert.informativeText = output?.error ?? "The session or compatible daemon is unavailable."
                    alert.runModal(); return
                }
                if copy { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                else {
                    let document = OutputDocumentController(title: title + (lastCommand ? " · last command" : " · scrollback"), text: text, truncated: output.truncated == true)
                    self.outputDocument = document
                    document.showWindow(nil)
                }
            }
        }
    }

    func searchOutput(all: Bool) {
        let panes = all ? workspace.sessions.keys.sorted() : workspace.selectedTab.map { [$0.focusedPane] } ?? []
        let sources = panes.map { id in
            OutputSource(id: id, title: workspace.allTabs.first(where: { $0.root.panes.contains(id) }).map { workspace.title(for: $0) } ?? workspace.sessions[id]?.command ?? id)
        }
        showWorkflow(title: all ? "Search All Terminal Output" : "Advanced Find", view: OutputSearchView(sources: sources) { [weak self] match in
            guard let self else { return }
            if let tab = self.workspace.allTabs.first(where: { $0.root.panes.contains(match.source.id) }) {
                self.workspace.select(tab.id)
                self.workspace.focus(pane: match.source.id)
            }
            self.showOutputForSession(match.source.id, title: match.source.title)
        })
    }

    private func showOutputForSession(_ id: String, title: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let output = TernClient.output(id)
            DispatchQueue.main.async {
                guard let self, let output, output.ok, let text = output.text else { return }
                let document = OutputDocumentController(title: title, text: text, truncated: output.truncated == true)
                self.outputDocument = document; document.showWindow(nil)
            }
        }
    }
}
