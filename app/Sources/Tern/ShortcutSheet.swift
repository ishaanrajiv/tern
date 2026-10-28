import SwiftUI

/// Help → Keyboard Shortcuts: every app shortcut as it's bound now, overrides included,
/// with a filter. Keys the terminal keeps (⌃ and ⌥ without ⌘) aren't app shortcuts, so
/// they aren't listed.
struct ShortcutSheet: View {
    let close: () -> Void
    @State private var query = ""
    @FocusState private var searching: Bool

    private var sections: [ShortcutRegistry.Section] {
        let all = ShortcutRegistry.cheatSheet(globalHotkey: UserDefaults.standard.bool(forKey: "globalHotkey"))
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.compactMap { section in
            let rows = section.rows.filter {
                $0.title.lowercased().contains(q) || section.category.rawValue.lowercased().contains(q)
                    || $0.keys.contains { $0.lowercased().contains(q) }
            }
            return rows.isEmpty ? nil : ShortcutRegistry.Section(category: section.category, rows: rows)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter shortcuts", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searching)
            }
            .padding(10)
            Divider()
            ScrollView {
                let sections = sections
                // Two columns, filled down then across, so each category stays together.
                let half = split(sections)
                HStack(alignment: .top, spacing: 28) {
                    column(half.left)
                    column(half.right)
                }
                .padding(20)
                if sections.isEmpty {
                    Text("No shortcuts match “\(query)”.").foregroundStyle(.secondary).padding(.bottom, 20)
                }
            }
            Divider()
            HStack {
                Text("Change any of these in Settings → Terminal → App shortcuts.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: close).keyboardShortcut(.cancelAction)
            }
            .padding(10)
        }
        .frame(width: 720, height: 600)
        .onAppear { searching = true }
    }

    private func column(_ sections: [ShortcutRegistry.Section]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(sections, id: \.category) { section in
                VStack(alignment: .leading, spacing: 5) {
                    Text(section.category.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .padding(.bottom, 2)
                    ForEach(section.rows, id: \.self) { row in
                        HStack(spacing: 8) {
                            Text(row.title).font(.system(size: 12.5)).lineLimit(1)
                            Spacer(minLength: 8)
                            ForEach(row.keys, id: \.self) { KeyCap(text: $0) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Splits whole sections into two columns of about the same height.
    private func split(_ sections: [ShortcutRegistry.Section]) -> (left: [ShortcutRegistry.Section], right: [ShortcutRegistry.Section]) {
        let height = { (section: ShortcutRegistry.Section) in section.rows.count + 2 }
        let total = sections.map(height).reduce(0, +)
        var count = 0
        let left = Array(sections.prefix { section in
            defer { count += height(section) }
            return count < total / 2
        })
        return (left, Array(sections.dropFirst(left.count)))
    }
}

private struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .fixedSize()
    }
}
