import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermShell

/// D-6 (b): an agent's write asked as a request — answered by the card,
/// declined, or ended by the clock — and the tab's mark that goes with it.
@MainActor
final class MCPApprovalsTests: XCTestCase {
    private let confirmation = WriteConfirmation(title: "An agent wants to stop “web”", detail: "nginx", button: "Allow", cancel: "Don't", asker: "Asked through MCP by Claude in the tab “api”")

    override func tearDown() async throws {
        MCPApprovals.timeout = .seconds(600)
        MCPApprovals.shared.inFront = nil
    }

    private func waitForPending(_ count: Int) async {
        for _ in 0..<200 where MCPApprovals.shared.pending.count != count { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func testTheTimeoutIsTenMinutes() {
        XCTAssertEqual(MCPApprovals.timeout, .seconds(600))
        XCTAssertEqual(MCPApprovals.timedOutMessage, "Nobody answered in Overterm within 10 minutes: nothing was done. Ask again if it is still needed.")
    }

    func testAllowOnTheCardGivesWhatWasTyped() async throws {
        let asking = Task { try await MCPApprovals.shared.ask(confirmation, pane: "pane-1") }
        await waitForPending(1)
        let request = try XCTUnwrap(MCPApprovals.shared.first(forPanes: ["pane-1"]))
        XCTAssertNil(MCPApprovals.shared.first(forPanes: ["pane-2"]), "another pane's tab has none")
        XCTAssertEqual(request.summary, "An agent wants to stop “web”")
        MCPApprovals.shared.answer(request.id, typed: "")
        let typed = try await asking.value
        XCTAssertEqual(typed, "")
        XCTAssertTrue(MCPApprovals.shared.pending.isEmpty)
        // A second answer to the same request does nothing.
        MCPApprovals.shared.answer(request.id, typed: nil)
    }

    func testDontDeclines() async throws {
        let asking = Task { try await MCPApprovals.shared.ask(confirmation, pane: "pane-1") }
        await waitForPending(1)
        MCPApprovals.shared.answer(try XCTUnwrap(MCPApprovals.shared.pending.first).id, typed: nil)
        let typed = try await asking.value
        XCTAssertNil(typed)
    }

    func testUnansweredItEndsInAnError() async {
        MCPApprovals.timeout = .milliseconds(50)
        do {
            _ = try await MCPApprovals.shared.ask(confirmation, pane: "pane-1")
            XCTFail("a request nobody answers ends in an error")
        } catch let error as BrowserMCP.ToolError {
            XCTAssertTrue(error.message.hasPrefix("Nobody answered in Overterm within"), error.message)
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertTrue(MCPApprovals.shared.pending.isEmpty)
    }

    func testANameToTypeHoldsAllow() {
        XCTAssertTrue(MCPApprovals.accepts("", name: nil))
        XCTAssertFalse(MCPApprovals.accepts("", name: "payments"))
        XCTAssertFalse(MCPApprovals.accepts("payment", name: "payments"))
        XCTAssertTrue(MCPApprovals.accepts(" payments\n", name: "payments"))
    }

    func testTheTabsMarkComesAndGoesWithTheRequest() {
        var activity = TabActivity()
        XCTAssertTrue(activity.mcpAsked("An agent wants to stop “web”", visible: false), "out of sight: notify")
        XCTAssertEqual(activity.mark, .waiting)
        XCTAssertTrue(activity.fromMCP)
        XCTAssertFalse(activity.mcpAsked("An agent wants to stop “web”", visible: false), "the same words again: no second notification")
        XCTAssertTrue(activity.mcpAnswered("An agent wants to stop “web”"))
        XCTAssertEqual(activity.mark, .none)

        // Something else marked it since: its mark stays.
        activity.mcpAsked("An agent wants to stop “web”", visible: true)
        activity.terraformAsked("asks to apply", visible: false)
        XCTAssertFalse(activity.mcpAnswered("An agent wants to stop “web”"))
        XCTAssertEqual(activity.mark, .waiting)
    }

    func testTheInboxCarriesTheRequestFirstAndOffersNoScreenChoices() async throws {
        let asking = Task { try await MCPApprovals.shared.ask(confirmation, pane: "pane-1") }
        await waitForPending(1)
        let request = try XCTUnwrap(MCPApprovals.shared.pending.first)
        let asked = Tab(terminal: TerminalView())
        asked.customTitle = "api"
        let other = Tab(terminal: TerminalView())
        other.customTitle = "web"
        other.activity.handle(.bell, visible: false)
        asked.activity.mcpAsked(request.summary, visible: false)
        let inbox = InboxModel()
        inbox.refresh(
            tabs: [other, asked], group: { _ in nil }, screen: { _ in "Do you want to proceed?\n❯ 1. Yes\n  2. No" },
            approval: { $0 === asked ? request : nil })
        XCTAssertEqual(inbox.entries.map(\.title), ["web", "api"], "both waiting, in tab order")
        let entry = try XCTUnwrap(inbox.entries.first { $0.title == "api" })
        XCTAssertEqual(entry.approval, request)
        XCTAssertNil(entry.prompt, "the card answers the write, never the screen's choices")
        XCTAssertEqual(entry.headline, "api — An agent wants to stop “web”")
        MCPApprovals.shared.answer(request.id, typed: nil)
        _ = try await asking.value
    }

    func testACallsArgumentsAreMaskedAndCut() {
        let line = MCPCallLog.masked([
            "statement": "SELECT 1 -- password=hunter2", "token": "abc", "url": "postgres://me:pw@db/x", "query": String(repeating: "a", count: 400),
            "replicas": 2,
        ])
        XCTAssertFalse(line.contains("hunter2"), line)
        XCTAssertFalse(line.contains("abc"), "a secret-named key's value is masked: \(line)")
        XCTAssertFalse(line.contains(":pw@"), line)
        XCTAssertTrue(line.contains("replicas: 2"), line)
        XCTAssertTrue(line.contains(String(repeating: "a", count: MCPCallLog.argumentLength) + "…"), "a long value is cut")
        XCTAssertTrue(line.hasPrefix("query: "), "keys in order: \(line)")
    }

    func testThePaneLogKeepsTheLastCallsAndHowTheyEnded() {
        let log = MCPCallLog()
        let first = log.begin(pane: "p", tool: "docker_list", arguments: [:])
        log.end(pane: "p", id: first, reply: ["result": ["content": [["type": "text", "text": "ok"]]]])
        let second = log.begin(pane: "p", tool: "docker_action", arguments: ["action": "remove"])
        log.end(pane: "p", id: second, reply: ["error": ["code": -32602, "message": "The user declined."]])
        let calls = log.calls(of: ["p"])
        XCTAssertEqual(calls.map(\.tool), ["docker_action", "docker_list"])
        XCTAssertEqual(calls.last?.outcome, .done(error: false))
        XCTAssertEqual(calls.first?.outcome, .done(error: true))
        XCTAssertNotNil(calls.last?.bytes)
        for index in 0..<(MCPCallLog.perPane + 5) { _ = log.begin(pane: "p", tool: "t\(index)", arguments: [:]) }
        XCTAssertEqual(log.calls(of: ["p"]).count, MCPCallLog.perPane)
        log.forget(pane: "p")
        XCTAssertTrue(log.calls(of: ["p"]).isEmpty)
    }

    func testTheSummaryNamesEveryFeaturesSwitch() {
        let values: [String: SettingValue] = [
            "browser.agentControl": .bool(true), "docker.agentAccess": .bool(true), "docker.agentWrites": .bool(true),
            "database.agentAccess": .bool(true), "kubernetes.agentAccess": .bool(true), "kubernetes.agentWrites": .list(["kind-dev"]),
        ]
        let rows = AgentToolsSummary.rows { values[$0] }
        XCTAssertEqual(rows.map(\.feature), ["Browser", "API client", "Notes", "Database", "Docker", "Kubernetes", "Activity", "Terraform"])
        XCTAssertEqual(rows.first { $0.feature == "Browser" }?.state, "on")
        XCTAssertEqual(rows.first { $0.feature == "Docker" }?.state, "reads; asks to act, each asked")
        XCTAssertEqual(rows.first { $0.feature == "Database" }?.state, "reads only")
        XCTAssertEqual(rows.first { $0.feature == "Kubernetes" }?.state, "reads; asks to change kind-dev, each asked")
        XCTAssertEqual(rows.first { $0.feature == "Terraform" }?.state, "off")
    }
}
