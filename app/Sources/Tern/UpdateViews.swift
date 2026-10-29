import SwiftUI

/// The sidebar's one place for updates: a row each for tern, ternd, Claude Code and Codex
/// when there's something to say. The most urgent row is drawn in full; the rest follow as
/// one line each with their main action. Amber outlines the card while the top row needs you.
struct UpdateCard: View {
    let center: UpdateCenter

    var body: some View {
        let entries = center.entries
        if let top = entries.first {
            VStack(alignment: .leading, spacing: 8) {
                UpdateRow(entry: top, center: center)
                if entries.count > 1 {
                    Rectangle().fill(Palette.border).frame(height: 1)
                    ForEach(entries.dropFirst()) { UpdateLine(entry: $0, center: center) }
                }
            }
            .padding(10)
            .background(Palette.hover, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                if top.needsYou {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.amber.opacity(0.55), lineWidth: 1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            .animation(Motion.animation(), value: entries)
        }
    }
}

private struct UpdateRow: View {
    let entry: UpdateEntry
    let center: UpdateCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 9) {
                UpdateTile(entry: entry)
                VStack(alignment: .leading, spacing: 2) {
                    // No vertical fixedSize: the window's minimum-size pass measures the sidebar at
                    // almost no width, where a long wrapped line would make the window grow.
                    Text(entry.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.text)
                        .lineLimit(2)
                    if let detail = entry.detail { UpdateDetail(entry: entry, detail: detail) }
                    if let note = entry.note {
                        Text(note).font(.system(size: 11)).foregroundStyle(Palette.amber).lineLimit(3)
                    }
                }
                .frame(minHeight: 22, alignment: entry.detail == nil ? .center : .top)
                Spacer(minLength: 0)
                if !entry.menu.isEmpty {
                    UpdateMenu(entry: entry, center: center)
                } else if let action = entry.trailing {
                    UpdateIconButton(action: action, center: center)
                }
            }
            if !entry.chips.isEmpty || entry.quote != nil || entry.tone == .progress || !entry.actions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if !entry.chips.isEmpty {
                        ChipFlow(spacing: 4) {
                            ForEach(entry.chips, id: \.self) { program in
                                Text(program)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(Palette.text)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Palette.chip, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            }
                        }
                    }
                    if let quote = entry.quote {
                        Text(quote)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.terminal, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.border, lineWidth: 1) }
                            .help(quote)
                    }
                    if entry.tone == .progress { UpdateProgressBar() }
                    if !entry.actions.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(Array(entry.actions.enumerated()), id: \.offset) { index, action in
                                Button(action.label) { center.perform(action, entry: entry) }
                                    .buttonStyle(UpdateButtonStyle(kind: index == 0 ? .primary : action.quiet ? .quiet : .secondary))
                                    .help(UpdateHelp.text(action, center: center))
                            }
                        }
                    }
                }
                .padding(.leading, 31)
            }
        }
        .transition(.opacity)
    }
}

/// A row after the first: its glyph, title and main action on one line.
private struct UpdateLine: View {
    let entry: UpdateEntry
    let center: UpdateCenter

    var body: some View {
        HStack(spacing: 8) {
            UpdateTile(entry: entry, size: 18).padding(.horizontal, 2)
            Text(entry.title)
                .font(.system(size: 11))
                .foregroundStyle(Palette.text2)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if let action = entry.actions.first {
                Button(action.label) { center.perform(action, entry: entry) }
                    .buttonStyle(UpdateButtonStyle(kind: .quiet))
                    .help(UpdateHelp.text(action, center: center))
            } else if let action = entry.trailing {
                UpdateIconButton(action: action, center: center)
            }
        }
        .transition(.opacity)
    }
}

/// The detail line; a running row counts its seconds.
private struct UpdateDetail: View {
    let entry: UpdateEntry
    let detail: String

    var body: some View {
        if let started = entry.started, entry.tone == .progress {
            // One line: the command gives way, the clock doesn't.
            TimelineView(.periodic(from: started, by: 1)) { context in
                HStack(spacing: 0) {
                    text(detail, lines: 1)
                    text(" · \(UpdateRunner.duration(context.date.timeIntervalSince(started)))").fixedSize()
                }
            }
        } else {
            text(detail)
        }
    }

