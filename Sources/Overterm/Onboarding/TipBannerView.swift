import AppKit
import SwiftUI

/// What a press on a tip asks of the window. Every one goes through the
/// window (`TerminalWindowController.performTipAction`), which runs it and
/// leaves the keyboard where it was.
package enum TipAction: Equatable, Sendable {
    /// T1: the Inbox, as View ▸ Inbox opens it.
    case openInbox
    /// T1: macOS's notification question, put now — by this click (D-6).
    case allowNotifications
    /// T2, T4: the Settings page that decides what the tip names.
    case settings(SettingsSection)
    /// ×: gone for good.
    case dismiss
    /// `general.tips` off: the card and every tip (D-11).
    case turnOffTips
}

/// What the banner shows besides `Start`'s state: notifications as macOS
/// said when T1 took its place — read live, never kept (D-14).
@MainActor
package final class TipBannerModel: ObservableObject {
    @Published package var permission: NotificationPermission?

    package init() {}
}

/// A tip, under the title bar, floating over the top of the body
/// (onboarding 7.6, D-3): one line or two, its buttons, Turn Off Tips and
/// ×. Nothing at all while no tip is placed. It never takes the keyboard:
/// its host refuses first responder (`TipBannerHostingView`), its buttons
/// take no focus, and it binds no key — Return and Esc stay the terminal's.
/// No timer: it stays until closed or answered.
package struct TipBannerView: View {
    @ObservedObject private var start: Start
    @ObservedObject private var model: TipBannerModel
    @ObservedObject private var theme: ChromeTheme
    @ObservedObject private var keys: Keybindings
    private let perform: (TipAction) -> Void

    package init(start: Start, model: TipBannerModel, theme: ChromeTheme, keys: Keybindings = .shared, perform: @escaping (TipAction) -> Void) {
        self._start = ObservedObject(wrappedValue: start)
        self._model = ObservedObject(wrappedValue: model)
        self._theme = ObservedObject(wrappedValue: theme)
        self._keys = ObservedObject(wrappedValue: keys)
        self.perform = perform
    }

    /// The tips' words with the keys bound now.
    package static func text(keys: Keybindings) -> StartText {
        var bound: [String: String] = [:]
        for id in StartText.tipCommands {
            if let key = KeyHints.key(id, keys: keys) { bound[id] = key }
        }
        return StartText(keys: bound)
    }

    package var body: some View {
        if start.active, start.state.tips, let banner = start.state.banner {
            let offer = StartText.tipOffer(banner, permission: model.permission)
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: symbol(banner))
                    .font(.system(size: ChromeMetrics.text(13)))
                    .foregroundStyle(banner.tip == .production ? ProductionColor.warning : theme.accentText)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: Self.text(keys: keys).tip(banner))
                        .font(.system(size: ChromeMetrics.text(11.5)))
                        .foregroundStyle(theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("tip.text")
                    if let offer {
                        Text(verbatim: offer)
                            .font(.system(size: ChromeMetrics.text(11)))
                            .foregroundStyle(theme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("tip.offer")
                    }
                }
                Spacer(minLength: 8)
                ForEach(StartText.tipButtons(banner, permission: model.permission), id: \.id) { button in
                    Button(button.title) { perform(button.action) }
                        .focusable(false)
                        .accessibilityIdentifier(button.id)
                }
                Button(StartText.turnOffTips) { perform(.turnOffTips) }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .font(.system(size: ChromeMetrics.text(10.5)))
                    .foregroundStyle(theme.text3)
                    .accessibilityIdentifier("tip.turnOffTips")
                Button {
                    perform(.dismiss)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: ChromeMetrics.text(10), weight: .semibold))
                        .foregroundStyle(theme.text3)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(StartText.closeTip)
                .accessibilityLabel(StartText.closeTip)
                .accessibilityIdentifier("tip.close")
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: 760)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(theme.card)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.border))
            )
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Tip")
            .accessibilityIdentifier("tip.banner")
        }
    }

    private func symbol(_ banner: StartState.Banner) -> String {
        switch banner.tip {
        case .needsYou: "bell.badge"
        case .production: "exclamationmark.octagon.fill"
        case .agentTools: "wrench.and.screwdriver"
        case .clearMoved: "lightbulb"
        }
    }
}

/// The banner's host: one view over the window's content, as the held
/// settings banner's (D-3), that never becomes first responder — a press
/// on a tip leaves the keyboard in the terminal (onboarding risk 1). A
/// press while the window isn't key acts at once.
package final class TipBannerHostingView: NSHostingView<TipBannerView> {
    package override var acceptsFirstResponder: Bool { false }
    package override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
