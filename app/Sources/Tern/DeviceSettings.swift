import AppKit
import SwiftUI

/// Settings → Devices: the machines whose folders tern offers, and how each is doing.
struct DeviceSettings: View {
    @AppStorage(Prefs.devices, store: Prefs.defaults) private var devicesText = ""
    @State private var newHost = ""

    var body: some View {
        let hosts = Prefs.parseRoots(devicesText).filter(Device.validHost)
        let typed = newHost.trimmingCharacters(in: .whitespaces)
        SettingsPage(pane: .devices, subtitle: "tern signs in with your SSH config, keys and agent, copies its own tern and ternd to ~/.local/share/tern on the device, and runs your sessions there, where they keep running when this Mac sleeps or quits tern. Type a device's name and a colon in \(ShortcutRegistry.label("folder.open")) to open its folders. Linux (x86_64 and ARM) and Apple Silicon Macs.") {
            SettingsSection {
                VStack(alignment: .leading, spacing: 10) {
                    SettingLabel(info: SettingsIndex["device"])
                    HStack(spacing: 8) {
                        TextField("", text: $newHost, prompt: Text("SSH alias or user@host"))
                            .fieldChrome(mono: true)
                            .onSubmit { add(typed, to: hosts) }
                        Button("Add") { add(typed, to: hosts) }
                            .buttonStyle(LitButtonStyle())
                            .disabled(!Device.validHost(typed) || hosts.contains(typed))
                    }
                    if !typed.isEmpty, !Device.validHost(typed) {
                        Text("Use a Host from ~/.ssh/config, or user@host. Ports, keys and jump hosts go in ~/.ssh/config.")
                            .font(.system(size: 11.5)).foregroundStyle(Palette.errorText)
                    }
                }
                .settingsRow(id: "device")
                ForEach(hosts, id: \.self) { host in
                    DeviceRow(host: host) { devicesText = Prefs.joinRoots(hosts.filter { $0 != host }) }
                        .settingsRow()
                }
            }
        }
    }

    private func add(_ host: String, to hosts: [String]) {
        guard Device.validHost(host), !hosts.contains(host) else { return }
        devicesText = Prefs.joinRoots(hosts + [host])
        newHost = ""
        DeviceCenter.shared.watch(DeviceCenter.shared.watched.union([host]))
    }
}

private struct DeviceRow: View {
    let host: String
    let remove: () -> Void
    @State private var hooks: [RemoteHooks]?
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        let status = DeviceCenter.shared.statuses[host] ?? .stopped
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: status.os == "Darwin" ? "laptopcomputer" : "server.rack")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(host).font(.system(size: 13, design: .monospaced))
                    Text(details(status))
                        .font(.system(size: 11.5)).foregroundStyle(status.failed ? Palette.errorText : .secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                Spacer()
                if status.needsSignIn {
                    Button("Sign In…") { DeviceCenter.shared.onSignIn?(host) }
                } else if status.state == "incompatible" || (status.connected && status.current == false) {
                    Button("Restart ternd…") { confirmRestart() }
                        .disabled(working)
                } else if !status.connected {
                    Button("Reconnect") { DeviceCenter.shared.reconnect(host) }
                }
                Button(action: remove) { Image(systemName: "minus").font(.system(size: 10, weight: .semibold)) }
                    .help("Remove \(host). Its folders stay in the sidebar until you close them.")
            }
            if status.connected {
                HStack(spacing: 8) {
                    Text(hooksSummary)
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Spacer()
                    if let hooks, hooks.contains(where: { $0.available && !$0.installed }) {
                        Button("Set Up Agent Hooks") { setUpHooks() }
                            .disabled(working)
                            .help("Lets Claude Code and Codex on \(host) report whether they're working or waiting for you.")
                    }
                }
            }
            if let problem {
                Text(problem).font(.system(size: 11.5)).foregroundStyle(Palette.errorText).textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
        .onAppear { DeviceCenter.shared.ensure(host); loadHooks() }
        .onChange(of: status.connected) { _, connected in if connected { loadHooks() } }
    }

    private func details(_ status: DeviceStatus) -> String {
        var parts = [status.summary]
        if let os = status.os, let arch = status.arch { parts.append(os == "Darwin" ? "macOS \(arch)" : "\(os) \(arch)") }
        if status.connected, let version = status.version { parts.append("ternd \(version)") }
        if status.failed, let message = status.message, !status.summary.contains(message) { parts.append(message) }
        return parts.joined(separator: " · ")
    }

    private var hooksSummary: String {
        guard let hooks else { return "Checking agent hooks…" }
        let names = ["claude": "Claude Code", "codex": "Codex"]
        let found = hooks.filter(\.available)
        if found.isEmpty { return "No Claude Code or Codex found on \(host)" }
        return found.map { "\(names[$0.agent] ?? $0.agent): \($0.installed ? "hooks set up" : "no hooks")" }.joined(separator: " · ")
    }

    private func loadHooks() {
        guard DeviceCenter.shared.statuses[host]?.connected == true else { return }
        let host = host
        DispatchQueue.global(qos: .userInitiated).async {
            let answer = TernClient.hooks(host: host, action: "status")
            DispatchQueue.main.async { if let answer { hooks = answer.agents } }
        }
    }

    private func setUpHooks() {
        working = true
        problem = nil
        let host = host, agents = (hooks ?? []).filter { $0.available && !$0.installed }.map(\.agent)
        DispatchQueue.global(qos: .userInitiated).async {
            var error: String?, latest: [RemoteHooks]?
            for agent in agents {
                guard let answer = TernClient.hooks(host: host, action: "install", agent: agent) else { error = "\(host) didn't answer."; break }
                if let e = answer.error { error = e }
            }
            latest = TernClient.hooks(host: host, action: "status")?.agents
            DispatchQueue.main.async {
                working = false
                problem = error
                if let latest { hooks = latest }
            }
        }
    }

    private func confirmRestart() {
        let alert = NSAlert()
        alert.messageText = "Restart ternd on \(host)?"
        alert.informativeText = "Restarting updates it to this version of tern. Programs running in its sessions end; their screens come back."
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        working = true
        problem = nil
        DeviceCenter.shared.restartDaemon(host) { error in
            working = false
            problem = error
        }
    }
}