    private func text(_ string: String, lines: Int = 3) -> some View {
        Text(string)
            .font(entry.detailIsCode ? .system(size: 11, design: .monospaced) : .system(size: 11))
            .foregroundStyle(Palette.text3)
            .lineLimit(lines)
            .truncationMode(.middle)
    }
}

/// The source's mark in a rounded tile, or the row's state when that matters more.
private struct UpdateTile: View {
    let entry: UpdateEntry
    var size: CGFloat = 22

    var body: some View {
        glyph
            .frame(width: size, height: size)
            .background(Palette.chip, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }

    @ViewBuilder private var glyph: some View {
        let symbol = Font.system(size: size * 0.5, weight: .medium)
        switch entry.tone {
        case .waiting:
            Circle().fill(Palette.amber).frame(width: size * 0.36, height: size * 0.36)
        case .warning, .failure:
            Image(systemName: "exclamationmark.triangle").font(symbol).foregroundStyle(Palette.amber)
        case .success:
            Image(systemName: "checkmark").font(symbol).foregroundStyle(Palette.text2)
        case .scheduled:
            Image(systemName: "clock").font(symbol).foregroundStyle(Palette.working)
        case .normal, .progress:
            switch entry.source {
            case .claude, .codex:
                AgentGlyph(agent: entry.source.rawValue, color: Palette.text2).frame(width: size * 0.55, height: size * 0.55)
            case .app: Image(systemName: "arrow.down").font(symbol).foregroundStyle(Palette.text2)
            case .daemon: Image(systemName: "server.rack").font(symbol).foregroundStyle(Palette.text2)
            }
        }
    }
}

/// Release notes, Remind Me Tomorrow and Skip This Version.
private struct UpdateMenu: View {
    let entry: UpdateEntry
    let center: UpdateCenter

    var body: some View {
        Menu {
            ForEach(Array(entry.menu.enumerated()), id: \.offset) { _, action in
                Button(action == .remindTomorrow ? "Remind Me Tomorrow" : action.label) { center.perform(action, entry: entry) }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(Palette.text3)
        .frame(width: 20, height: 20)
        .help("More")
    }
}

private struct UpdateIconButton: View {
    let action: UpdateAction
    let center: UpdateCenter

    var body: some View {
        Button { center.perform(action) } label: {
            Image(systemName: "terminal")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.text3)
        .help(UpdateHelp.text(action, center: center))
        .accessibilityLabel("Show Output")
    }
}

private enum UpdateHelp {
    static func text(_ action: UpdateAction, center: UpdateCenter) -> String {
        switch action {
        case .downloadApp: "Download and verify the release"
        case .installApp: "Install and relaunch tern. Running programs stay in ternd."
        case .whatsNew: "Release notes in Settings › Updates"
        case .restartDaemon, .restartDaemonNow: "Restart ternd now"
        case .restartDaemonWhenIdle: "Restart ternd once nothing is running"
        case .cancelIdleRestart: "Don't restart ternd"
        case .runAgent(let agent), .retryAgent(let agent):
            "Runs `\(center.agents.versions[agent]?.updateCommand ?? "")` in the background"
        case .answer: "Open the updater's terminal to answer it"
        case .showOutput: "Show the updater's terminal"
        case .closeRun: "Close this row"
        case .remindTomorrow: "Hide this version for a day"
        case .skipVersion: "Don't offer this version again"
        }
    }
}

/// The card's buttons: the main action filled, others quieter.
struct UpdateButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, kind == .quiet ? 6 : 9)
            .frame(height: 22)
            .foregroundStyle(kind == .primary ? Palette.terminal : kind == .quiet ? Palette.text2 : Palette.text)
            .background(background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }

