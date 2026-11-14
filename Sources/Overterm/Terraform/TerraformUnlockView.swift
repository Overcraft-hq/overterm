import SwiftUI

/// Force Unlock…, beside Wait for It under a lock the plan couldn't take
/// (2e): only where it can be forced — not the local backend's OS lock,
/// not HCP's — and not while one is going.
struct TerraformForceUnlockButton: View {
    @ObservedObject var run: TerraformPlanRun
    @ObservedObject var unlocks: TerraformUnlockModel = .shared
    @ObservedObject var theme: ChromeTheme
    let action: () -> Void

    var body: some View {
        if run.lock != nil, TerraformProcessCheck.refused(.forceUnlock, backendType: run.card.facts.backend.type) == nil,
            unlocks.notes[run.id]?.unlocked != true
        {
            let going = unlocks.going.contains(run.id)
            Button(action: action) {
                Label(going ? "Checking the Lock…" : "Force Unlock…", systemImage: "lock.open").font(.system(size: ChromeMetrics.text(11)))
                    .padding(.horizontal, 7).frame(height: ChromeMetrics.row(22))
                    .background(RoundedRectangle(cornerRadius: 5).fill(theme.iconBg))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.text)
            .disabled(going)
            .accessibilityIdentifier("terraform.plan.forceUnlock")
        }
    }
}

/// What the last force unlock of this run's lock said: unlocked (Plan
/// again), or why nothing was.
struct TerraformUnlockNoteView: View {
    @ObservedObject var run: TerraformPlanRun
    @ObservedObject var unlocks: TerraformUnlockModel = .shared
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        if let note = unlocks.notes[run.id] {
            Text(verbatim: note.text).font(.system(size: ChromeMetrics.text(11), weight: note.unlocked ? .semibold : .regular))
                .foregroundStyle(note.unlocked ? theme.greenText : theme.orangeText).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("terraform.plan.unlockNote")
        }
    }
}
