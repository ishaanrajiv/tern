import SwiftUI

/// The sidebar's one place for updates: a row each for tern, ternd, Claude Code and Codex
/// when there's something to say. Two or more fold under "N updates", most urgent row first.
struct UpdateCard: View {
    let center: UpdateCenter
    @State private var expanded = false

    var body: some View {
        let entries = center.entries
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if entries.count > 1 {
                    Button { withAnimation(Motion.animation()) { expanded.toggle() } } label: {
                        HStack(spacing: 6) {
                            Text("\(entries.count) updates").font(.system(size: 11, weight: .semibold))
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(expanded ? "Show only the first" : "Show all")
                }
                ForEach(Array((expanded ? entries : Array(entries.prefix(1))).enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider().overlay(Palette.border) }
                    UpdateRow(entry: entry, center: center)
                }
            }
            .padding(10)
            .background(Palette.hover, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                if entries.first?.tone == .warning {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.amber.opacity(0.6), lineWidth: 1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }
}

private struct UpdateRow: View {
    let entry: UpdateEntry
    let center: UpdateCenter

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            UpdateGlyph(entry: entry).frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 4) {
                // No vertical fixedSize: the window's minimum-size pass measures the sidebar at
                // almost no width, where a long wrapped line would make the window grow.
                Text(entry.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                if let detail = entry.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
                if !entry.actions.isEmpty || entry.version != nil || entry.source == .app {
                    HStack(spacing: 10) {
                        ForEach(Array(entry.actions.enumerated()), id: \.offset) { index, action in
                            Button(action.label) { center.perform(action) }
                                .foregroundStyle(index == 0 ? Palette.text : Palette.text2)
                                .help(help(action))
                        }
                        if entry.version != nil || entry.source == .app { more }
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
            }
            Spacer(minLength: 0)
        }
        .transition(.opacity)
    }

    /// Release notes, Remind Me Tomorrow and Skip This Version.
    private var more: some View {
        Menu {
            if entry.source == .app { Button("Release Notes…") { center.openSettings?() } }
            if entry.version != nil {
                Button("Remind Me Tomorrow") { center.remindTomorrow(entry) }
                Button("Skip This Version") { center.skip(entry) }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(Palette.text2)
        .help("More")
    }

    private func help(_ action: UpdateAction) -> String {
        switch action {
        case .downloadApp: "Download and verify the release"
        case .installApp: "Install and relaunch tern. Running programs stay in ternd."
        case .restartDaemon, .restartDaemonNow: "Restart ternd now"
        case .restartDaemonWhenIdle: "Restart ternd once nothing is running"
        case .cancelIdleRestart: "Don't restart ternd"
        case .runAgent(let agent): "Runs `\(center.agents.versions[agent]?.updateCommand ?? "")` in the background"
        case .showOutput: "Show the updater's terminal"
        case .closeRun: "Close this row"
        }
    }
}

/// The source's mark, or the row's state when something is happening.
private struct UpdateGlyph: View {
    let entry: UpdateEntry

    var body: some View {
        switch entry.tone {
        case .progress:
            ProgressView().controlSize(.mini)
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.text2)
        case .failure, .warning:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.amber)
        case .normal:
            switch entry.source {
            case .claude, .codex: AgentGlyph(agent: entry.source.rawValue, color: Palette.text2)
            case .app: Image(systemName: "arrow.down.circle").foregroundStyle(Palette.text2)
            case .daemon: Image(systemName: "arrow.clockwise.circle").foregroundStyle(Palette.text2)
            }
        }
    }
}

/// Settings › Updates: every version in one place, and how tern keeps itself current.
struct UpdatesSettings: View {
    let center: UpdateCenter
    @AppStorage(Prefs.checkAppUpdates) private var checkAppUpdates = true
    @AppStorage(Prefs.downloadAppUpdates) private var downloadAppUpdates = true
    @AppStorage(Prefs.installAppUpdatesOnQuit) private var installOnQuit = true
    @AppStorage(Prefs.includePrereleases) private var includePrereleases = true
    @AppStorage(Prefs.offerAgentUpdates) private var offerAgentUpdates = true

    var body: some View {
        let app = center.app
        Form {
            Section("Versions") {
                VersionRow(name: "tern", version: AppUpdates.currentVersion, status: app.status) {
                    switch app.phase {
                    case .ready: Button("Restart to Update") { center.perform(.installApp) }
                    case .idle where app.release != nil, .failed where app.release != nil:
                        Button("Download") { center.perform(.downloadApp) }
                    default: if app.busy { ProgressView().controlSize(.small) }
                    }
                }
                VersionRow(name: "ternd", version: center.daemon?.version ?? "–", status: daemonStatus) {
                    if center.daemon?.running == true, center.daemon?.current == false {
                        Button("Restart") { center.perform(.restartDaemon) }.disabled(center.restartingDaemon)
                    }
                }
                ForEach(["claude", "codex"], id: \.self) { agent in agentRow(agent) }
            }
            if let release = app.release, !app.notes.isEmpty {
                Section("What's new in \(release.tag_name)") {
                    ScrollView {
                        Text(app.notes).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                    Link("View release on GitHub", destination: release.html_url).font(.caption)
                }
            }
            Section("tern") {
                Toggle("Check for updates automatically", isOn: $checkAppUpdates)
                Toggle("Download updates in the background", isOn: $downloadAppUpdates)
                    .help("Verified against its checksum and Developer ID signature before it's offered.")
                Toggle("Install downloaded updates when tern quits", isOn: $installOnQuit)
                    .help("Sessions keep running in ternd. Restart to Update installs it now.")
                Toggle("Include alpha prereleases", isOn: $includePrereleases)
                    .onChange(of: includePrereleases) { center.app.check(interactive: false) }
            }
            Section("Agents") {
                Toggle(isOn: $offerAgentUpdates) {
                    Text("Offer Claude Code and Codex updates")
                    Text("Updates run in the background. Their output opens if they need you or fail.")
                }
            }
            Section {
                HStack {
                    Text(checkedText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now") { center.checkAll() }.disabled(app.busy || center.agents.checking)
                }
            }
        }
        .settingsPane()
    }

    private var daemonStatus: String {
        guard let daemon = center.daemon else { return "Checking…" }
        if !daemon.running { return "Not running." }
        if daemon.current { return "Up to date." }
        return daemon.compatible ? "A newer build is installed. Restarting ends running programs." : "Older than this tern. Restart it soon."
    }

    private var checkedText: String {
        if center.agents.checking || center.app.phase == .checking { return "Checking for updates…" }
        let last = [center.app.lastChecked, center.agents.lastChecked].compactMap { $0 }.max()
        return last.map { "Checked at \($0.formatted(date: .omitted, time: .shortened))" } ?? "Updates not checked yet"
    }

    @ViewBuilder private func agentRow(_ agent: String) -> some View {
        let name = UpdateSource(rawValue: agent)!.name
        let version = center.agents.versions[agent]
        let run = center.runner.runs[agent]
        let status: String = {
            guard let version else { return center.agents.checking ? "Checking version…" : "Not found in PATH." }
            if run?.phase == .running { return "Updating…" }
            let line = version.behind ? "\(version.latest ?? "") is available." : "Up to date."
            return [line, version.shadowWarning].compactMap { $0 }.joined(separator: " ")
        }()
        VersionRow(name: name, version: version?.installed ?? "–", status: status) {
            if run?.phase == .running {
                Button("Show Output") { center.perform(.showOutput(agent)) }
            } else if let version, version.behind {
                Button("Update") { center.runAgent(agent) }.help("Runs `\(version.updateCommand)` in the background")
            }
        }
    }
}

private struct VersionRow<Trailing: View>: View {
    let name: String
    let version: String
    let status: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name)
                    Text(version).foregroundStyle(.secondary).monospacedDigit()
                }
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer()
            trailing()
        }
    }
}