    private var background: Color {
        switch kind {
        case .primary: Palette.text
        case .secondary: Palette.selection
        case .quiet: .clear
        }
    }
}

/// Updaters don't report progress, so the bar sweeps; it holds still when motion is reduced.
private struct UpdateProgressBar: View {
    @State private var sweep = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            Capsule().fill(Palette.selection)
                .overlay(alignment: .leading) {
                    Capsule().fill(Palette.working)
                        .frame(width: width * 0.34)
                        .offset(x: Motion.reduced ? width * 0.33 : sweep ? width : -width * 0.34)
                }
                .clipShape(Capsule())
        }
        .frame(height: 3)
        .onAppear {
            guard !Motion.reduced else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) { sweep = true }
        }
    }
}

/// Lays chips out in rows, wrapping when the next one doesn't fit.
private struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for (index, size) in row.items {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [(Int, CGSize)] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for (index, subview) in subviews.enumerated() {
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width { rows.append(Row()) }
            let gap = rows[rows.count - 1].items.isEmpty ? 0 : spacing
            rows[rows.count - 1].items.append((index, size))
            rows[rows.count - 1].width += gap + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}

// MARK: Console

/// The update console's header: which updater, its command and state, and Hide or Stop.
struct UpdateConsoleHeader: View {
    let runner: UpdateRunner
    let agent: String

    var body: some View {
        let run = runner.runs[agent]
        let name = UpdateSource(rawValue: agent)?.name ?? agent
        HStack(spacing: 9) {
            AgentGlyph(agent: agent, color: Palette.text2)
                .frame(width: 12, height: 12)
                .frame(width: 22, height: 22)
                .background(Palette.chip, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(run?.phase == .running ? "Updating \(name)" : name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.text)
                .fixedSize()
            Text(run?.command ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.text3)
                .lineLimit(1)
                .truncationMode(.middle)
            if let run { UpdateStatusChip(run: run).fixedSize() }
            Spacer(minLength: 8)
            switch run?.phase {
            case .running?:
                Button("Stop") { runner.stop(agent) }
                    .buttonStyle(UpdateButtonStyle(kind: .quiet))
                    .help("End the updater. \(name) may be left half updated.")
                Button("Hide") { runner.hide(agent) }
                    .buttonStyle(UpdateButtonStyle(kind: .secondary))
                    .help("The update carries on; the sidebar shows how it goes.")
            case .failed?:
                Button("Copy Output") { runner.copyOutput(agent) }
                    .buttonStyle(UpdateButtonStyle(kind: .quiet))
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Palette.sidebar)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.border).frame(height: 1) }
    }
}

/// After a failure: how it ended, Close and Retry. Nothing otherwise.
struct UpdateConsoleFooter: View {
    let runner: UpdateRunner
    let agent: String

    var body: some View {
        if let run = runner.runs[agent], run.phase == .failed {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.amber)
                Text(run.code.map { "Exited with \($0) after \(UpdateRunner.duration(run.elapsed))" } ?? "Stopped before it finished")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.text)
                Spacer(minLength: 8)
                Button("Close") { runner.close(agent) }
                    .buttonStyle(UpdateButtonStyle(kind: .quiet))
                Button("Retry") { runner.start(agent: agent, command: run.command) }
                    .buttonStyle(UpdateButtonStyle(kind: .primary))
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Palette.sidebar)
            .overlay(alignment: .top) { Rectangle().fill(Palette.border).frame(height: 1) }
        }
    }
}

private struct UpdateStatusChip: View {
    let run: UpdateRunner.Run

    var body: some View {
        let (text, color): (String, Color) = switch run.phase {
        case .running: run.waiting ? ("Needs an answer", Palette.amber) : ("Running", Palette.working)
        case .failed: ("Failed", Palette.amber)
        case .succeeded: ("Done", Palette.text2)
        }
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Palette.chip, in: Capsule())
    }
}

