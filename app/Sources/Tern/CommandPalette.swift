import AppKit
import SwiftUI

struct PaletteItem: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let shortcut: String
    let symbol: String
    let action: () -> Void
}

/// Ranks `items` by how well `query` matches their title: prefix, then word
/// start, then substring, then in-order subsequence.
func fuzzyFilter(_ items: [PaletteItem], _ query: String) -> [PaletteItem] {
    fuzzyRank(items, query, title: \.title, subtitle: \.subtitle)
}

/// `fuzzyFilter` for anything with a title, and a subtitle that counts for less.
func fuzzyRank<T>(_ items: [T], _ query: String, title: (T) -> String, subtitle: (T) -> String) -> [T] {
    let q = query.lowercased().trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return items }
    func score(_ text: String) -> Int? {
        let t = text.lowercased()
        if t.hasPrefix(q) { return 0 }
        if t.contains(" " + q) { return 1 }
        if t.contains(q) { return 2 }
        var it = t.makeIterator()
        for c in q {
            var found = false
            while let n = it.next() { if n == c { found = true; break } }
            if !found { return nil }
        }
        return 3
    }
    return items
        .compactMap { item in
            let s = [score(title(item)), score(subtitle(item)).map { $0 + 4 }].compactMap { $0 }.min()
            return s.map { (item, $0) }
        }
        .sorted { $0.1 < $1.1 }
        .map(\.0)
}

/// ⌘K's palette. Besides commands and sessions it has a settings mode, where ←/→ change the
/// selected value in place, and within that a theme list that previews each theme as you move.
struct CommandPaletteView: View {
    let items: [PaletteItem]
    let settings: [QuickSetting]
    let dismiss: () -> Void

    enum Mode: Equatable {
        case commands, settings
        /// Theme list; `original` comes back on Esc.
        case themes(original: String)
    }

    @State private var mode: Mode
    @State private var query = ""
    @State private var selection = 0
    /// Bumped on every change, so rows re-read values kept outside SwiftUI.
    @State private var revision = 0
    @State private var appeared = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(items: [PaletteItem], settings: [QuickSetting] = [], startInSettings: Bool = false, dismiss: @escaping () -> Void) {
        self.items = items
        self.settings = settings
        self.dismiss = dismiss
        _mode = State(initialValue: startInSettings ? .settings : .commands)
    }

