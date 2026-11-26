#if E2E
import AppKit
import Foundation

/// One hunk staged, unstaged and discarded from the open changes pane, in a
/// real repository (P13, GIT-G1): two edits far apart in one file are two
/// hunks, each its own patch.
extension E2ERunner {
    func hunkStagingChecks(_ repo: URL) async {
        let diff = app.diff
        let twenty = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let file = repo.appendingPathComponent("h.txt")
        try? twenty.write(to: file, atomically: true, encoding: .utf8)
        _ = try? await git(["add", "h.txt"], in: repo)
        _ = try? await git(["-c", "user.email=e2e@example.test", "-c", "user.name=e2e", "commit", "-q", "-m", "twenty lines"], in: repo)
        try? twenty.replacingOccurrences(of: "line 2\n", with: "line two\n").replacingOccurrences(of: "line 18\n", with: "line eighteen\n")
            .write(to: file, atomically: true, encoding: .utf8)
        func hunks() -> [DiffModel.DiffHunk] {
            guard let card = diff.diffs["h.txt"] else { return [] }
            return card.lines.compactMap { card.hunks[$0.id] }
        }
        check("two edits far apart are two hunks, each with its buttons", await eventually(8) { hunks().count == 2 }, "\(hunks().count)")
        guard let first = hunks().first else { return }
        let staged = await diff.apply(first, .stage)
        let partial = await eventually(5) { diff.files.first { $0.path == "h.txt" }?.stageState == .partial }
        check("Stage takes that hunk alone", staged && partial, diff.actionError ?? "")
        let cached = (try? await Git.run(["diff", "--cached"], in: repo)) ?? ""
        check("the index has it, not the other", cached.contains("+line two") && !cached.contains("eighteen"), cached)
        check("the card says what is staged and what isn't", await eventually(5) { diff.diffs["h.txt"]?.unstagedFrom != nil })
        if let back = hunks().first(where: { $0.side == .staged }) {
            let unstaged = await diff.apply(back, .unstage)
            let none = await eventually(5) { diff.files.first { $0.path == "h.txt" }?.stageState == ChangedFile.StageState.none }
            check("Unstage takes it back out", unstaged && none)
        }
        _ = await eventually(5) { hunks().count == 2 && hunks().allSatisfy { $0.side == .unstaged } }
        if let second = hunks().last {
            _ = await diff.apply(second, .discard)
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            check("Discard takes only that part of the file back", text.contains("line two\n") && text.contains("line 18\n") && !text.contains("eighteen"), text)
        }
        // Back as it was, for the scenario's next checks.
        _ = try? await git(["checkout", "--", "h.txt"], in: repo)
        _ = await eventually(5) { diff.files.isEmpty }
    }
}
#endif
