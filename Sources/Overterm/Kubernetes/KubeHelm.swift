import Compression
import Foundation

// Stage 2c — docs/design/kubernetes/analysis.md, 2.12 and Section 4 (Helm
// releases): Helm's releases read from the cluster's own storage, with no
// `helm` binary. A release is a record per revision — a Secret of type
// `helm.sh/release.v1` (the default driver) or a ConfigMap, labelled
// `owner=helm`, `name`, `status`, `version` — whose one key, `release`, is
// the release as JSON, gzipped and base64'd (and base64'd again by the API,
// for a Secret). The list is the records' metadata only: their labels say
// the name, revision and status. One record is read, decoded and masked
// when a release is opened, and nothing of it but the masked text stays.
// All of this file is pure.

/// Where Helm keeps a release.
enum KubeHelmStorage: String, Sendable, Equatable, CaseIterable {
    /// `HELM_DRIVER=secret`, Helm 3's and 4's default.
    case secret
    /// `HELM_DRIVER=configmap`: the same record, in a ConfigMap.
    case configMap
    /// Helm 2's Tiller: ConfigMaps labelled `OWNER=TILLER`, a protobuf
    /// record — listed by its labels, never decoded.
    case tiller

    var kind: KubeResourceKind { self == .secret ? KubeHelm.secrets : KubeHelm.configMaps }

    /// What the list asks the server for: Helm's records and nothing else.
    var labelSelector: String { self == .tiller ? "OWNER=TILLER" : "owner=helm" }
    var fieldSelector: String? { self == .secret ? "type=\(KubeHelm.secretType)" : nil }

    var said: String {
        switch self {
        case .secret: "Secret"
        case .configMap: "ConfigMap"
        case .tiller: "Helm 2 (Tiller) ConfigMap"
        }
    }
}

/// One revision's record, as its metadata says it: never its data.
struct KubeHelmRecord: Equatable, Sendable, Identifiable {
    var storage: KubeHelmStorage
    var namespace: String
    /// The Secret's or ConfigMap's name: `sh.helm.release.v1.web.v3`.
    var object: String
    var release: String
    var revision: Int
    /// Helm's word: `deployed`, `superseded`, `failed`, `pending-upgrade`…
    var status: String
    /// `modifiedAt`, else `createdAt` (Unix seconds), else the object's creation.
    var updated: Date?

    var id: String { "\(storage.rawValue)/\(namespace)/\(object)" }
}

/// A release: every record of one name in a namespace, newest first.
struct KubeHelmRelease: Equatable, Sendable, Identifiable {
    var name: String
    var namespace: String
    var storage: KubeHelmStorage
    /// Newest revision first; never empty.
    var history: [KubeHelmRecord]

    var latest: KubeHelmRecord { history[0] }
    var revision: Int { latest.revision }
    var status: String { latest.status }
    var updated: Date? { latest.updated }
    var id: String { "\(storage.rawValue)/\(namespace)/\(name)" }
    var isFailing: Bool { ["failed", "pending-install", "pending-upgrade", "pending-rollback", "uninstalling"].contains(status) }
}

/// What a decoded revision says of its chart: kept for the list once a
/// release was opened — names and versions, no values.
struct KubeHelmChart: Equatable, Sendable {
    var chart: String?
    var version: String?
    var appVersion: String?

    /// `web-1.2.3`, as `helm list` says it.
    var said: String? {
        guard let chart else { return nil }
        return version.map { "\(chart)-\($0)" } ?? chart
    }
}

