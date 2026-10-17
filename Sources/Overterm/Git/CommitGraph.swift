import Foundation

/// A line crossing a row of the graph: the lane it is in at the top of the
/// row, and the lane it is in at the bottom. They are equal for the common
/// case — a branch passing straight down beside the commits.
struct GraphEdge: Equatable {
    let from: Int
    let to: Int
}

/// One commit's row in the graph gutter.
struct GraphRow: Equatable {
    let sha: String
    /// Where the commit's own dot sits.
    let lane: Int
    /// Lines passing this row without touching the dot.
    let through: [GraphEdge]
    /// Lanes above that end at this dot: its children. More than one means
    /// branches rejoining here.
    let incoming: [Int]
    /// Lanes below the dot continues into: its parents. More than one means
    /// this commit is a merge.
    let outgoing: [Int]
    /// How many lanes are in play — what the gutter has to be wide enough
    /// for at this row.
    let width: Int
}

/// Where each commit sits in the graph, and what connects to what.
///
/// Pure, and the whole reason the gutter can be a `Canvas`: given the
/// commits in the order they are listed, a lane is a column that some
/// commit is expected in. A commit takes the lowest lane already waiting
/// for it, else the lowest free one; its first parent inherits that lane
/// and the others take lanes of their own. A lane nobody is waiting in is
/// free again at once, so six lanes serve a repository with a hundred
/// branches in it as long as only six overlap at a time.
enum GraphLayout {
    /// `maxLanes` is the gutter's budget. Beyond it lanes are drawn on top
    /// of the last one rather than widening the sidebar without end — the
    /// graph stops being exact, which is the right trade at 180 pt.
    static func rows(for commits: [Commit], maxLanes: Int = 6) -> [GraphRow] {
        let cap = max(1, maxLanes)
        func clamp(_ lane: Int) -> Int { min(lane, cap - 1) }

        /// What each lane is waiting for; nil is free.
        var lanes: [String?] = []
        func claimFree(_ lanes: inout [String?]) -> Int {
            if let free = lanes.firstIndex(where: { $0 == nil }) { return free }
            lanes.append(nil)
            return lanes.count - 1
        }
        func occupied(_ lanes: [String?]) -> Int {
            (lanes.lastIndex(where: { $0 != nil }).map { $0 + 1 }) ?? 0
        }

        var rows: [GraphRow] = []
        rows.reserveCapacity(commits.count)
        for commit in commits {
            let before = lanes
            let expecting = before.indices.filter { before[$0] == commit.sha }
            let lane = expecting.first ?? claimFree(&lanes)

            // Every other lane waiting for this commit is spent here.
            for spent in expecting.dropFirst() { lanes[spent] = nil }

            var outgoing: [Int] = []
            if let first = commit.parents.first {
                lanes[lane] = first
                outgoing.append(lane)
            } else {
                // A root commit: the lane ends.
                lanes[lane] = nil
            }
            for parent in commit.parents.dropFirst() {
                if let waiting = lanes.indices.first(where: { lanes[$0] == parent }) {
                    outgoing.append(waiting)
                } else {
                    let free = claimFree(&lanes)
                    lanes[free] = parent
                    outgoing.append(free)
                }
            }

            let through = before.indices
                .filter { before[$0] != nil && !expecting.contains($0) }
                .map { GraphEdge(from: clamp($0), to: clamp($0)) }
            rows.append(
                GraphRow(
                    sha: commit.sha, lane: clamp(lane), through: through,
                    incoming: expecting.map(clamp), outgoing: outgoing.map(clamp),
                    width: min(cap, max(occupied(before), occupied(lanes), lane + 1))))
        }
        return rows
    }

    /// The widest any row gets — the gutter is one width for the whole
    /// list, or the commits' subjects would shift as you scroll.
    static func width(of rows: [GraphRow]) -> Int {
        rows.map(\.width).max() ?? 1
    }
}
