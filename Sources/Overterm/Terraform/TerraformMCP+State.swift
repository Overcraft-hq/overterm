import Foundation

/// The state's tools (analysis 5.10, stage 2c): `tf_state_list` (its
/// addresses by module), `tf_state_show` (one object, masked — off on
/// production), `tf_outputs` (names, types and non-sensitive values; a
/// sensitive one is said to be, never given — there is no tool for one,
/// as there is none for a Kubernetes Secret).
///
/// What the person read in the panel this last quarter hour (the same
/// root and workspace) answers first, masked again as an agent reads it
/// (`TerraformState.forAgents`). Otherwise the agent's own read, of a
/// local backend only: any other is reached by initialising it, and its
/// `-backend-config` credentials (an http or pg password, an access key)
/// are kept in clear in `.terraform/terraform.tfstate` (spike 4) — the
/// stripped environment wouldn't stop them, and agents' reads get no
/// credentials (5.10). So a remote state is the person's to open (State in
/// the panel), and tools answer from that read. The agent's own read is
/// `state list`, then `show -json` only where the root's providers may
/// start (`providersRefusal`: `show` starts them for their schemas), in
/// the stripped environment (`Purpose.agentRead`), the workspace checked
/// to exist first. Nothing is written, nothing locked.
extension TerraformMCP {
    static let stateNames = ["tf_state_list", "tf_state_show", "tf_outputs"]

    /// A state read an agent is answered from.
    struct AgentState {
        var addresses: [String]
        var capped: Bool
        /// Masked for agents; nil for a list alone.
        var state: TerraformState?
        /// Where it came from, said first.
        var note: String
    }

    static func stateCall(_ name: String, _ arguments: [String: Any], in checkout: URL) async throws -> String {
        let card = try await card(arguments, in: checkout, tool: name)
        let address = argument(arguments, "address")
        if name == "tf_state_show" {
            guard address != nil else { throw BrowserMCP.ToolError(message: "tf_state_show needs “address”: one of tf_state_list's.") }
            if card.isProduction {
                return "\(card.name) is production: tf_state_show is off there. tf_state_list and tf_outputs read it; its objects are the person's to look at, in Overterm's Terraform panel (State)."
            }
        }
        let root = "\(card.name) · workspace \(card.workspace) · \(card.backendSummary) · \(card.rootClass.title.uppercased())"
        let read: AgentState
        switch await agentState(card, checkout: checkout, values: name != "tf_state_list") {
        case .failure(let why): return "\(card.name): \(why)"
        case .success(let got): read = got
        }
        switch name {
        case "tf_state_list":
            return read.note + "\n" + TerraformStateText.list(read.addresses, capped: read.capped, root: root)
        case "tf_outputs":
            return read.note + "\n" + TerraformStateText.outputs(read.state?.outputs ?? [], root: root)
        default:
            guard let address, let resource = read.state?.resource(address) else {
                let needle = address ?? ""
                let near = read.addresses.filter { !needle.isEmpty && ($0.contains(needle) || needle.contains($0)) }.prefix(8)
                return "\(address ?? "?") isn't in the state of \(card.name)." + (near.isEmpty ? "" : " Close: " + near.joined(separator: ", "))
            }
            return read.note + "\n" + TerraformStateText.resource(resource, root: root)
        }
    }

    /// The person's read of `card` when fresh enough, else the agent's own.
    static func agentState(_ card: TerraformRootCard, checkout: URL, values: Bool) async -> Result<AgentState, StateRefusal> {
        let reads = TerraformStateReads.shared
        if let person = reads.latest(checkout: checkout, root: card.path, reader: .person), person.phase == .read, person.workspace == card.workspace,
            let finished = person.finished, Date().timeIntervalSince(finished) <= TerraformStateReads.agentMaxAge, !values || person.state != nil
        {
            return .success(
                AgentState(
                    addresses: person.addresses, capped: person.capped, state: person.state?.forAgents(),
                    note: "(From the state the person read in Overterm \(person.age()).)"))
        }
        if let why = agentReadRefusal(card) { return .failure(StateRefusal(why)) }
        let (folder, backend, workspace) = (card.folder, card.facts.backend, card.workspace)
        let outside = await TerraformPanelModel.blocking {
            TerraformStateRead.agentLocalRefusal(backend: backend, workspace: workspace, root: folder, checkout: checkout)
        }
        if let outside { return .failure(StateRefusal(outside)) }
        if values, let why = await providersRefusal(root: card.folder, checkout: checkout) {
            return .failure(
                StateRefusal(
                    "reading its state's values starts its providers, and \(why). Ask the person to open State in Overterm's Terraform panel — tf_ tools then answer from what they read — or to run terraform init there."
                ))
        }
        let read = TerraformStateRead(checkout: checkout, card: card, reader: .agent, values: values)
        reads.add(read)
        await read.start(settingPath: Settings.shared.terraformPath)
        switch read.phase {
        case .read:
            return .success(AgentState(addresses: read.addresses, capped: read.capped, state: read.state?.forAgents(), note: "(Read now from its local state, by the agent's own read.)"))
        case .refused(let why):
            return .failure(StateRefusal(why))
        case .failed(let why):
            return .failure(StateRefusal(why))
        default:
            return .failure(StateRefusal("the read didn't finish."))
        }
    }

    /// Why an agent's own read of `card`'s state is refused: any backend
    /// but a local one (its init record can hold credentials, and reading
    /// it reaches a remote state). Nil: a local backend.
    static func agentReadRefusal(_ card: TerraformRootCard) -> String? {
        let backend = card.facts.backend
        guard backend.type != "local" else { return nil }
        return
            "its state is in \(card.backendSummary), which an agent's read never reaches — initialising a remote backend uses what its settings and init record hold, credentials too. Ask the person to open State in Overterm's Terraform panel: tf_ tools then answer from what they read, for 15 minutes."
    }

    struct StateRefusal: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }
}