/// One revision decoded and masked (rule 9): what the detail shows, and
/// nothing else of the record — the values and the manifest as YAML with
/// what looks secret replaced by `***`, every Secret's `data` and
/// `stringData` in the manifest masked whatever its keys, the notes
/// scrubbed. Printed, it says only which release it is.
struct KubeHelmDetail: Equatable, Sendable {
    var release: String
    var namespace: String
    var revision: Int
    var status: String
    var chart: KubeHelmChart
    /// The chart's own description.
    var chartDescription: String?
    /// Helm's word on the revision: `Install complete`, `Upgrade "web" failed: …` (scrubbed).
    var summary: String?
    var firstDeployed: Date?
    var lastDeployed: Date?
    /// NOTES.txt as rendered, scrubbed.
    var notes: String
    /// `helm get values`: what the user supplied, masked.
    var userValues: String
    /// `helm get values --all`: the chart's defaults with the user's over them, masked.
    var computedValues: String
    /// `helm get manifest`, masked; a document that couldn't be read whole is left out.
    var manifest: String
    /// How many values were masked (user-supplied, computed).
    var maskedUserValues: Int
    var maskedComputedValues: Int
    /// The manifest's Secrets, masked whole.
    var maskedSecrets: Int
    /// Documents of the manifest left out: unreadable, so unmaskable.
    var withheldDocuments: Int
}

extension KubeHelmDetail: CustomStringConvertible {
    /// Never a value: a detail printed (a check's detail, a log) says which release it is.
    var description: String { "Helm release \(namespace)/\(release) v\(revision) (\(status))" }
}

/// Why a record couldn't be read: said without anything it held.
enum KubeHelmProblem: Error, Equatable, LocalizedError {
    case notARecord
    case unreadable
    case tooLarge(Int)
    case helm2

    var errorDescription: String? {
        switch self {
        case .notARecord: "The answer isn't a Helm release record."
        case .unreadable: "The release record couldn't be read: it isn't Helm's encoding."
        case .tooLarge(let limit): "The release record is larger than \(limit / (1024 * 1024)) MB decompressed: not read."
        case .helm2: "A Helm 2 (Tiller) record: its protobuf isn't read here. helm 2to3 moves it to Helm 3's storage."
        }
    }
}

enum KubeHelm {
    static let secretType = "helm.sh/release.v1"
    /// The decompressed size a record may have (Section 4: 32 MB).
    static let sizeLimit = 32 * 1024 * 1024

    static let secrets = KubeResourceKind(
        group: "", version: "v1", resource: "secrets", kind: "Secret", singular: "secret", namespaced: true,
        verbs: ["create", "delete", "deletecollection", "get", "list", "patch", "update", "watch"])
    static let configMaps = KubeResourceKind(
        group: "", version: "v1", resource: "configmaps", kind: "ConfigMap", singular: "configmap", namespaced: true,
        verbs: ["create", "delete", "deletecollection", "get", "list", "patch", "update", "watch"], shortNames: ["cm"])

    // MARK: The list