    private var results: [PaletteItem] { fuzzyFilter(items, query) }
    private var settingResults: [QuickSetting] {
        fuzzyRank(settings, query, title: \.title, subtitle: \.section)
    }
    private var themeResults: [(id: String, name: String, theme: Theme?)] {
        fuzzyRank(QuickSetting.themes, query, title: \.name, subtitle: { _ in "" })
    }
    private var count: Int {
        switch mode {
        case .commands: results.count
        case .settings: settingResults.count
        case .themes: themeResults.count
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(appeared ? 0.12 : 0)
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    switch mode {
                    case .commands:
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    case .settings:
                        Crumb(parts: ["Settings"])
                    case .themes:
                        Crumb(parts: ["Settings", "Theme"])
                    }
                    TextField(prompt, text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($focused)
                        .onSubmit(submit)
                        // On the field itself: its editor would otherwise take arrows and Esc first.
                        .onKeyPress(.downArrow) { move(1); return .handled }
                        .onKeyPress(.upArrow) { move(-1); return .handled }
                        .onKeyPress(.leftArrow) { adjust(-1) ? .handled : .ignored }
                        .onKeyPress(.rightArrow) { adjust(1) ? .handled : .ignored }
                        .onKeyPress(.escape) { back(); return .handled }
                        .onExitCommand(perform: back)
                }
                .padding(.horizontal, 14)
                .frame(height: 46)

                Rectangle().fill(Palette.border).frame(height: 1)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            rows
                            if count == 0 {
                                Text("No matches").foregroundStyle(.secondary).padding(16)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 396)
                    .onChange(of: selection) { _, i in proxy.scrollTo(rowID(i)) }
                }

                if mode != .commands {
                    Rectangle().fill(Palette.border).frame(height: 1)
                    HStack(spacing: 14) {
                        Text("↑↓ move")
                        Text(mode == .settings ? "←→ change" : "previews as you move")
                        Text(mode == .settings ? "↩ toggle or open" : "↩ keep")
                        Spacer()
                        Text(mode == .settings ? "esc close" : "esc back")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                }
            }
            .frame(width: 600)
            .background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border))
            .themedText()
            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
            // Drops in from just above, settling into place.
            .scaleEffect(appeared || reduceMotion ? 1 : 0.98, anchor: .top)
            .offset(y: appeared || reduceMotion ? 0 : -10)
            .opacity(appeared ? 1 : 0)
            .padding(.top, 80)
        }
        .onAppear {
            withAnimation(Motion.animation(0.2)) { appeared = true }
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: query) { _, _ in selection = 0 }
        .onChange(of: selection) { _, _ in previewTheme() }
    }

    /// Scroll ids per mode: shared ones let the lazy list show one mode's rows in another.
    private func rowID(_ i: Int) -> String {
        switch mode {
        case .commands: "c\(i)"
        case .settings: "s\(i)"
        case .themes: "t\(i)"
        }
    }

    private var prompt: String {
        switch mode {
        case .commands: "Type a command or session name"
        case .settings: "Search settings"
        case .themes: "Search themes"
        }
    }

    @ViewBuilder private var rows: some View {
        switch mode {
        case .commands:
            ForEach(Array(results.enumerated()), id: \.element.id) { i, item in
                PaletteRow(item: item, selected: i == selection)
                    .id(rowID(i))
                    .onTapGesture {
                        selection = i
                        submit()
                    }
            }
        case .settings:
            let list = settingResults
            ForEach(Array(list.enumerated()), id: \.element.id) { i, setting in
                // Section headings only over the whole list; a search ranks across them.
                if query.isEmpty, i == 0 || list[i - 1].section != setting.section {
                    Text(setting.section)
                        .font(.system(size: 10.5, weight: .semibold))
                        .kerning(0.6)
                        .textCase(.uppercase)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.top, i == 0 ? 4 : 10)
                        .padding(.bottom, 3)
                }
                SettingRow(setting: setting, selected: i == selection, revision: revision) { delta in
                    selection = i
                    if setting.step(delta) { revision += 1 }
                }
                .id(rowID(i))
                .onTapGesture {
                    selection = i
                    submit()
                }
            }
        case .themes(let original):
            ForEach(Array(themeResults.enumerated()), id: \.element.id) { i, option in
                ThemeRow(name: option.name, theme: option.theme, current: option.id == original, selected: i == selection)
                    .id(rowID(i))
                    .onTapGesture {
                        selection = i
                        submit()
                    }
            }
        }
    }

    private func move(_ delta: Int) {
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    /// ←/→ on a value that steps. Elsewhere the arrows move the text cursor as usual.
    private func adjust(_ delta: Int) -> Bool {
        guard mode == .settings, settingResults.indices.contains(selection),
              settingResults[selection].step(delta) else { return false }
        revision += 1
        return true
    }

    private func submit() {
        switch mode {
        case .commands:
            let r = results
            guard r.indices.contains(selection) else { return }
            dismiss()
            r[selection].action()
        case .settings:
            let r = settingResults
            guard r.indices.contains(selection) else { return }
            let setting = r[selection]
            switch setting.control {
            case .toggle(let get, let set):
                set(!get())
                revision += 1
            case .choice, .stepper:
                if setting.step(1) { revision += 1 }
            case .themes:
                let current = ThemeStore.selectedID
                enter(.themes(original: current))
                selection = QuickSetting.themes.firstIndex { $0.id == current } ?? 0
            case .action(_, let run):
                dismiss()
                run()
            }
        case .themes:
            // The previewed theme stays.
            leaveThemes()
        }
    }

    /// Esc: out of the theme list (putting the theme back), else close.
    private func back() {
        if case .themes(let original) = mode {
            Prefs.defaults.set(original, forKey: Prefs.theme)
            leaveThemes()
        } else {
            dismiss()
        }
    }

    private func enter(_ next: Mode) {
        mode = next
        query = ""
        focused = true
    }

    private func leaveThemes() {
        enter(.settings)
        revision += 1
        selection = settings.firstIndex { if case .themes = $0.control { true } else { false } } ?? 0
    }

    private func previewTheme() {
        guard case .themes = mode, themeResults.indices.contains(selection) else { return }
        let id = themeResults[selection].id
        if ThemeStore.selectedID != id { Prefs.defaults.set(id, forKey: Prefs.theme) }
    }
}

