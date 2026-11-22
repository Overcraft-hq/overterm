import Foundation

/// What a tab and a pane hold for Terraform, kept by the shell untyped.
extension Tab {
    /// One of its panes asks for a Terraform write (TerraformPrompt, 3.3):
    /// its tab's mark and the Inbox's card; never answered by Overterm.
    package var terraformAsk: TerraformAsk? {
        get { terraformAskStorage as? TerraformAsk }
        set { terraformAskStorage = newValue }
    }
}

extension TerminalView {
    /// An agent started here and how Terraform's writes were guarded at
    /// its launch (`TerraformAgentGuard`, 3.4): its header says when not.
    package var terraformAgentGuard: TerraformAgentGuard.Launch {
        get { terraformAgentGuardStorage as? TerraformAgentGuard.Launch ?? .none }
        set { terraformAgentGuardStorage = newValue }
    }
}
