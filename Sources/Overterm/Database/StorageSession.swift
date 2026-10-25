import Foundation

/// A storage connection, open: its buckets, each folder's listing as far
/// as it has been read (a page at a time), and the uploads under way.
@MainActor
final class StorageSession: ObservableObject {
    enum State: Equatable {
        case closed, connecting, open
        case failed(String)
    }

    struct Transfer: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var progress: Double = 0
        var error: String?
        var done = false
    }

    let connection: DatabaseConnection
    let client: any StorageClient
    @Published private(set) var state = State.closed
    @Published private(set) var buckets: [StorageBucket] = []
    /// By `bucket/prefix`.
    @Published private(set) var listings: [String: StorageListing] = [:]
    @Published private(set) var loading: Set<String> = []
    @Published private(set) var transfers: [Transfer] = []
    private var opening: Task<Void, Never>?

    init(_ connection: DatabaseConnection, secrets: DatabaseSecrets) {
        self.connection = connection
        client = StorageClients.make(
            connection, secret: secrets.value(.password, for: connection.id), serviceAccount: secrets.value(.serviceAccount, for: connection.id))
    }

    var isOpen: Bool { state == .open }

    static func key(_ bucket: String, _ prefix: String) -> String { "\(bucket)/\(prefix)" }

    func open() async {
        if let opening {
            await opening.value
            return
        }
        guard state != .open else { return }
        let task = Task {
            state = .connecting
            do {
                try await client.connect()
                buckets = try await client.buckets()
                state = .open
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
        opening = task
        await task.value
        opening = nil
    }

    func close() {
        state = .closed
        buckets = []
        listings = [:]
    }

    func listing(_ bucket: String, _ prefix: String) -> StorageListing? { listings[Self.key(bucket, prefix)] }

    /// A folder's first page — or, `more`, its next.
    func load(_ bucket: String, _ prefix: String, more: Bool = false) async {
        let key = Self.key(bucket, prefix)
        guard !loading.contains(key), more || listings[key] == nil else { return }
        let token = more ? listings[key]?.next : nil
        if more, token == nil { return }
        loading.insert(key)
        defer { loading.remove(key) }
        do {
            let page = try await client.list(bucket: bucket, prefix: prefix, after: token)
            var listing = more ? (listings[key] ?? StorageListing()) : StorageListing()
            listing.folders += page.folders
            listing.objects += page.objects
            listing.next = page.next
            listings[key] = listing
        } catch {
            listings[key] = StorageListing()
            report(error)
        }
    }

    /// What is shown again from the server: a folder (and the buckets).
    func refresh(_ bucket: String? = nil, _ prefix: String = "") async {
        if let bucket {
            listings = listings.filter { !$0.key.hasPrefix(Self.key(bucket, prefix)) }
            await load(bucket, prefix)
        } else {
            listings = [:]
            buckets = (try? await client.buckets()) ?? buckets
        }
    }

    @Published var lastError: String?

    private func report(_ error: Error) {
        lastError = error.localizedDescription
    }

    private func refuseIfReadOnly() -> Bool {
        guard connection.readOnly else { return false }
        lastError = "This connection only reads."
        return true
    }

    // MARK: Writing

    /// Files and folders from Finder into `bucket/prefix`, a folder's
    /// files under its name — one at a time, each with its progress.
    func upload(_ urls: [URL], to bucket: String, prefix: String) async {
        guard !refuseIfReadOnly() else { return }
        var files: [(URL, String)] = []
        for url in urls {
            var isFolder: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
            if isFolder.boolValue {
                // Both resolved: the walker answers /private/var for /var,
                // and a key cut at the wrong length lands in the wrong folder.
                let base = url.deletingLastPathComponent().resolvingSymlinksInPath().path
                let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                while let file = walker?.nextObject() as? URL {
                    guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                    let path = file.resolvingSymlinksInPath().path
                    guard path.hasPrefix(base + "/") else { continue }
                    files.append((file, prefix + String(path.dropFirst(base.count + 1))))
                }
            } else {
                files.append((url, prefix + url.lastPathComponent))
            }
        }
        for (file, key) in files {
            let transfer = Transfer(name: key)
            transfers.append(transfer)
            let id = transfer.id
            do {
                try await client.upload(bucket: bucket, key: key, file: file, contentType: FilePreview.contentType(of: key)) { progress in
                    Task { @MainActor [weak self] in self?.update(id) { $0.progress = progress } }
                }
                update(id) {
                    $0.progress = 1
                    $0.done = true
                }
            } catch {
                update(id) { $0.error = error.localizedDescription }
            }
        }
        await refresh(bucket, prefix)
        // Finished ones go a moment later; failed ones stay to be read.
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        transfers.removeAll { $0.done }
    }

    private func update(_ id: UUID, _ change: (inout Transfer) -> Void) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        change(&transfers[index])
    }

    func dismissTransfers() { transfers.removeAll { $0.done || $0.error != nil } }

    /// An empty folder: S3 has none, so a `name/` marker stands for it.
    func newFolder(_ name: String, in bucket: String, prefix: String) async {
        guard !refuseIfReadOnly() else { return }
        let clean = name.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !clean.isEmpty else { return }
        do {
            try await client.put(bucket: bucket, key: prefix + clean + "/", data: Data(), contentType: "application/x-directory")
        } catch {
            report(error)
        }
        await refresh(bucket, prefix)
    }

    func newBucket(_ name: String) async {
        guard !refuseIfReadOnly() else { return }
        do {
            try await client.createBucket(name.lowercased())
            buckets = (try? await client.buckets()) ?? buckets
        } catch {
            report(error)
        }
    }

    /// The keys a delete would take: a file's own, a folder's every one.
    func keys(for key: String, in bucket: String) async -> [String] {
        guard key.hasSuffix("/") else { return [key] }
        return (try? await client.keys(bucket: bucket, prefix: key)) ?? []
    }

    func delete(_ keys: [String], in bucket: String, refreshing prefix: String) async {
        guard !refuseIfReadOnly(), !keys.isEmpty else { return }
        do {
            try await client.delete(bucket: bucket, keys: keys)
        } catch {
            report(error)
        }
        await refresh(bucket, prefix)
    }
}

extension DatabaseModel {
    /// A storage connection's session — one an id, made on first need.
    func storage(_ connection: DatabaseConnection) -> StorageSession {
        if let session = storageSessions[connection.id], session.connection == connection { return session }
        let session = StorageSession(connection, secrets: store.secrets)
        storageSessions[connection.id] = session
        return session
    }
}