    /// A `PartialObjectMetadataList` page's records (a plain List's items
    /// are read for their metadata alone too). An item that isn't one of
    /// Helm's (no release name, no revision) is passed over.
    static func records(_ body: Data, storage: KubeHelmStorage) throws -> (records: [KubeHelmRecord], continueToken: String?) {
        guard let list = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw KubeTableReader.Malformed(detail: "not a list")
        }
        var records: [KubeHelmRecord] = []
        for item in list["items"] as? [[String: Any]] ?? [] {
            if let record = record(item["metadata"] as? [String: Any] ?? [:], storage: storage) { records.append(record) }
        }
        let token = ((list["metadata"] as? [String: Any])?["continue"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (records, token)
    }

    /// One item's metadata as a record: Helm 3's lowercase labels, Tiller's
    /// uppercase ones; the name and revision from the object's name when a
    /// label is missing (`sh.helm.release.v1.web.v3`, Tiller's `web.v3`).
    static func record(_ metadata: [String: Any], storage: KubeHelmStorage) -> KubeHelmRecord? {
        guard let object = metadata["name"] as? String, let namespace = metadata["namespace"] as? String else { return nil }
        let labels = metadata["labels"] as? [String: String] ?? [:]
        func label(_ name: String) -> String? { labels[storage == .tiller ? name.uppercased() : name].flatMap { $0.isEmpty ? nil : $0 } }
        let fromName = nameAndRevision(object, storage: storage)
        guard let release = label("name") ?? fromName?.name, let revision = label("version").flatMap({ Int($0) }) ?? fromName?.revision else {
            return nil
        }
        let stamp = (storage == .tiller ? labels["MODIFIED_AT"] ?? labels["CREATED_AT"] : labels["modifiedAt"] ?? labels["createdAt"]).flatMap {
            TimeInterval($0)
        }
        let updated = stamp.map { Date(timeIntervalSince1970: $0) } ?? (metadata["creationTimestamp"] as? String).flatMap(date)
        return KubeHelmRecord(
            storage: storage, namespace: namespace, object: object, release: release, revision: revision,
            status: (label("status") ?? "unknown").lowercased(), updated: updated)
    }

    /// `sh.helm.release.v1.<name>.v<revision>` (Tiller: `<name>.v<revision>`).
    static func nameAndRevision(_ object: String, storage: KubeHelmStorage) -> (name: String, revision: Int)? {
        let prefix = "sh.helm.release.v1."
        var rest = Substring(object)
        if storage != .tiller {
            guard object.hasPrefix(prefix) else { return nil }
            rest = rest.dropFirst(prefix.count)
        }
        guard let dot = rest.range(of: ".v", options: .backwards), let revision = Int(rest[dot.upperBound...]), dot.lowerBound > rest.startIndex else {
            return nil
        }
        return (String(rest[..<dot.lowerBound]), revision)
    }

    /// The records as releases: by storage, namespace and name, each's
    /// revisions newest first; the releases by namespace, then name.
    static func releases(_ records: [KubeHelmRecord]) -> [KubeHelmRelease] {
        let grouped = Dictionary(grouping: records) { "\($0.storage.rawValue)\u{0}\($0.namespace)\u{0}\($0.release)" }
        return grouped.values.map { records in
            let history = records.sorted { $0.revision > $1.revision }
            return KubeHelmRelease(name: history[0].release, namespace: history[0].namespace, storage: history[0].storage, history: history)
        }
        .sorted { ($0.namespace, $0.name, $0.storage.rawValue) < ($1.namespace, $1.name, $1.storage.rawValue) }
    }

    // MARK: One record

    /// One record's object (a Secret's or a ConfigMap's GET) decoded and
    /// masked at once: the decoded release is never kept, only what
    /// `KubeHelmDetail` holds.
    /// `isCancelled` is asked between the steps; yes, `CancellationError`.
    static func decode(_ body: Data, storage: KubeHelmStorage, isCancelled: () -> Bool = { false }) throws -> KubeHelmDetail {
        if isCancelled() { throw CancellationError() }
        let payload = try payload(body, storage: storage)
        if isCancelled() { throw CancellationError() }
        guard let release = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { throw KubeHelmProblem.unreadable }
        if isCancelled() { throw CancellationError() }
        return try detail(release, isCancelled: isCancelled)
    }

    /// The release's JSON from its record: the API's base64 for a Secret,
    /// then Helm's base64, then gzip — a payload that doesn't start
    /// `1f 8b 08` is plain JSON (old releases). Capped at `sizeLimit`.
    static func payload(_ body: Data, storage: KubeHelmStorage, limit: Int = sizeLimit) throws -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let kind = object["kind"] as? String, kind == (storage == .secret ? "Secret" : "ConfigMap"),
            let encoded = (object["data"] as? [String: Any])?["release"] as? String
        else { throw KubeHelmProblem.notARecord }
        var text = encoded
        if storage == .secret {
            guard let once = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else { throw KubeHelmProblem.unreadable }
            text = String(decoding: once, as: UTF8.self)
        }
        guard let helm = Data(base64Encoded: text, options: .ignoreUnknownCharacters) else { throw KubeHelmProblem.unreadable }
        let json = try isGzip(helm) ? gunzip(helm, limit: limit) : helm
        guard json.count <= limit else { throw KubeHelmProblem.tooLarge(limit) }
        if storage == .tiller || json.first.map({ $0 != UInt8(ascii: "{") }) == true {
            throw storage == .tiller ? KubeHelmProblem.helm2 : KubeHelmProblem.unreadable
        }
        return json
    }

    static func isGzip(_ data: Data) -> Bool { data.count >= 3 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B && data[data.startIndex + 2] == 8 }

