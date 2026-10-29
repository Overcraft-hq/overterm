import Foundation

/// A volume's detail's tabs.
enum VolumeTab: String, CaseIterable, Identifiable {
    case overview, files

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// A volume's Files tab: a folder at a time, listed through a helper
/// container that runs (`DockerEngine.filesHelper`) — made when the tab
/// first lists, removed as soon as it stops showing, made again when it
/// shows next or when it went under it (its sleep ended). The folder is
/// kept meanwhile, so coming back lists the same one. Files themselves
/// are opened, saved and downloaded by the window, through a helper made
/// for each call (`DockerEngine.reaching`), which needs no shell.
@MainActor
final class VolumeFilesSession: ObservableObject, DockerFolderBrowsing {
    let volume: String
    let docker: DockerModel
    @Published private(set) var folder: String?
    @Published private(set) var entries: [DockerFiles.Entry] = []
    @Published private(set) var filesError: String?
    @Published private(set) var listing = false
    /// No image here has a shell: the tab offers to pull busybox.
    @Published private(set) var needsImage = false
    @Published private(set) var pulling = false

    /// The helper, made or on its way: removed whichever it is.
    private var helper: (engine: DockerEngine, made: Task<String, Error>)?
    private var loading: Task<Void, Never>?
    private var shown = false
    /// The image that last made a helper that ran `sh`: tried first.
    static var worked: String?

    init(volume: String, docker: DockerModel = .shared) {
        self.volume = volume
        self.docker = docker
    }

    /// The tab shows, or stops showing: listed again, or its helper gone —
    /// the folder and what it held kept for its return.
    func follow(shown: Bool) {
        guard shown != self.shown else { return }
        self.shown = shown
        if shown {
            open(folder ?? "/")
        } else {
            loading?.cancel()
            listing = false
            release()
        }
    }

    /// A folder of the volume. Listed only while the tab shows: a session
    /// that doesn't makes nothing.
    func open(_ folder: String) {
        self.folder = folder
        guard shown else { return }
        loading?.cancel()
        listing = true
        loading = Task { [weak self] in await self?.list(folder) }
    }

    func reload() { open(folder ?? "/") }

    private func list(_ folder: String) async {
        guard let engine = docker.engine else {
            filesError = "Docker isn't running."
            listing = false
            return
        }
        // Reconnected: the old engine's helper is no use.
        if let helper, helper.engine !== engine { release() }
        var retried = false
        while true {
            // Closed or hidden before it began: no helper for nobody.
            guard shown, !Task.isCancelled else { return }
            let made = helperTask(on: engine)
            let id: String
            do {
                id = try await made.value
            } catch {
                // One that couldn't be made has nothing to remove: the next
                // listing tries again.
                if helper?.made == made { helper = nil }
                return failed(error, in: folder)
            }
            do {
                let found = try await engine.list(id, folder: DockerVolumeFiles.helperPath(folder))
                guard !Task.isCancelled, self.folder == folder else { return }
                entries = found
                filesError = nil
                needsImage = false
                listing = false
                return
            } catch {
                let status = (error as? DockerError)?.status
                // Its sleep ended, or someone removed it: another, once.
                if !retried, !Task.isCancelled, status == 404 || status == 409, helper?.made == made {
                    retried = true
                    release()
                    continue
                }
                return failed(error, in: folder)
            }
        }
    }

    private func failed(_ error: Error, in folder: String) {
        guard !Task.isCancelled, self.folder == folder else { return }
        needsImage = (error as? DockerError) == DockerVolumeFiles.noShell
        // Removed or pruned since the list was read: the list says so too.
        if (error as? DockerError) == DockerError.volumeGone(volume) { docker.load(.volumes) }
        entries = []
        filesError = DockerVolumeFiles.said(error.localizedDescription)
        listing = false
    }

    /// The helper, made if there is none.
    private func helperTask(on engine: DockerEngine) -> Task<String, Error> {
        if let helper { return helper.made }
        let made = makeHelper(engine)
        helper = (engine, made)
        return made
    }

    /// The first image that runs `sh` (`DockerVolumeFiles.shellImages`):
    /// each tried with `sh -c true`, at most three. Only when none had a
    /// shell does the tab offer busybox; a failure of another kind (a full
    /// disk, a volume that won't mount) is said as the engine said it, as
    /// busybox would fail the same way. A volume gone fails at once.
    private func makeHelper(_ engine: DockerEngine) -> Task<String, Error> {
        let volume = volume
        let users = docker.containers(mountingVolume: volume)
        let debug = Settings.shared.dockerDebugImage
        let worked = Self.worked
        return Task {
            let images = try await engine.images()
            var failure: Error?
            for image in DockerVolumeFiles.shellImages(images, debugImage: debug, mountedBy: users, worked: worked) {
                let id: String
                do {
                    id = try await engine.filesHelper(mounting: volume, image: image)
                } catch {
                    if (error as? DockerError) == DockerError.volumeGone(volume) { throw error }
                    if !DockerVolumeFiles.hasNoShell(error) { failure = error }
                    continue
                }
                do {
                    let probe = try await engine.exec(id, ["sh", "-c", "true"])
                    if probe.exitCode == 0 {
                        Self.worked = image
                        return id
                    }
                    if ![126, 127].contains(probe.exitCode) {
                        let said = probe.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                        failure = DockerError(status: 0, message: "The helper's sh -c true ended \(probe.exitCode)" + (said.isEmpty ? "." : ": " + said))
                    }
                } catch {
                    failure = error
                }
                await engine.removeHelper(id)
            }
            throw failure ?? DockerVolumeFiles.noShell
        }
    }

    /// busybox down, asked for by the tab's button — never on its own.
    func pullShellImage() {
        guard let engine = docker.engine, !pulling else { return }
        pulling = true
        Task {
            do {
                for try await _ in engine.pull(DockerVolumeFiles.fallbackImage) {}
                pulling = false
                needsImage = false
                docker.load(.images)
                reload()
            } catch {
                pulling = false
                filesError = "Pull \(DockerVolumeFiles.fallbackImage): \(error.localizedDescription)"
            }
        }
    }

    /// Its helper removed: the removal, for a caller that must wait till
    /// the volume is free (Remove, Clean Up).
    @discardableResult
    func close() -> Task<Void, Never>? {
        loading?.cancel()
        loading = nil
        shown = false
        listing = false
        return release()
    }

    /// Its helper removed — one still being made too, once it is.
    @discardableResult
    private func release() -> Task<Void, Never>? {
        guard let helper else { return nil }
        self.helper = nil
        let (engine, made) = helper
        return Task.detached {
            guard let id = try? await made.value else { return }
            await engine.removeHelper(id)
        }
    }
}
