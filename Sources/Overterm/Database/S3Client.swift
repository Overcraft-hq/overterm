import CryptoKit
import Foundation

/// S3 and everything that speaks it — AWS, DigitalOcean Spaces, MinIO,
/// Cloudflare R2, Backblaze B2, Wasabi, GCS's interoperability — over REST,
/// each request signed with SigV4 (`S3Signer`). Bucket names in the host
/// (virtual-hosted) or the path, as the provider wants.
actor S3Client: StorageClient {
    private let config: DatabaseConnection
    private let secret: String?
    private let session: URLSession
    private let progress = UploadProgress()

    init(_ connection: DatabaseConnection, secret: String?) {
        config = connection
        self.secret = secret
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        session = URLSession(configuration: configuration, delegate: progress, delegateQueue: nil)
    }

    // MARK: Addressing and signing

    private func signer() throws -> S3Signer {
        if !config.awsProfile.isEmpty {
            guard let profile = AWSProfile.load(config.awsProfile) else {
                throw DatabaseError.failed("No profile “\(config.awsProfile)” in ~/.aws/credentials.")
            }
            return S3Signer(
                accessKey: profile.accessKey, secretKey: profile.secretKey, sessionToken: profile.sessionToken,
                region: config.location.isEmpty ? (profile.region ?? "us-east-1") : config.location)
        }
        guard let secret, !secret.isEmpty else { throw DatabaseError.failed("No secret key — Edit Connection to add it.") }
        return S3Signer(accessKey: config.user, secretKey: secret, sessionToken: nil, region: config.location.isEmpty ? "us-east-1" : config.location)
    }

    /// `scheme://host[:port]/bucket/key`, or `scheme://bucket.host/key`.
    func url(bucket: String?, key: String = "", query: [(String, String)] = []) -> URL? {
        var components = URLComponents()
        components.scheme = config.sslMode == .disable ? "http" : "https"
        let virtual = !config.pathStyle && bucket != nil
        components.host = virtual ? "\(bucket!).\(config.host)" : config.host
        components.port = config.port
        var segments: [String] = []
        if let bucket, !virtual { segments.append(bucket) }
        if !key.isEmpty { segments += key.split(separator: "/", omittingEmptySubsequences: false).map(String.init) }
        components.percentEncodedPath = "/" + segments.map(S3Signer.encode).joined(separator: "/")
        if !query.isEmpty {
            components.percentEncodedQuery = query.map { "\(S3Signer.encode($0.0))=\(S3Signer.encode($0.1))" }.joined(separator: "&")
        }
        return components.url
    }

    private func request(
        _ method: String, _ url: URL?, headers: [String: String] = [:], body: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url else { throw DatabaseError.failed("The endpoint isn't a valid address.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        let signed = try signer().sign(
            method: method, url: url, headers: headers, payloadHash: S3Signer.sha256(body ?? Data()), date: Date())
        for (name, value) in signed { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DatabaseError.failed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw DatabaseError.failed("No answer.") }
        guard (200..<300).contains(http.statusCode) else { throw Self.failure(data, http) }
        return (data, http)
    }

    /// S3's `<Error><Code>…<Message>…</Error>`, said plainly.
    static func failure(_ data: Data, _ response: HTTPURLResponse) -> DatabaseError {
        let tree = XMLTree.parse(data)
        let code = tree?.value("Code") ?? ""
        var message = tree?.value("Message") ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode).capitalized
        if code == "PermanentRedirect" || code == "AuthorizationHeaderMalformed",
            let region = response.value(forHTTPHeaderField: "x-amz-bucket-region") ?? tree?.value("Region")
        {
            message = "The bucket is in \(region) — set the region to it."
        }
        if code == "SignatureDoesNotMatch" { message = "The secret key doesn't match the access key." }
        if code == "InvalidAccessKeyId" { message = "No such access key." }
        return DatabaseError.failed(code.isEmpty || message.contains(code) ? message : "\(message) (\(code))")
    }

    // MARK: StorageClient

    func connect() async throws {
        // A key may list one bucket and not the others: the default one tried first.
        if !config.database.isEmpty {
            _ = try await list(bucket: config.database, prefix: "", after: nil)
        } else {
            _ = try await buckets()
        }
    }

    func buckets() async throws -> [StorageBucket] {
        do {
            let (data, _) = try await request("GET", url(bucket: nil))
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let names = XMLTree.parse(data)?.child("Buckets")?.all("Bucket") ?? []
            var buckets = names.compactMap { node -> StorageBucket? in
                guard let name = node.value("Name") else { return nil }
                let created = node.value("CreationDate").flatMap { formatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
                return StorageBucket(name: name, created: created)
            }
            if !config.database.isEmpty, !buckets.contains(where: { $0.name == config.database }) {
                buckets.insert(StorageBucket(name: config.database), at: 0)
            }
            return buckets
        } catch  where !config.database.isEmpty {
            // Not allowed to list buckets: the one it is for.
            return [StorageBucket(name: config.database)]
        }
    }

    /// PUT /bucket — in the connection's region (us-east-1 takes no body).
    func createBucket(_ name: String) async throws {
        let region = try signer().region
        var body: Data?
        if region != "us-east-1", region != "auto", config.provider == .aws || config.provider == .custom {
            body = Data(
                "<CreateBucketConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><LocationConstraint>\(region)</LocationConstraint></CreateBucketConfiguration>"
                    .utf8)
        }
        _ = try await request("PUT", url(bucket: name), body: body)
    }

    func list(bucket: String, prefix: String, after token: String?) async throws -> StorageListing {
        var query = [("list-type", "2"), ("delimiter", "/"), ("prefix", prefix), ("max-keys", "1000")]
        if let token { query.append(("continuation-token", token)) }
        let (data, _) = try await request("GET", url(bucket: bucket, query: query))
        return Self.listing(data, prefix: prefix)
    }

    /// ListObjectsV2's answer: its folders and files, the page's end.
    static func listing(_ data: Data, prefix: String) -> StorageListing {
        guard let tree = XMLTree.parse(data) else { return StorageListing() }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var listing = StorageListing()
        listing.folders = tree.all("CommonPrefixes").compactMap { $0.value("Prefix") }
        listing.objects = tree.all("Contents").compactMap { node in
            guard let key = node.value("Key"), key != prefix else { return nil }
            let modified = node.value("LastModified").flatMap { formatter.date(from: $0) ?? plain.date(from: $0) }
            return StorageObject(
                key: key, size: Int64(node.value("Size") ?? "") ?? 0, modified: modified,
                etag: node.value("ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
        }
        if tree.value("IsTruncated") == "true" { listing.next = tree.value("NextContinuationToken") }
        return listing
    }

    func keys(bucket: String, prefix: String) async throws -> [String] {
        var keys: [String] = []
        var token: String?
        repeat {
            var query = [("list-type", "2"), ("prefix", prefix), ("max-keys", "1000")]
            if let token { query.append(("continuation-token", token)) }
            let (data, _) = try await request("GET", url(bucket: bucket, query: query))
            let tree = XMLTree.parse(data)
            keys += tree?.all("Contents").compactMap { $0.value("Key") } ?? []
            token = tree?.value("IsTruncated") == "true" ? tree?.value("NextContinuationToken") : nil
        } while token != nil && keys.count < 100_000
        return keys
    }

    func read(bucket: String, key: String, range: ClosedRange<Int64>?) async throws -> Data {
        var headers: [String: String] = [:]
        if let range { headers["Range"] = "bytes=\(range.lowerBound)-\(range.upperBound)" }
        return try await request("GET", url(bucket: bucket, key: key), headers: headers).0
    }

    func head(bucket: String, key: String) async throws -> StorageMetadata {
        let (_, response) = try await request("HEAD", url(bucket: bucket, key: key))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return StorageMetadata(
            size: Int64(response.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0,
            contentType: response.value(forHTTPHeaderField: "Content-Type"),
            modified: response.value(forHTTPHeaderField: "Last-Modified").flatMap(formatter.date),
            etag: response.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
    }

    func download(bucket: String, key: String, to destination: URL) async throws {
        guard let url = url(bucket: bucket, key: key) else { throw DatabaseError.failed("The endpoint isn't a valid address.") }
        var request = URLRequest(url: url)
        for (name, value) in try signer().sign(method: "GET", url: url, headers: [:], payloadHash: S3Signer.sha256(Data()), date: Date()) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (file, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Self.failure((try? Data(contentsOf: file)) ?? Data(), (response as? HTTPURLResponse) ?? HTTPURLResponse())
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: file, to: destination)
    }

    func upload(bucket: String, key: String, file: URL, contentType: String?, progress report: @escaping @Sendable (Double) -> Void) async throws {
        guard let url = url(bucket: bucket, key: key) else { throw DatabaseError.failed("The endpoint isn't a valid address.") }
        // The file's hash, read in pieces: a large file isn't held in memory.
        let hash = try Self.sha256(of: file)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        var headers: [String: String] = [:]
        if let contentType { headers["Content-Type"] = contentType }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        headers["Content-Length"] = "\(size)"
        for (name, value) in try signer().sign(method: "PUT", url: url, headers: headers, payloadHash: hash, date: Date()) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let task = session.uploadTask(with: request, fromFile: file)
        let (data, response) = try await progress.run(task, report: report)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Self.failure(data, (response as? HTTPURLResponse) ?? HTTPURLResponse())
        }
    }

    func put(bucket: String, key: String, data: Data, contentType: String?) async throws {
        var headers: [String: String] = [:]
        if let contentType { headers["Content-Type"] = contentType }
        _ = try await request("PUT", url(bucket: bucket, key: key), headers: headers, body: data)
    }

    func delete(bucket: String, keys: [String]) async throws {
        var remaining = keys[...]
        while !remaining.isEmpty {
            let batch = Array(remaining.prefix(1000))
            remaining = remaining.dropFirst(batch.count)
            let objects = batch.map { "<Object><Key>\(Self.escape($0))</Key></Object>" }.joined()
            let body = Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><Delete><Quiet>true</Quiet>\(objects)</Delete>".utf8)
            let md5 = Data(Insecure.MD5.hash(data: body)).base64EncodedString()
            do {
                let (data, _) = try await request(
                    "POST", url(bucket: bucket, query: [("delete", "")]), headers: ["Content-MD5": md5, "Content-Type": "application/xml"],
                    body: body)
                if let error = XMLTree.parse(data)?.child("Error") {
                    throw DatabaseError.failed("\(error.value("Key") ?? ""): \(error.value("Message") ?? "not deleted")")
                }
            } catch let error as DatabaseError where batch.count > 0 && Self.noBatchDelete(error) {
                // A provider without DeleteObjects: one at a time.
                for key in batch { _ = try await request("DELETE", url(bucket: bucket, key: key)) }
            }
        }
    }

    private static func noBatchDelete(_ error: DatabaseError) -> Bool {
        guard case .failed(let message) = error else { return false }
        return message.contains("NotImplemented") || message.contains("not implemented") || message.contains("MalformedXML")
    }

    func link(bucket: String, key: String, expires: TimeInterval) async throws -> URL? {
        guard let url = url(bucket: bucket, key: key) else { return nil }
        return try signer().presign(url: url, expires: expires, date: Date())
    }

    nonisolated func path(bucket: String, key: String) -> String { "s3://\(bucket)/\(key)" }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return S3Signer.hex(hasher.finalize())
    }
}

/// An upload's progress, from URLSession's delegate to whoever asked.
final class UploadProgress: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [Int: @Sendable (Double) -> Void] = [:]
    private var bodies: [Int: Data] = [:]
    private var waiting: [Int: CheckedContinuation<(Data, URLResponse), Error>] = [:]

    func run(_ task: URLSessionUploadTask, report: @escaping @Sendable (Double) -> Void) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                reports[task.taskIdentifier] = report
                waiting[task.taskIdentifier] = continuation
            }
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData sent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let report = lock.withLock { reports[task.taskIdentifier] }
        if totalBytesExpectedToSend > 0 { report?(Double(totalBytesSent) / Double(totalBytesExpectedToSend)) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { bodies[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, body) = lock.withLock { () -> (CheckedContinuation<(Data, URLResponse), Error>?, Data) in
            reports[task.taskIdentifier] = nil
            return (waiting.removeValue(forKey: task.taskIdentifier), bodies.removeValue(forKey: task.taskIdentifier) ?? Data())
        }
        if let error {
            continuation?.resume(throwing: DatabaseError.failed(error.localizedDescription))
        } else if let response = task.response {
            continuation?.resume(returning: (body, response))
        } else {
            continuation?.resume(throwing: DatabaseError.failed("No answer."))
        }
    }
}