    /// The decoded release, as the detail shows it.
    static func detail(_ release: [String: Any], isCancelled: () -> Bool = { false }) throws -> KubeHelmDetail {
        let info = release["info"] as? [String: Any] ?? [:]
        let chart = release["chart"] as? [String: Any] ?? [:]
        let metadata = chart["metadata"] as? [String: Any] ?? [:]
        let config = release["config"] as? [String: Any] ?? [:]
        let defaults = chart["values"] as? [String: Any] ?? [:]
        let user = KubeHelmMask.values(config)
        if isCancelled() { throw CancellationError() }
        let computed = KubeHelmMask.values(coalesced(defaults, config))
        if isCancelled() { throw CancellationError() }
        let manifest = KubeHelmMask.manifest(release["manifest"] as? String ?? "")
        func text(_ value: Any?) -> String? { (value as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return KubeHelmDetail(
            release: text(release["name"]) ?? "", namespace: text(release["namespace"]) ?? "", revision: (release["version"] as? NSNumber)?.intValue ?? 0,
            status: (text(info["status"]) ?? "unknown").lowercased(),
            chart: KubeHelmChart(chart: text(metadata["name"]), version: text(metadata["version"]), appVersion: text(metadata["appVersion"])),
            chartDescription: text(metadata["description"]).map(KubeHelmMask.scrubbed),
            summary: text(info["description"]).map(KubeHelmMask.scrubbed),
            firstDeployed: text(info["first_deployed"]).flatMap(date), lastDeployed: text(info["last_deployed"]).flatMap(date),
            notes: KubeHelmMask.scrubbed(text(info["notes"]) ?? ""),
            userValues: config.isEmpty ? "" : KubeYAML.text(user.value), computedValues: KubeYAML.text(computed.value), manifest: manifest.text,
            maskedUserValues: user.masked, maskedComputedValues: computed.masked, maskedSecrets: manifest.secrets, withheldDocuments: manifest.withheld)
    }

    /// `helm get values --all`: the chart's values with the user's over
    /// them, maps merged key by key; a user's `null` takes a default away
    /// (Helm's `CoalesceValues`).
    static func coalesced(_ defaults: [String: Any], _ user: [String: Any]) -> [String: Any] {
        var out = defaults
        for (key, value) in user {
            if value is NSNull {
                out[key] = nil
            } else if let map = value as? [String: Any], let base = out[key] as? [String: Any] {
                out[key] = coalesced(base, map)
            } else {
                out[key] = value
            }
        }
        return out
    }

    /// RFC 3339 with or without a fraction (Helm writes nine digits).
    static func date(_ text: String) -> Date? {
        let trimmed = text.replacingOccurrences(of: #"\.[0-9]+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }

    // MARK: gzip

    /// A gzip member's data, inflated — at most `limit` bytes, else
    /// `tooLarge`, whatever its header claims.
    static func gunzip(_ data: Data, limit: Int = sizeLimit) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, isGzip(data) else { throw KubeHelmProblem.unreadable }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 {
            guard index + 2 <= bytes.count else { throw KubeHelmProblem.unreadable }
            index += 2 + (Int(bytes[index]) | Int(bytes[index + 1]) << 8)
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 0x02 != 0 { index += 2 }
        guard index < bytes.count - 8 else { throw KubeHelmProblem.unreadable }
        return try inflate(Array(bytes[index..<(bytes.count - 8)]), limit: limit)
    }

    /// Raw DEFLATE (Compression's `COMPRESSION_ZLIB`), bounded.
    static func inflate(_ input: [UInt8], limit: Int) throws -> Data {
        try stream(input, operation: COMPRESSION_STREAM_DECODE, limit: limit)
    }

    private static func stream(_ input: [UInt8], operation: compression_stream_operation, limit: Int) throws -> Data {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw KubeHelmProblem.unreadable }
        defer { compression_stream_destroy(stream) }
        let chunk = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        var out = Data()
        return try input.withUnsafeBufferPointer { source in
            stream.pointee.src_ptr = source.baseAddress ?? UnsafePointer(buffer)
            stream.pointee.src_size = source.count
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.pointee.dst_size
                if produced > 0 {
                    guard out.count + produced <= limit else { throw KubeHelmProblem.tooLarge(limit) }
                    out.append(buffer, count: produced)
                }
                switch status {
                case COMPRESSION_STATUS_END: return out
                case COMPRESSION_STATUS_OK:
                    // Neither input nor output moved: a truncated stream.
                    if produced == 0, stream.pointee.src_size == 0 { throw KubeHelmProblem.unreadable }
                default: throw KubeHelmProblem.unreadable
                }
            }
        }
    }

    // MARK: Writing one (the fake's and the tests')

    /// A release as Helm stores it: JSON, gzipped, base64'd — the string a
    /// record's `release` key holds (a Secret's is base64'd once more by the API).
    static func encode(_ release: [String: Any]) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: release, options: [.sortedKeys])) ?? Data()
        return gzip(json).base64EncodedString()
    }

    /// A gzip member around raw DEFLATE, as Go's `gzip.Writer` writes one.
    static func gzip(_ data: Data) -> Data {
        let deflated = (try? stream([UInt8](data), operation: COMPRESSION_STREAM_ENCODE, limit: Int.max)) ?? Data()
        var out = Data([0x1F, 0x8B, 0x08, 0, 0, 0, 0, 0, 0, 0xFF])
        out.append(deflated)
        for value in [crc32(data), UInt32(truncatingIfNeeded: data.count)] {
            withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        }
        return out
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
}

