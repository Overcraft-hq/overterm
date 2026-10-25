import Foundation

/// Google Cloud Storage through its own JSON API, signed in as BigQuery is:
/// a service account's key, or whoever gcloud is on this Mac. (A GCS bucket
/// with HMAC keys is S3 too: S3Client with the GCS provider.)
actor GCSClient: StorageClient {
    private let config: DatabaseConnection
    private let serviceAccount: String?
    private var token: (value: String, expires: Date)?
    private let session = URLSession(configuration: .ephemeral)
    private let progress = UploadProgress()
    private lazy var uploads = URLSession(configuration: .ephemeral, delegate: progress, delegateQueue: nil)

    init(_ connection: DatabaseConnection, serviceAccount: String?) {
        config = connection
        self.serviceAccount = serviceAccount
    }

    private func accessToken() async throws -> String {
        if let token, token.expires > Date().addingTimeInterval(60) { return token.value }
        let fresh: (String, Date)
        switch config.bigQueryAuth {
        case .serviceAccount:
            guard let serviceAccount, !serviceAccount.isEmpty else { throw DatabaseError.failed("No service account key — Edit Connection to add it.") }
            fresh = try await BigQueryDriver.token(
                serviceAccount: serviceAccount, session: session, scope: "https://www.googleapis.com/auth/devstorage.read_write")
        case .gcloud:
            fresh = (try await BigQueryDriver.gcloudToken(), Date().addingTimeInterval(45 * 60))
        }
        token = fresh
        return fresh.0
    }

    private static let api = "https://storage.googleapis.com/storage/v1"

    /// An object's name in a URL path: every `/` encoded too.
    static func encode(_ key: String) -> String { S3Signer.encode(key) }

    private func send(_ method: String, _ address: String, body: Data? = nil, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: address) else { throw DatabaseError.failed("Not a valid bucket or name.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DatabaseError.failed("No answer.") }
        guard (200..<300).contains(http.statusCode) else { throw Self.failure(data, http.statusCode) }
        return (data, http)
    }

    static func failure(_ data: Data, _ status: Int) -> DatabaseError {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = (json?["error"] as? [String: Any])?["message"] as? String
        return DatabaseError.failed(message ?? "Google Cloud Storage answered \(status).")
    }

    private static func json(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }

    private static func date(_ text: Any?) -> Date? {
        guard let text = text as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    func connect() async throws {
        if !config.database.isEmpty {
            _ = try await list(bucket: config.database, prefix: "", after: nil)
        } else {
            _ = try await buckets()
        }
    }

    func buckets() async throws -> [StorageBucket] {
        let (data, _) = try await send("GET", "\(Self.api)/b?project=\(S3Signer.encode(config.project))&maxResults=1000")
        var buckets = (Self.json(data)["items"] as? [[String: Any]] ?? []).compactMap { item -> StorageBucket? in
            guard let name = item["name"] as? String else { return nil }
            return StorageBucket(name: name, created: Self.date(item["timeCreated"]))
        }
        if !config.database.isEmpty, !buckets.contains(where: { $0.name == config.database }) {
            buckets.insert(StorageBucket(name: config.database), at: 0)
        }
        return buckets
    }

    func createBucket(_ name: String) async throws {
        var body: [String: Any] = ["name": name]
        if !config.location.isEmpty { body["location"] = config.location }
        _ = try await send(
            "POST", "\(Self.api)/b?project=\(S3Signer.encode(config.project))", body: try JSONSerialization.data(withJSONObject: body),
            headers: ["Content-Type": "application/json"])
    }

    func list(bucket: String, prefix: String, after token: String?) async throws -> StorageListing {
        var address = "\(Self.api)/b/\(Self.encode(bucket))/o?delimiter=%2F&maxResults=1000&prefix=\(S3Signer.encode(prefix))"
        if let token { address += "&pageToken=\(S3Signer.encode(token))" }
        let (data, _) = try await send("GET", address)
        let json = Self.json(data)
        var listing = StorageListing()
        listing.folders = json["prefixes"] as? [String] ?? []
        listing.objects = (json["items"] as? [[String: Any]] ?? []).compactMap { item in
            guard let name = item["name"] as? String, name != prefix else { return nil }
            return StorageObject(
                key: name, size: Int64(item["size"] as? String ?? "") ?? 0, modified: Self.date(item["updated"]), etag: item["etag"] as? String)
        }
        listing.next = json["nextPageToken"] as? String
        return listing
    }

    func keys(bucket: String, prefix: String) async throws -> [String] {
        var keys: [String] = []
        var token: String?
        repeat {
            var address = "\(Self.api)/b/\(Self.encode(bucket))/o?maxResults=1000&fields=items(name),nextPageToken&prefix=\(S3Signer.encode(prefix))"
            if let token { address += "&pageToken=\(S3Signer.encode(token))" }
            let json = Self.json(try await send("GET", address).0)
            keys += (json["items"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            token = json["nextPageToken"] as? String
        } while token != nil && keys.count < 100_000
        return keys
    }

    func read(bucket: String, key: String, range: ClosedRange<Int64>?) async throws -> Data {
        var headers: [String: String] = [:]
        if let range { headers["Range"] = "bytes=\(range.lowerBound)-\(range.upperBound)" }
        return try await send("GET", "\(Self.api)/b/\(Self.encode(bucket))/o/\(Self.encode(key))?alt=media", headers: headers).0
    }

    func head(bucket: String, key: String) async throws -> StorageMetadata {
        let json = Self.json(try await send("GET", "\(Self.api)/b/\(Self.encode(bucket))/o/\(Self.encode(key))").0)
        return StorageMetadata(
            size: Int64(json["size"] as? String ?? "") ?? 0, contentType: json["contentType"] as? String, modified: Self.date(json["updated"]),
            etag: json["etag"] as? String)
    }

    func upload(bucket: String, key: String, file: URL, contentType: String?, progress report: @escaping @Sendable (Double) -> Void) async throws {
        guard
            let url = URL(
                string: "https://storage.googleapis.com/upload/storage/v1/b/\(Self.encode(bucket))/o?uploadType=media&name=\(S3Signer.encode(key))")
        else { throw DatabaseError.failed("Not a valid bucket or name.") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue(contentType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await progress.run(uploads.uploadTask(with: request, fromFile: file), report: report)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Self.failure(data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    func put(bucket: String, key: String, data: Data, contentType: String?) async throws {
        _ = try await send(
            "POST", "https://storage.googleapis.com/upload/storage/v1/b/\(Self.encode(bucket))/o?uploadType=media&name=\(S3Signer.encode(key))",
            body: data, headers: ["Content-Type": contentType ?? "application/octet-stream"])
    }

    func delete(bucket: String, keys: [String]) async throws {
        for key in keys {
            do {
                _ = try await send("DELETE", "\(Self.api)/b/\(Self.encode(bucket))/o/\(Self.encode(key))")
            } catch DatabaseError.failed(let message) where message.contains("404") || message.contains("No such object") {
                continue
            }
        }
    }

    /// The Cloud console's page for it (signed URLs need the key's own signature).
    func link(bucket: String, key: String, expires: TimeInterval) async throws -> URL? {
        URL(
            string:
                "https://console.cloud.google.com/storage/browser/_details/\(Self.encode(bucket))/\(key.split(separator: "/").map { S3Signer.encode(String($0)) }.joined(separator: "/"))?project=\(S3Signer.encode(config.project))"
        )
    }

    nonisolated func path(bucket: String, key: String) -> String { "gs://\(bucket)/\(key)" }
}
