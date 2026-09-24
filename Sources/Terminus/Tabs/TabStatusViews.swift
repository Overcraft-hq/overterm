import SwiftUI

/// How a tab shows what its agent is doing. Motion is the signal's volume:
/// working breathes, waiting sends a ring out, done and failed sit still —
/// so five busy tabs stay calm and the one that wants you stands out.
/// With Reduce Motion on, everything is still and colour carries it.
enum TabStatusStyle {
    /// Signal yellow: the brand's "look here".
    static let signal = Color(red: 1.0, green: 0.882, blue: 0.29)
    static let done = Color(red: 0.36, green: 0.78, blue: 0.44)
    static let failed = Color(red: 0.94, green: 0.36, blue: 0.34)
    /// GitHub's "merged" purple, so a merged worktree reads like its PR.
    static let merged = Color(red: 0.64, green: 0.47, blue: 0.96)
}

/// The agent's glyph while it works: signal yellow, slowly breathing.
struct WorkingGlyph: View {
    let symbol: String
    var size: CGFloat = 10
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(TabStatusStyle.signal)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) { dim = true }
            }
            .help("Working")
    }
}

/// Waiting for you: a yellow dot sending out a soft ring.
struct WaitingDot: View {
    var size: CGFloat = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ring = false

    var body: some View {
        ZStack {
            if !reduceMotion {
                Circle()
                    .stroke(TabStatusStyle.signal, lineWidth: 1.5)
                    .frame(width: size, height: size)
                    .scaleEffect(ring ? 2.4 : 1)
                    .opacity(ring ? 0 : 0.9)
            }
            Circle().fill(TabStatusStyle.signal).frame(width: size, height: size)
        }
        .frame(width: size * 2.4, height: size * 2.4)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { ring = true }
        }
    }
}

/// Done or failed while you were away: still, small, coloured.
struct ResultMark: View {
    let failed: Bool
    var size: CGFloat = 9

    var body: some View {
        Image(systemName: failed ? "xmark.circle.fill" : "checkmark.circle.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(failed ? TabStatusStyle.failed : TabStatusStyle.done)
    }
}

/// A thin bar sliding along the bottom of a working tab, like a page
/// loading in Chrome — visible even on a 38 pt pinned tab.
struct WorkingBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -0.4

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(TabStatusStyle.signal.opacity(0.18))
                if reduceMotion {
                    Capsule().fill(TabStatusStyle.signal.opacity(0.7))
                } else {
                    Capsule()
                        .fill(TabStatusStyle.signal)
                        .frame(width: width * 0.4)
                        .offset(x: width * phase)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 2)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { phase = 1.0 }
        }
    }
}