/// "Settings › Theme": where in the palette you are.
private struct Crumb: View {
    let parts: [String]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                if i > 0 { Text("›").fontWeight(.regular).opacity(0.6) }
                Text(part)
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Palette.chip, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .fixedSize()
    }
}

private struct SettingRow: View {
    let setting: QuickSetting
    let selected: Bool
    /// Not shown: a new value makes the row read its setting again.
    let revision: Int
    let adjust: (Int) -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: setting.symbol)
                .font(.system(size: 12))
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(setting.title)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 8)
            Group {
                switch setting.control {
                case .choice:
                    stepping(less: "chevron.left", more: "chevron.right")
                case .stepper:
                    stepping(less: "minus", more: "plus")
                case .toggle(let get, _):
                    MiniSwitch(on: get())
                case .themes:
                    HStack(spacing: 6) {
                        Text(setting.valueLabel)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    }
                    .padding(.trailing, 6)
                case .action(let shortcut, _):
                    Text(shortcut).monospacedDigit().padding(.trailing, 6)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 32)
        .background(selected ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
    }

    private func stepping(less: String, more: String) -> some View {
        HStack(spacing: 2) {
            StepButton(symbol: less) { adjust(-1) }
            Text(setting.valueLabel)
                .monospacedDigit()
                .frame(minWidth: 72)
                // A new value slides in rather than snapping.
                .contentTransition(.numericText())
                .animation(Motion.animation(0.18), value: setting.valueLabel)
            StepButton(symbol: more) { adjust(1) }
        }
        // The arrows are for the row you're on; the value is always there.
        .environment(\.stepButtonsShown, selected)
    }
}

private struct StepButtonsShownKey: EnvironmentKey {
    static let defaultValue = true
}

private extension EnvironmentValues {
    var stepButtonsShown: Bool {
        get { self[StepButtonsShownKey.self] }
        set { self[StepButtonsShownKey.self] = newValue }
    }
}

private struct StepButton: View {
    let symbol: String
    let action: () -> Void
    @Environment(\.stepButtonsShown) private var shown
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 20, height: 22)
                .background(hovering ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
        .opacity(shown ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: shown)
        .onHover { hovering = $0 }
    }
}

/// A small switch in the theme's own greys: no accent colour.
private struct MiniSwitch: View {
    let on: Bool

    var body: some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule().fill(on ? Palette.text2 : Palette.chip)
            if !on { Capsule().strokeBorder(Palette.border) }
            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                .padding(2)
        }
        .frame(width: 30, height: 18)
        .padding(.trailing, 4)
        .animation(Motion.animation(0.2), value: on)
    }
}

private struct ThemeRow: View {
    let name: String
    let theme: Theme?
    let current: Bool
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let theme {
                    HStack(spacing: 3) {
                        ForEach([theme.sidebar, theme.terminal, theme.amber, theme.working], id: \.self) { color in
                            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color(nsColor: color)).frame(width: 12, height: 16)
                        }
                    }
                    .padding(2)
                    .background(Palette.border, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                } else {
                    Image(systemName: "terminal")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 61, height: 20)
                }
            }
            Text(name).font(.system(size: 13))
            if theme == nil {
                Text("from your Ghostty config").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            Spacer()
            if current {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 6)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(selected ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: item.symbol)
                .font(.system(size: 12))
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(item.title)
                .font(.system(size: 13))
                .lineLimit(1)
                .layoutPriority(1)
            if !item.subtitle.isEmpty {
                Text(item.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            Text(item.shortcut)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(selected ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
    }
}
