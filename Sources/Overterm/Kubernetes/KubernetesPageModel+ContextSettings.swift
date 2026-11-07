import Foundation

// MARK: A context's settings, in one place

/// The selected context's `kubernetes.contexts` entry, whether
/// `kubernetes.agentWrites` names it, and `applyOnProduction` — shown and
/// edited in a sheet over the page (`KubeContextSettingsSheetView`), from
/// the context card and the sidebar context row's menu. Read from the
/// file's own values (`Settings.fileValue`: what this build can't read is
/// kept), saved through `Settings.set`: settings.json edited in place
/// (`SettingsJSON`), checked by `SettingsSchema` first
/// (`KubeContextSettingsDraft.applied`). A production context made less
/// strict is asked in red first, its name typed.
/// Production's write switch for the session is only shown: it is never a
/// setting.
extension KubernetesPageModel {
    /// The sheet for `context` (nil: the one selected), as the settings hold it now.
    func openContextSettings(_ context: KubeContext? = nil) {
        guard let context = context ?? model.selected else { return }
        cheatSheet = false
        picker = nil
        command = nil
        contextSettingsDraft = KubeContextSettingsDraft(
            context: context, contexts: contexts(),
            agentWrites: (settingsStore.fileValue(KubeContextSettingsDraft.agentWritesKey) ?? settingsStore.value(KubeContextSettingsDraft.agentWritesKey))?
                .list ?? [])
    }

    func closeContextSettings() {
        contextSettingsDraft = nil
        giveListTheKeyboard()
    }

    /// Save: both settings written, or nothing and why. Read again from
    /// the store first, so an edit made meanwhile — in the file, on the
    /// Settings page — to another context's entry isn't lost.
    /// `kubernetes.contexts` as the file has it — an entry's fields this
    /// build can't read kept, so a Save writes them back —, else (a file
    /// that doesn't parse) the last good one.
    private func contexts() -> SettingValue? {
        settingsStore.fileValue(KubeContextSettingsDraft.contextsKey) ?? settingsStore.value(KubeContextSettingsDraft.contextsKey)
    }

    func saveContextSettings() {
        guard let draft = contextSettingsDraft else { return }
        let contextsKey = KubeContextSettingsDraft.contextsKey
        let agentWritesKey = KubeContextSettingsDraft.agentWritesKey
        guard let current = settingsStore.fileValue(contextsKey) else {
            contextSettingsDraft?.problem = "settings.json doesn't parse, so nothing was written: fix it in Settings ▸ Kubernetes first."
            return
        }
        // Production made less strict: asked in the sheet, in red, the name typed, before anything is written.
        if draft.lessStrict(entry: current.entries?[draft.context]), !draft.confirmingLessStrict, draft.validation == nil {
            contextSettingsDraft?.confirmingLessStrict = true
            return
        }
        let names = settingsStore.fileValue(agentWritesKey)?.list ?? []
        switch draft.applied(contexts: current, agentWrites: names) {
        case .failure(let refused):
            contextSettingsDraft?.problem = refused.reason
        case .success(let (contexts, agentWrites)):
            settingsStore.set(contextsKey, contexts)
            if agentWrites != names { settingsStore.set(agentWritesKey, .list(agentWrites)) }
            // A file that doesn't parse is the user's to fix: Settings writes nothing then.
            guard settingsStore.fileValue(contextsKey) == contexts, settingsStore.fileValue(agentWritesKey)?.list ?? [] == agentWrites else {
                contextSettingsDraft?.problem = "settings.json doesn't parse, so nothing was written: fix it in Settings ▸ Kubernetes first."
                return
            }
            closeContextSettings()
        }
    }

    /// Settings ▸ Kubernetes, for what the sheet doesn't hold.
    func openKubernetesSettings() {
        contextSettingsDraft = nil
        actions?.settings()
    }
}