/// What looks secret in a release, masked (rule 9: Helm's `config` and the
/// Secrets in its manifest are masked; Section 4: neither is written to
/// disk or given to agents). Pure.
///
/// - **Values** (the user's, the computed ones): a string under a key —
///   any key on its path — that looks secret (`Secrets.isSecret`:
///   `password`, `auth`, `token`, `apiKey`, `existingSecret`…) is `***`,
///   and a number there too; a `name`/`value` pair (an env list) by its
///   name, as `KubeObjectStrip` masks env, its value a string or a
///   number; every other
///   string has a URL's password and credentials in text taken out
///   (`Secrets.scrubCredentials`: PEM bodies, JWTs, bearer tokens, AWS keys).
/// - **The manifest**: each document as `KubeObjectStrip.shown` shows an
///   object — a Secret's `data` and `stringData` all `***`, env values by
///   name, the last-applied annotation gone; a `*List`'s items each so —
///   and credentials in text out of every string. A document that can't be read whole is left out,
///   said: what it holds can't be masked.
enum KubeHelmMask {
    static let mask = KubeObjectStrip.mask

    static func values(_ values: [String: Any]) -> (value: [String: Any], masked: Int) {
        var count = 0
        let out = walk(values, secretPath: false, key: nil, count: &count) as? [String: Any] ?? [:]
        return (out, count)
    }

    private static func walk(_ value: Any, secretPath: Bool, key: String?, count: inout Int) -> Any {
        switch value {
        case let map as [String: Any]:
            var out: [String: Any] = [:]
            // An env entry (`name: DB_PASSWORD`, `value: …`): by its name.
            let entryName = (map["name"] as? String).flatMap { Secrets.isSecret($0) ? $0 : nil }
            for (inner, item) in map {
                let secret = secretPath || Secrets.isSecret(inner) || (entryName != nil && inner == "value")
                out[inner] = walk(item, secretPath: secret, key: inner, count: &count)
            }
            return out
        case let list as [Any]:
            return list.map { walk($0, secretPath: secretPath, key: key, count: &count) }
        case let text as String:
            if secretPath, !text.isEmpty {
                count += 1
                return mask
            }
            let scrubbed = scrubbed(text)
            if scrubbed != text { count += 1 }
            return scrubbed
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            // As a string is: under a secret path (`auth: {pin: 123456}`,
            // a secret-named env entry's value), or its own key secret.
            if secretPath || key.map(Secrets.isSecret) == true {
                count += 1
                return mask
            }
            return number
        default:
            return value
        }
    }

    /// Text that isn't a value of a secret's own: every URL's password and
    /// what looks like a credential taken out.
    static func scrubbed(_ text: String) -> String { Secrets.scrubCredentials(Secrets.maskURLs(in: text)) }

