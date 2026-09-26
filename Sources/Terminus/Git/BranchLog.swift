import Foundation

/// One commit of a branch: what the Commits list shows.
struct BranchCommit: Identifiable, Equatable {
    let sha: String
    let shortSHA: String
    /// git's relative date ("2 hours ago").
    let date: String
    let subject: String
    /// The message after the subject; empty when there is none.
    let body: String
    /// The paths it touched (a rename's new path). None for a merge.
    let files: [String]

    var id: String { sha }
}

/// A branch's commits since it left its base, from `git log`.
enum BranchLog {
    /// The branch's commits after `mergeBase`, newest first, at most `limit`.
    ///
    /// The fields are NUL-separated, as git's own -z output is: a message can
    /// hold newlines and tabs, never a NUL. Each commit is led by an empty
    /// field, and no path is empty, so a commit's file list ends where the
    /// next commit starts — even at a path that looks like a hash.
    static func arguments(since mergeBase: String, limit: Int) -> [String] {
        [
            "log", "-z", "--name-only", "--no-show-signature", "--max-count=\(limit)",
            "--format=%x00%H%x00%h%x00%ar%x00%s%x00%b", "\(mergeBase)..HEAD",
        ]
    }

    /// Parses what `arguments` prints: per commit an empty field, the hash,
    /// the short hash, the date, the subject, the body; then (-z ends the
    /// format with a NUL) the files, the first after a newline.
    static func parse(_ output: String) -> [BranchCommit] {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var commits: [BranchCommit] = []
        var i = 0
        while i + 5 < fields.count {
            guard fields[i].isEmpty else {
                i += 1
                continue
            }
            let header = Array(fields[(i + 1)...(i + 5)])
            i += 6
            var files: [String] = []
            while i < fields.count, !fields[i].isEmpty {
                // git puts a newline between the message and the file list.
                files.append(files.isEmpty && fields[i].hasPrefix("\n") ? String(fields[i].dropFirst()) : fields[i])
                i += 1
            }
            commits.append(
                BranchCommit(
                    sha: header[0], shortSHA: header[1], date: header[2], subject: header[3],
                    body: header[4].trimmingCharacters(in: .whitespacesAndNewlines), files: files))
        }
        return commits
    }

    /// The commits that touched each path, in `commits`' order (newest first).
    static func byFile(_ commits: [BranchCommit]) -> [String: [BranchCommit]] {
        var byFile: [String: [BranchCommit]] = [:]
        for commit in commits {
            for path in Set(commit.files) { byFile[path, default: []].append(commit) }
        }
        return byFile
    }
}