// MARK: Settings

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
                VersionRow(symbol: "arrow.down.circle", name: "tern", version: AppUpdates.currentVersion,
                           status: app.status, state: appState) {
                    switch app.phase {
                    case .ready: Button("Restart to Update") { center.perform(.installApp) }
                    case .idle where app.release != nil, .failed where app.release != nil:
                        Button("Download") { center.perform(.downloadApp) }
                    default: if app.busy { ProgressView().controlSize(.small) }
                    }
                }
                VersionRow(symbol: "server.rack", name: "ternd", version: center.daemon?.version ?? "–",
                           status: daemonStatus, state: daemonState) {
                    if center.restartWhenIdle {
                        Button("Cancel") { center.perform(.cancelIdleRestart) }
                    } else if center.daemon?.running == true, center.daemon?.current == false {
                        if !center.busy.isEmpty {
                            Button("When Idle") { center.perform(.restartDaemonWhenIdle) }.disabled(center.restartingDaemon)
                        }
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
                Toggle(isOn: $downloadAppUpdates) {
                    Text("Download updates in the background")
                    Text("Checked against its checksum and Developer ID signature before it's offered.")
                }
                Toggle(isOn: $installOnQuit) {
                    Text("Install downloaded updates when tern quits")
                    Text("Sessions keep running in ternd.")
                }
                Toggle("Include alpha prereleases", isOn: $includePrereleases)
                    .onChange(of: includePrereleases) { center.app.check(interactive: false) }
            }
            Section("Agents") {
                Toggle(isOn: $offerAgentUpdates) {
                    Text("Offer Claude Code and Codex updates")
                    Text("They run out of sight; the console opens if one needs you or fails.")
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

    private var appState: VersionState {
        switch center.app.phase {
        case .checking, .downloading, .installing: .working
        case .ready: .offer
        case .failed: .attention
        case .idle: center.app.release == nil ? .current : .offer
        }
    }

    private var daemonState: VersionState {
        guard let daemon = center.daemon, daemon.running else { return .current }
        if center.restartingDaemon || center.restartWhenIdle { return .working }
        if daemon.current { return .current }
        return daemon.compatible ? .offer : .attention
    }

    private var daemonStatus: String {
        guard let daemon = center.daemon else { return "Checking…" }
        if !daemon.running { return "Not running." }
        if center.restartingDaemon { return "Restarting…" }
        if daemon.current { return "Up to date." }
        if center.restartWhenIdle { return "Restarts when \(BusySessions.summary(center.busy)) \(center.busy.count == 1 ? "ends" : "end")." }
        let cost = center.busy.isEmpty ? "Nothing is running, so nothing ends." : "Restarting now ends \(BusySessions.summary(center.busy))."
        return (daemon.compatible ? "A newer build is installed. " : "Older than this tern; restart it soon. ") + cost
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
            if run?.phase == .running { return run?.waiting == true ? "Waiting for an answer." : "Updating…" }
            return version.behind ? "\(version.latest ?? "") is available." : "Up to date."
        }()
        let state: VersionState = run?.phase == .running ? (run?.waiting == true ? .attention : .working)
            : version?.behind == true ? .offer : .current
        VersionRow(agent: agent, name: name, version: version?.installed ?? "–", status: status, note: version?.shadowWarning, state: state) {
            if run?.phase == .running {
                Button("Show Output") { center.perform(.showOutput(agent)) }
            } else if let version, version.behind {
                Button("Update") { center.runAgent(agent) }.help("Runs `\(version.updateCommand)` in the background")
            }
        }
    }
}

/// A version's state, as its dot shows it: amber needs you, blue is under way.
private enum VersionState {
    case current, offer, working, attention

    var color: Color {
        switch self {
        case .current: Color.secondary.opacity(0.5)
        case .offer: Color.primary
        case .working: Palette.working
        case .attention: Palette.amber
        }
    }
}

private struct VersionRow<Trailing: View>: View {
    var symbol: String? = nil
    var agent: String? = nil
    let name: String
    let version: String
    let status: String
    var note: String? = nil
    let state: VersionState
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let agent {
                    AgentGlyph(agent: agent, color: .secondary).frame(width: 14, height: 14)
                } else if let symbol {
                    Image(systemName: symbol).foregroundStyle(.secondary)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name)
                    Text(version).foregroundStyle(.secondary).font(.body.monospacedDigit())
                }
                HStack(spacing: 6) {
                    Circle().fill(state.color).frame(width: 6, height: 6)
                    Text(status).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if let note {
                    Text(note).font(.caption).foregroundStyle(Palette.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            trailing()
        }
    }
}
