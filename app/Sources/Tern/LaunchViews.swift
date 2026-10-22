import AppKit
import SwiftUI

struct LaunchPresetsView: View {
    let workspace: Workspace
    @State private var file = LaunchPresetFile()
    @State private var draft: LaunchPreset
    @State private var error = ""
    @State private var readable = true
    let launch: () -> Void

    init(workspace: Workspace, launch: @escaping () -> Void) {
        self.workspace = workspace; self.launch = launch
        _draft = State(initialValue: workspace.capturePreset(name: workspace.currentProject?.name ?? "Project"))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Menu("Saved Presets") {
                    ForEach(file.presets) { preset in Button(preset.name) { draft = preset; error = "" } }
                }
                Button("Capture Current Project") { draft = workspace.capturePreset(name: workspace.currentProject?.name ?? "Project") }
                Spacer()
            }
            Form {
                TextField("Name", text: $draft.name)
                TextField("Project folder", text: $draft.project)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(draft.tabs.indices, id: \.self) { index in
                        GroupBox("Tab \(index + 1)") {
                            VStack(alignment: .leading) {
                                TextField("Tab name", text: Binding(get: { draft.tabs[index].name ?? "" }, set: { draft.tabs[index].name = $0.isEmpty ? nil : $0 }))
                                ForEach(draft.tabs[index].root.panes, id: \.self) { pane in
                                    if let value = draft.tabs[index].panes[pane] {
                                        Text("Pane \((draft.tabs[index].root.panes.firstIndex(of: pane) ?? 0) + 1)")
                                            .font(.caption).foregroundStyle(.secondary)
                                        LaunchPaneEditor(pane: Binding(get: { draft.tabs[index].panes[pane] ?? value }, set: { draft.tabs[index].panes[pane] = $0 })).id(draft.id + pane)
                                    }
                                }
                            }.padding(6)
                        }
                    }
                }
            }
            Text("Launch creates new sessions and runs the commands below. Presets are stored locally and may contain environment secrets.").font(.caption).foregroundStyle(.secondary)
            if !error.isEmpty { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Delete Preset") {
                    do { var next = file; next.presets.removeAll { $0.id == draft.id }; try next.save(); file = next } catch { self.error = error.localizedDescription }
                }.disabled(!readable || !file.presets.contains { $0.id == draft.id })
                Spacer()
                Button("Save Preset") {
                    do {
                        try draft.validate()
                        var next = file; next.presets.removeAll { $0.id == draft.id }; next.presets.append(draft)
                        try next.save(); file = next; error = ""
                    } catch { self.error = error.localizedDescription }
                }.disabled(!readable)
                Button("Launch") {
                    do { try workspace.launch(draft); launch() } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 640, height: 640)
        .onAppear { do { file = try LaunchPresetFile.load() } catch { readable = false; self.error = error.localizedDescription } }
    }
}

private struct LaunchPaneEditor: View {
    @Binding var pane: LaunchPane
    @State private var environment = ""
    @State private var environmentError = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Local folder", text: $pane.directory)
            TextField("Startup command, optional", text: $pane.command)
            TextField("Environment: KEY=value, one per line", text: $environment, axis: .vertical)
                .lineLimit(1...4)
                .onChange(of: environment) { _, text in
                    var values: [String: String] = [:]
                    for line in text.split(separator: "\n") {
                        let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                        guard pair.count == 2 else { environmentError = "Use KEY=value."; pane.environment = ["!invalid": ""]; return }
                        values[String(pair[0])] = String(pair[1])
                    }
                    environmentError = ""; pane.environment = values
                }
            if !environmentError.isEmpty { Text(environmentError).foregroundStyle(.red) }
            Toggle("Connect over SSH", isOn: Binding(get: { pane.remote != nil }, set: { pane.remote = $0 ? RemoteConnection() : nil }))
            if pane.remote != nil {
                RemoteFields(connection: Binding(get: { pane.remote ?? RemoteConnection() }, set: { pane.remote = $0 }))
            }
        }
        .onAppear { environment = pane.environment.keys.sorted().map { "\($0)=\(pane.environment[$0]!)" }.joined(separator: "\n") }
        .onChange(of: pane.environment) { _, value in
            if environmentError.isEmpty { environment = value.keys.sorted().map { "\($0)=\(value[$0]!)" }.joined(separator: "\n") }
        }
        .padding(.vertical, 6)
    }
}

struct RemoteFields: View {
    @Binding var connection: RemoteConnection
    var body: some View {
        TextField("SSH alias or user@host", text: $connection.host)
        TextField("Remote folder", text: $connection.directory)
        TextField("tmux session, optional", text: $connection.tmuxSession)
    }
}

struct RemoteSessionView: View {
    let workspace: Workspace
    let opened: () -> Void
    @State private var connection: RemoteConnection
    @State private var error = ""
    init(workspace: Workspace, opened: @escaping () -> Void) {
        self.workspace = workspace; self.opened = opened
        _connection = State(initialValue: workspace.selectedTab.flatMap { workspace.remote(for: $0.focusedPane) } ?? RemoteConnection())
    }
    var body: some View {
        Form {
            RemoteFields(connection: $connection)
            Text("Uses your SSH config, keys, agent, ports, and jump hosts. Passwords and host-key questions appear in the terminal. The host needs tmux when a session name is set.").font(.caption).foregroundStyle(.secondary)
            Text("To save this connection, capture its project in Launch Presets. Opening the same tmux session reconnects to it. Splitting a remote pane opens another SSH connection.").font(.caption).foregroundStyle(.secondary)
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            Button("Connect") { do { try workspace.openRemote(connection); opened() } catch { self.error = error.localizedDescription } }
                .keyboardShortcut(.defaultAction)
        }.padding(20).frame(width: 520)
    }
}
