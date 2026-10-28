import AppKit
import SwiftUI

/// The strip above the panes: where this session is (folder › name, branch), then its state
/// in a capsule. What runs in each pane and where is on the pane's own header.
struct ContentHeader: View {
    let workspace: Workspace
    let layout: HeaderLayout
    @AppStorage(Prefs.workingIndicator) private var indicator = WorkingIndicator.trailing
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 6) {
                if SecureKeyboard.shared.enabled { Image(systemName: "lock.fill").help("Secure Keyboard Entry is enabled").accessibilityLabel("Secure Keyboard Entry enabled") }
                if let tab = workspace.selectedTab {
                    let s = workspace.sessions[tab.focusedPane]
                    if let folder = workspace.project(containing: tab.id)?.name {
                        Text(folder).foregroundStyle(.tertiary).lineLimit(1)
                        Text("›").foregroundStyle(.tertiary).opacity(0.6)
                    }
                    Text(workspace.title(for: tab))
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let remote = workspace.remote(for: tab.focusedPane) {
                        HeaderChip(text: remote.host + ":" + remote.directory, symbol: "network")
                    } else if let branch = s?.branch {
                        HeaderChip(text: branch, symbol: "arrow.triangle.branch")
                    }
                    if s?.agent == nil, let code = s?.exitCode {
                        Text("last exit \(code)" + (s?.durationMs.map { String(format: " · %.1fs", Double($0) / 1000) } ?? ""))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(code == 0 ? Color.secondary : Color.red)
                    }
                    Spacer(minLength: 12)
                    // Only what needs saying: an agent at work or waiting, with how long. An idle
                    // shell says nothing; the sidebar already shows every tab's age.
                    let status = workspace.status(for: tab, now: context.date)
                    let agent = workspace.agent(for: tab)
                    if status == .needsYou, let message = workspace.agentMessage(tab) {
                        Text(message)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if status == .needsYou || (status == .working && agent != nil) {
                        StatusCapsule(status: status, agent: agent, since: workspace.stateSince(tab),
                                      now: context.date, indicator: indicator)
                            .id(status)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.92).combined(with: .opacity))
                    }
                } else {
                    Spacer()
                }
            }
            .animation(Motion.animation(), value: workspace.selectedTab.map { workspace.status(for: $0, now: context.date) })
            .font(.system(size: 12.5))
            .padding(.leading, 10 + layout.leadingInset)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .themedText()
        }
    }
}

/// The branch (or remote host) beside the title.
private struct HeaderChip: View {
    let text: String
    let symbol: String

    var body: some View {
        Label {
            Text(text).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: symbol).font(.system(size: 9.5, weight: .medium))
        }
        .labelStyle(ChipLabelStyle())
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Palette.chip, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct ChipLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon; configuration.title }
    }
}

/// "Codex working · 4m" with the sidebar's glyph: amber-tinted when it needs you, a quiet chip
/// while it works.
private struct StatusCapsule: View {
    let status: SessionStatus
    let agent: String?
    let since: Date?
    let now: Date
    let indicator: WorkingIndicator

    var body: some View {
        let needsYou = status == .needsYou
        let label = agent.map { "\(agentName($0)) \(status.label.lowercased())" } ?? status.label
        HStack(spacing: 7) {
            StatusIcon(status: status, agent: agent, turning: indicator == .turning)
            Text([label, relativeAge(since, now: now)].filter { !$0.isEmpty && $0 != "now" }.joined(separator: " · "))
                .font(.system(size: 11.5, weight: needsYou ? .medium : .regular).monospacedDigit())
                .foregroundStyle(needsYou ? Palette.amber : Palette.text2)
                .lineLimit(1)
            if status == .working, indicator == .trailing {
                Spinner(color: Palette.working).frame(width: 12, height: 12)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: 24)
        .background(needsYou ? Palette.amber.opacity(0.16) : Palette.chip, in: Capsule())
        .fixedSize()
    }
}

/// Window geometry the SwiftUI parts follow.
@Observable
final class HeaderLayout {
    /// Room the header leaves on its left for the traffic lights when the sidebar is hidden.
    var leadingInset: CGFloat = 0
    /// The titlebar's height, which the sidebar starts below (zero in full screen).
    var titlebarHeight: CGFloat = 38
}

/// Lets the header act as titlebar: drag moves the window, double-click zooms.
final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.performZoom(nil)
        } else {
            window?.performDrag(with: event)
        }
    }
}
