import Foundation

/// One entry of `git stash list`.
struct Stash: Identifiable, Equatable {
    /// `stash@{0}` — what every stash command takes.
    let ref: String
    let sha: String
    let relative: String
    /// `WIP on main: 1a2b3c4 the last commit`, usually.
    let subject: String

    var id: String { ref }
    /// The index in `ref`, for the one command that wants a number.
    var index: Int? {
        guard let open = ref.firstIndex(of: "{"), let close = ref.firstIndex(of: "}") else { return nil }
        return Int(ref[ref.index(after: open)..<close])
    }
}

enum Stashes {
    /// `stash list` is `git log` underneath, so it takes `-z` and a format.
    /// Led by an empty field, as the commit log is, so a subject holding a
    /// tab or a colon can't move the boundary.
    static let arguments = ["stash", "list", "-z", "--format=%x00%gd%x00%H%x00%ar%x00%s"]

    static func parse(_ output: String) -> [Stash] {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var stashes: [Stash] = []
        var i = 0
        while i + 4 < fields.count {
            guard fields[i].isEmpty else {
                i += 1
                continue
            }
            let f = Array(fields[(i + 1)...(i + 4)])
            i += 5
            guard !f[0].isEmpty else { continue }
            stashes.append(Stash(ref: f[0], sha: f[1], relative: f[2], subject: f[3]))
        }
        return stashes
    }
}
