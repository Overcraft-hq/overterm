import Foundation

package struct StorageBucket: Hashable, Sendable {
    package var name: String
    package var created: Date?
}

package struct StorageObject: Hashable, Sendable {
    package var key: String
    package var size: Int64
    package var modified: Date?
    package var etag: String?

    /// The last part of its key: what the tree shows.
    package var name: String { key.split(separator: "/").last.map(String.init) ?? key }
}

/// A folder's contents: its folders (prefixes, `/` at the end) and files,
/// and where the next page starts when there are more.
package struct StorageListing: Equatable, Sendable {
    package var folders: [String] = []
    package var objects: [StorageObject] = []
    package var next: String?
}

package struct StorageMetadata: Equatable, Sendable {
    package var size: Int64
    package var contentType: String?
    package var modified: Date?
    package var etag: String?
}

/// One bucket store: S3 and its kin (`S3Client`) or GCS's own (`GCSClient`).
package protocol StorageClient: Actor {
    func connect() async throws
    func buckets() async throws -> [StorageBucket]
    func createBucket(_ name: String) async throws
    func list(bucket: String, prefix: String, after token: String?) async throws -> StorageListing
    /// Every key under a prefix — for deleting a folder.
    func keys(bucket: String, prefix: String) async throws -> [String]
    func read(bucket: String, key: String, range: ClosedRange<Int64>?) async throws -> Data
    func head(bucket: String, key: String) async throws -> StorageMetadata
    /// The whole file to `destination`, through a file on disk — never in memory.
    func download(bucket: String, key: String, to destination: URL) async throws
    func upload(bucket: String, key: String, file: URL, contentType: String?, progress: @escaping @Sendable (Double) -> Void) async throws
    func put(bucket: String, key: String, data: Data, contentType: String?) async throws
    func delete(bucket: String, keys: [String]) async throws
    /// A link that opens the file in a browser: presigned (S3), or the
    /// console's (GCS) — nil when there is none.
    func link(bucket: String, key: String, expires: TimeInterval) async throws -> URL?
    /// `s3://bucket/key`, `gs://bucket/key`.
    nonisolated func path(bucket: String, key: String) -> String
}

package enum StorageClients {
    package static func make(_ connection: DatabaseConnection, secret: String?, serviceAccount: String?) -> any StorageClient {
        switch connection.kind {
        case .gcs: GCSClient(connection, serviceAccount: serviceAccount)
        default: S3Client(connection, secret: secret)
        }
    }
}

/// An S3 answer in XML, as a tree: enough for listings and errors.
package final class XMLTree: NSObject, XMLParserDelegate {
    package final class Node {
        package let name: String
        package var text = ""
        package var children: [Node] = []
        package init(_ name: String) { self.name = name }

        package func child(_ name: String) -> Node? { children.first { $0.name == name } }
        package func all(_ name: String) -> [Node] { children.filter { $0.name == name } }
        package func value(_ name: String) -> String? { child(name)?.text }
    }

    private var stack: [Node] = [Node("#document")]

    package static func parse(_ data: Data) -> Node? {
        let tree = XMLTree()
        let parser = XMLParser(data: data)
        parser.delegate = tree
        guard parser.parse() else { return nil }
        return tree.stack.first?.children.first
    }

    package func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let node = Node(name)
        stack.last?.children.append(node)
        stack.append(node)
    }

    package func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }

    package func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if stack.count > 1 { stack.removeLast() }
    }
}

/// ~/.aws/credentials and ~/.aws/config, as the AWS CLI reads them.
package enum AWSProfile {
    package struct Credentials: Equatable {
        package var accessKey: String
        package var secretKey: String
        package var sessionToken: String?
        package var region: String?
    }

    package static func load(_ name: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Credentials? {
        let profile = name.isEmpty ? "default" : name
        let credentials = ini((try? String(contentsOf: home.appendingPathComponent(".aws/credentials"), encoding: .utf8)) ?? "")
        let config = ini((try? String(contentsOf: home.appendingPathComponent(".aws/config"), encoding: .utf8)) ?? "")
        guard let section = credentials[profile], let key = section["aws_access_key_id"], let secret = section["aws_secret_access_key"]
        else { return nil }
        let settings = config[profile == "default" ? "default" : "profile \(profile)"] ?? config[profile] ?? [:]
        return Credentials(accessKey: key, secretKey: secret, sessionToken: section["aws_session_token"], region: settings["region"])
    }

    /// The profiles ~/.aws/credentials has.
    package static func names(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        ini((try? String(contentsOf: home.appendingPathComponent(".aws/credentials"), encoding: .utf8)) ?? "").keys.sorted()
    }

    package static func ini(_ text: String) -> [String: [String: String]] {
        var sections: [String: [String: String]] = [:]
        var current: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let current, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            sections[current, default: [:]][key] = value
        }
        return sections
    }
}
