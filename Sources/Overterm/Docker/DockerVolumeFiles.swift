import Foundation

/// A volume's files, as its Files tab reaches them: through a helper
/// container that has the volume at `/volume`. Folders are listed as a
/// container's are, by `DockerFiles`' script through `exec`, so that
/// helper must run, and run `sh`; `archive` on a folder hands over its
/// whole tree, written as it is walked in name order — a folder's entries
/// come spread among its subfolders' until the end, so a database's volume
/// would be gigabytes a click. Files themselves go through `archive`, on
/// a helper that never starts. Pure.
enum DockerVolumeFiles {
    /// Where a helper has the volume.
    static let mount = "/volume"
    /// How long a browsing helper lives, in seconds: removed when its tab
    /// stops showing, and by its own end (AutoRemove) after a crash.
    static let lifetime = 1800
    /// What the tab offers to pull when no image here has a shell: a few
    /// MB, and only when asked.
    static let fallbackImage = "busybox:latest"

    /// A volume's path as the helper has it: `/conf/app.conf` →
    /// `/volume/conf/app.conf`. `.` and `..` are left out, as a local
    /// copy's are, so a typed `/../../etc` stays in the volume.
    static func helperPath(_ path: String) -> String {
        let parts = path.split(separator: "/").filter { $0 != "." && $0 != ".." }
        return parts.isEmpty ? mount : mount + "/" + parts.joined(separator: "/")
    }

    /// The helper's paths in what the engine or the script says, as the
    /// volume's: `No such folder: /volume/x` → `No such folder: /x`, the
    /// mount itself `/`.
    static func said(_ message: String) -> String {
        let start = #"(^|[\s"'(:=])"#
        let under = message.replacingOccurrences(of: start + "/volume(?=/)", with: "$1", options: .regularExpression)
        return under.replacingOccurrences(of: start + #"/volume(?![\w/-]|\.\w)"#, with: "$1/", options: .regularExpression)
    }

    /// `docker.io/library/busybox:1.36` → `busybox`; `nicolaka/netshoot` as it is.
    static func repository(_ reference: String) -> String {
        var name = DockerEngine.split(reference).0
        for prefix in ["docker.io/", "index.docker.io/", "library/"] where name.hasPrefix(prefix) { name.removeFirst(prefix.count) }
        return name
    }

    /// Small images that have a shell, the likeliest first.
    static let shells = ["busybox", "alpine", "debian", "ubuntu"]

    /// The images to try for a helper that runs `sh`, by id, at most
    /// `limit`: the one that `worked` last; busybox, alpine, debian,
    /// ubuntu; the debug shell's image; what mounts the volume; then the
    /// rest by size, smallest first. Never an untagged image, nor a
    /// distroless one (no shell, by design).
    static func shellImages(
        _ images: [ImageSummary], debugImage: String, mountedBy users: [ContainerSummary], worked: String? = nil, limit: Int = 3
    ) -> [String] {
        let usable = images.filter { image in !image.isDangling && !image.tags.contains { $0.contains("distroless") } }
        func named(_ name: String) -> [ImageSummary] { usable.filter { $0.tags.contains { repository($0) == name } } }
        var ordered: [String] = []
        if let worked, usable.contains(where: { $0.Id == worked }) { ordered.append(worked) }
        for name in shells { ordered += named(name).map(\.Id) }
        ordered += named(repository(debugImage)).map(\.Id)
        let ids = Set(usable.map(\.Id))
        ordered += users.compactMap(\.ImageID).filter(ids.contains)
        ordered += usable.sorted { $0.Size < $1.Size }.map(\.Id)
        var seen = Set<String>()
        return Array(ordered.filter { seen.insert($0).inserted }.prefix(limit))
    }

    /// A helper's start refused for want of `sh` in its image, as runc
    /// says it: another image may have one.
    static func hasNoShell(_ error: Error) -> Bool { error.localizedDescription.contains("executable file not found") }

    /// What the tab says when no image here could list the volume.
    static let noShell = DockerError(
        status: 0, message: "No image here has a shell to list the volume with. Pull busybox (a few MB) and Overterm uses it.")
}