    /// `helm get manifest`, masked: its `---` documents one by one, each's
    /// `# Source:` line kept.
    static func manifest(_ text: String) -> (text: String, secrets: Int, withheld: Int) {
        var documents: [[Substring]] = [[]]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == "---" || line.hasPrefix("--- ") {
                documents.append([])
            } else {
                documents[documents.count - 1].append(line)
            }
        }
        var out: [String] = []
        var secrets = 0
        var withheld = 0
        for lines in documents {
            let body = lines.joined(separator: "\n")
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let source = lines.first { $0.hasPrefix("# Source:") }.map(String.init)
            // Only comments (a template that rendered nothing): no document.
            let content = lines.filter { !$0.hasPrefix("#") }.joined(separator: "\n")
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            guard let parsed = YAMLReader.documents(body)?.filter({ !($0 is NSNull) }), parsed.count == 1, let object = parsed.first as? [String: Any]
            else {
                withheld += 1
                out.append((source.map { $0 + "\n" } ?? "") + "# Left out: Overterm couldn't read this document whole, so it couldn't mask it.\n")
                continue
            }
            var shown = masked(object, secrets: &secrets)
            shown = scrubbingStrings(shown) as? [String: Any] ?? shown
            out.append((source.map { $0 + "\n" } ?? "") + KubeYAML.text(shown))
        }
        return (out.map { "---\n" + $0 }.joined(), secrets, withheld)
    }

    /// One object as `KubeObjectStrip.shown` shows it — and a list's
    /// (`kind: List`, `SecretList`, any `*List` with `items`, which Helm
    /// takes from a template) each item so, its Secrets counted.
    private static func masked(_ object: [String: Any], secrets: inout Int) -> [String: Any] {
        if (object["kind"] as? String)?.hasSuffix("List") == true, let items = object["items"] as? [Any] {
            var object = object
            object["items"] = items.map { item -> Any in
                guard let item = item as? [String: Any] else { return item }
                return masked(item, secrets: &secrets)
            }
            return KubeObjectStrip.shown(object, full: false)
        }
        if KubeObjectStrip.isSecret(object) { secrets += 1 }
        return KubeObjectStrip.shown(object, full: false)
    }

    static func scrubbingStrings(_ value: Any) -> Any {
        switch value {
        case let map as [String: Any]: map.mapValues(scrubbingStrings)
        case let list as [Any]: list.map(scrubbingStrings)
        case let text as String where text != mask: scrubbed(text)
        default: value
        }
    }
}

/// The helm commands the Helm section offers to copy — the user's to run
/// with their own credentials — always with `--kube-context` and `-n`
/// (rule 7), quoted for zsh as `KubectlLine`'s are. Pure.
enum KubeHelmLine {
    /// `helm list --kube-context C -n NS` (`-A` across all namespaces).
    /// Several namespaces: a command each, a line each.
    static func list(context: String, scope: KubeScope) -> String {
        var words = ["helm", "list", "--kube-context", KubectlLine.quoted(context)]
        switch scope {
        case .all: words.append("-A")
        case .namespace(let name): words += ["-n", KubectlLine.quoted(name)]
        case .namespaces:
            return (scope.names ?? []).map { list(context: context, scope: .namespace($0)) }.joined(separator: "\n")
        }
        return words.joined(separator: " ")
    }

    /// `helm status NAME --kube-context C -n NS [--revision N]`.
    static func status(context: String, namespace: String, release: String, revision: Int? = nil) -> String {
        var words = ["helm", "status", KubectlLine.quoted(release), "--kube-context", KubectlLine.quoted(context), "-n", KubectlLine.quoted(namespace)]
        if let revision { words += ["--revision", String(revision)] }
        return words.joined(separator: " ")
    }

    /// `helm history NAME --kube-context C -n NS`.
    static func history(context: String, namespace: String, release: String) -> String {
        ["helm", "history", KubectlLine.quoted(release), "--kube-context", KubectlLine.quoted(context), "-n", KubectlLine.quoted(namespace)]
            .joined(separator: " ")
    }
}
