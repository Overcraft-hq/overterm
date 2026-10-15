import SwiftUI

/// Which theme a pick in the gallery sets: the one theme, or — when the
/// terminal follows macOS — its dark or its light half.
enum ThemeSlot: String, CaseIterable, Identifiable, Sendable {
    case dark, light

    var id: String { rawValue }

    /// The setting it writes. The single theme and the dark one are the
    /// same key: turning "follow macOS" off leaves the theme you had.
    var key: String {
        switch self {
        case .dark: "appearance.theme"
        case .light: "appearance.themeLight"
        }
    }

    var title: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        }
    }
}

/// Settings ▸ Themes: what the terminal looks like, as a gallery you pick
/// from rather than a list of 473 names in a menu.
///
/// Picking applies at once — the file, the Ghostty overrides, every open
/// terminal — because that is the only way to judge a theme. The chrome
/// around the terminal is drawn from the theme too, which is what each
/// card shows: the strip, a terminal, the ANSI colours.
struct ThemesSettings: View {
    @ObservedObject var model: SettingsPageModel
    @ObservedObject var settings: Settings
    @ObservedObject var catalog: ThemeCatalog
    let theme: ChromeTheme

    private var followsSystem: Bool { settings.value("appearance.followSystemAppearance")?.bool ?? false }
    private var slot: ThemeSlot { followsSystem ? model.themeSlot : .dark }
    private var chosen: String { settings.value(slot.key)?.string ?? "" }

    private var shown: [ThemeCatalog.Entry] {
        ThemeCatalog.filter(catalog.entries, search: model.themeSearch, showing: model.themeShowing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            current
            controls
            gallery
        }
        .onAppear { catalog.load() }
    }

    // MARK: What is on

    /// The theme in force, big: one, or the pair macOS switches between.
    private var current: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                if followsSystem {
                    ForEach(ThemeSlot.allCases) { slot in
                        slotCard(slot)
                    }
                } else {
                    slotCard(.dark)
                }
                Spacer(minLength: 0)
            }
            Toggle(isOn: follows) {
                Text("Follow macOS between a light and a dark theme")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.text)
            }
            .toggleStyle(.checkbox)
            Text(
                followsSystem
                    ? "Ghostty switches as the system does. Pick a slot above, then a theme below."
                    : "The terminal changes as you pick. The tab strip and the sidebar take the new colours when Overterm next opens."
            )
            .font(.system(size: 11))
            .foregroundStyle(theme.text3)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func slotCard(_ slot: ThemeSlot) -> some View {
        let name = settings.value(slot.key)?.string ?? ""
        let picked = catalog.theme(named: name)
        let isEditing = !followsSystem || model.themeSlot == slot
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let picked {
                    ThemePreview(theme: picked, scale: 1.25)
                        .frame(width: 200, height: 112)
                        .id(picked.name)
                        .transition(.opacity)
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.iconBg)
                        .frame(width: 200, height: 112)
                        .overlay(
                            Text(catalog.isLoaded ? "Your Ghostty config" : "…")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.text3)
                        )
                }
            }
            .animation(.easeInOut(duration: 0.35), value: name)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: isEditing && followsSystem ? 2 : 0)
                    .padding(-3)
            )
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isEditing)
            HStack(spacing: 6) {
                if followsSystem {
                    Text(slot.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.text2)
                }
                Text(verbatim: name.isEmpty ? "Default" : name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                if !name.isEmpty {
                    Button {
                        settings.set(slot.key, nil)
                    } label: {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.text3)
                    .help("Back to your Ghostty config's theme")
                }
            }
            .frame(width: 200, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.themeSlot = slot }
    }

    private var follows: Binding<Bool> {
        Binding(
            get: { followsSystem },
            set: { on in
                settings.set("appearance.followSystemAppearance", on ? .bool(true) : nil)
                if on { model.themeSlot = .dark }
            })
    }

    // MARK: Picking one

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(theme.text3)
                // A String, not a key: an interpolated count in a
                // LocalizedStringKey comes out as "473" in Turkish.
                TextField(searchPlaceholder, text: $model.themeSearch)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("themes.search")
            }
            .padding(.horizontal, 9)
            .frame(width: 240, height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(theme.rowSel))
            Picker("", selection: $model.themeShowing) {
                ForEach(ThemeCatalog.Showing.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Spacer()
            Text(verbatim: catalog.isLoaded ? "\(shown.count)" : "")
                .font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(theme.text3)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.2), value: shown.count)
        }
    }

    private var searchPlaceholder: String {
        guard catalog.isLoaded else { return "Search themes" }
        return model.themeShowing == .popular ? "Search the ten" : "Search \(catalog.entries.count) themes"
    }

    private var gallery: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 208, maximum: 280), spacing: 14)], alignment: .leading, spacing: 14) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                ThemeCard(
                    entry: entry, isSelected: entry.theme.name == chosen, index: index, theme: theme,
                    pick: { settings.set(slot.key, .string(entry.theme.name)) })
            }
        }
        .animation(.easeInOut(duration: 0.2), value: shown.count)
        .overlay(alignment: .top) {
            if !catalog.isLoaded {
                ProgressView().controlSize(.small).padding(.top, 40)
            } else if shown.isEmpty {
                // Nothing among the ten is the usual way to meet the other
                // 463: say how many there are and open them in one click.
                let elsewhere = ThemeCatalog.filter(catalog.entries, search: model.themeSearch, showing: .all).count
                VStack(spacing: 8) {
                    Text(verbatim: model.themeSearch.isEmpty ? "Nothing here" : "No match among the ten")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.text2)
                    if elsewhere > 0 {
                        Button("Search all \(catalog.entries.count) themes (\(elsewhere))") {
                            withAnimation(.easeInOut(duration: 0.25)) { model.themeShowing = .all }
                        }
                    }
                }
                .padding(.top, 40)
            }
        }
    }
}

/// One theme in the gallery: its preview, its name, and what it costs to
/// look at — nothing moves until the pointer is on it.
private struct ThemeCard: View {
    let entry: ThemeCatalog.Entry
    let isSelected: Bool
    let index: Int
    let theme: ChromeTheme
    let pick: () -> Void

    @State private var hovering = false
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ThemePreview(theme: entry.theme)
                .frame(height: 104)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0)
                        .padding(-2.5)
                )
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(5)
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    }
                }
                .shadow(color: .black.opacity(hovering ? 0.28 : 0), radius: hovering ? 10 : 0, y: hovering ? 4 : 0)
            HStack(spacing: 5) {
                Text(verbatim: entry.theme.name)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if entry.source == .user {
                    Text("Yours")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.accentText)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(theme.iconBg))
                }
                Spacer(minLength: 0)
            }
        }
        .scaleEffect(hovering ? 1.03 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: hovering)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isSelected)
        // Up into place as the row scrolls in — a stagger across the row, not
        // across 473 cards, so scrolling back is as lively as the first look.
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 8)
        .onAppear {
            guard !shown else { return }
            withAnimation(.easeOut(duration: 0.26).delay(Double(index % 9) * 0.03)) { shown = true }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: pick)
        .help(entry.theme.isDark ? "Dark" : "Light")
        .accessibilityIdentifier("theme.\(entry.theme.name)")
    }
}
