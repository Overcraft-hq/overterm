import Foundation
import NIOCore
import NIOPosix
import NIOSSL

/// Apache Kafka over its own protocol on SwiftNIO, no client library
/// (`KafkaWire`): the bootstrap servers, then each partition's leader as
/// Metadata names it — or, through an SSH tunnel, the one address given
/// for everything (a single broker; another's advertised address can't be
/// reached that way, said). TLS from the first byte or none; SASL PLAIN or
/// SCRAM-SHA-256/512 (the connection's `authSource`), the password from the
/// keychain.
///
/// Never a consumer group of its own: PEEK fetches by offset, so nobody's
/// committed offset moves. The tree: topics (partitions below, their
/// offsets) and consumer groups (their lag). docs/architecture.md, Kafka.
package actor KafkaDriver: DatabaseDriver {
    package let config: DatabaseConnection
    private let password: String?
    /// By broker id; the bootstrap server under `bootstrapID` until
    /// Metadata says which it is.
    private var connections: [Int32: KafkaConnection] = [:]
    private var bootstrap: KafkaConnection?
    /// Opens in flight, by broker id.
    private var opening: [Int32: Task<KafkaConnection, Error>] = [:]
    private var versions: [Int16: ClosedRange<Int16>] = [:]
    package private(set) var metadata: KafkaWire.Metadata?

    /// SASL mechanisms the form offers; none is no SASL.
    package static let mechanisms = ["PLAIN", "SCRAM-SHA-256", "SCRAM-SHA-512"]

    package init(_ connection: DatabaseConnection, password: String?) {
        config = connection
        self.password = password
    }

    /// Through a tunnel: only the address given is reachable.
    private var oneAddress: Bool { config.usesTunnel }

    // MARK: Connecting

    /// The bootstrap servers: `host` may list several (`a:9092,b:9092`).
    package static func seeds(_ connection: DatabaseConnection) -> [(host: String, port: Int)] {
        let port = connection.port ?? DatabaseKind.kafka.defaultPort ?? 9092
        let seeds = connection.host.split(separator: ",").map { item -> (String, Int) in
            let (host, own) = MongoURL.split(String(item).trimmingCharacters(in: .whitespaces))
            return (host.isEmpty ? "127.0.0.1" : host, own ?? port)
        }
        return seeds.isEmpty ? [("127.0.0.1", port)] : seeds
    }

    package func connect() async throws {
        guard bootstrap == nil else { return }
        var failures: [String] = []
        for seed in Self.seeds(config) {
            do {
                let connection = try await open(seed.host, seed.port)
                bootstrap = connection
                try await refresh()
                return
            } catch let error as DatabaseError {
                await close()
                // A password refused is refused by every broker: said at once.
                if case .failed(let message) = error, message.hasPrefix("Authentication failed") { throw error }
                failures.append(error.localizedDescription)
            } catch {
                await close()
                failures.append(error.localizedDescription)
            }
        }
        throw DatabaseError.failed(failures.count == 1 ? failures[0] : failures.joined(separator: "\n"))
    }

    /// A socket to one broker, its versions read and signed in.
    private func open(_ host: String, _ port: Int) async throws -> KafkaConnection {
        let address = "\(host):\(port)"
        let tls = try tlsHandler(serverName: config.serverName ?? host)
        let connection = KafkaConnection(address: address)
        let bootstrapper = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(8))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if let tls { try channel.pipeline.syncOperations.addHandler(tls) }
                    try channel.pipeline.syncOperations.addHandler(connection.handler)
                }
            }
        do {
            connection.channel = try await bootstrapper.connect(host: host, port: port).get()
        } catch {
            throw DatabaseError.failed("Couldn't reach Kafka at \(address) — \(MongoDriver.describe(error))")
        }
        do {
            let answer = try await connection.send(.apiVersions, version: 0, body: [], timeout: .seconds(10))
            let theirs = try KafkaWire.apiVersions(answer)
            if versions.isEmpty { versions = theirs }
        } catch let error as NIOSSLError {
            await connection.close()
            throw DatabaseError.failed("TLS with \(address) failed — \(MongoDriver.tlsWords(error))")
        } catch {
            await connection.close()
            throw DatabaseError.failed(
                config.sslMode == .disable
                    ? "\(address) didn't answer as Kafka — if its listener wants TLS, turn TLS on. (\(error.localizedDescription))"
                    : "\(address) didn't answer as Kafka over TLS — it may not speak TLS on this port: try with TLS off. (\(error.localizedDescription))")
        }
        do {
            try await authenticate(connection)
        } catch {
            await connection.close()
            throw error
        }
        return connection
    }

    private func tlsHandler(serverName: String) throws -> NIOSSLClientHandler? {
        var configuration = TLSConfiguration.makeClientConfiguration()
        switch config.sslMode {
        case .disable, .prefer: return nil
        case .require: configuration.certificateVerification = .none
        case .verifyFull:
            let path = (config.caFile.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            if !path.isEmpty {
                guard FileManager.default.isReadableFile(atPath: path) else {
                    throw DatabaseError.failed("The CA bundle \(config.caFile) can't be read — choose it again in Edit Connection….")
                }
                configuration.trustRoots = .file(path)
            }
        }
        let isAddress = serverName.allSatisfy { $0.isNumber || $0 == "." } || serverName.contains(":")
        do {
            return try NIOSSLClientHandler(
                // SNI even unverified: managed clusters route by it.
                context: NIOSSLContext(configuration: configuration), serverHostname: isAddress ? nil : serverName)
        } catch {
            throw DatabaseError.failed("TLS couldn't be set up: \(MongoDriver.describe(error))")
        }
    }

    /// SASL: the mechanism the connection names, through SaslHandshake
    /// then SaslAuthenticate's rounds. None named: no SASL.
    private func authenticate(_ connection: KafkaConnection) async throws {
        let mechanism = config.authSource.trimmingCharacters(in: .whitespaces).uppercased()
        guard !mechanism.isEmpty else { return }
        guard let password, !password.isEmpty else {
            throw DatabaseError.failed("Kafka signs \(config.user) in with \(mechanism) and a password, and none was given (authMechanismRequiresPassword).")
        }
        let handshake = try KafkaWire.saslHandshake(
            try await connection.send(.saslHandshake, version: 1, body: KafkaWire.saslHandshakeRequest(mechanism: mechanism), timeout: .seconds(10)))
        guard handshake.error == 0 else {
            throw DatabaseError.failed(
                "Authentication failed: the broker doesn't take \(mechanism) on this listener — it takes \(handshake.mechanisms.joined(separator: ", ")).")
        }
        let version = try version(.saslAuthenticate)
        func round(_ token: [UInt8]) async throws -> [UInt8] {
            do {
                return try KafkaWire.saslAuthenticate(
                    try await connection.send(.saslAuthenticate, version: version, body: KafkaWire.saslAuthenticateRequest(token), timeout: .seconds(15)))
            } catch let failure as KafkaWire.Failure {
                let said = failure.message.hasPrefix("Authentication failed") ? failure.message : "Authentication failed: \(failure.message)"
                throw DatabaseError.failed("\(said) — the user or the password is wrong.")
            }
        }
        if mechanism == "PLAIN" {
            _ = try await round([0] + Array(config.user.utf8) + [0] + Array(password.utf8))
            return
        }
        guard let scramMechanism = MongoSCRAM.Mechanism(rawValue: mechanism), scramMechanism != .sha1 else {
            throw DatabaseError.failed("Overterm signs in to Kafka with PLAIN, SCRAM-SHA-256 or SCRAM-SHA-512, not \(mechanism).")
        }
        // Kafka's ScramFormatter takes the password's UTF-8 as it is: no SASLprep.
        let nonce = Data((0..<24).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let scram = MongoSCRAM(mechanism: scramMechanism, user: config.user, rawSecret: password, nonce: nonce)
        do {
            let first = try await round(Array(scram.clientFirst.utf8))
            let final = try scram.clientFinal(serverFirst: String(decoding: first, as: UTF8.self))
            let last = try await round(Array(final.message.utf8))
            try MongoSCRAM.verify(serverFinal: String(decoding: last, as: UTF8.self), expected: final.serverSignature)
        } catch let failure as MongoSCRAM.Failure {
            throw DatabaseError.failed("Authentication failed: \(failure.message)")
        }
    }

    package func close() async {
        for task in opening.values { task.cancel() }
        opening = [:]
        for connection in connections.values where connection !== bootstrap { await connection.close() }
        await bootstrap?.close()
        connections = [:]
        bootstrap = nil
    }

    // MARK: Sending

    private func version(_ api: KafkaWire.API) throws -> Int16 {
        do {
            return try KafkaWire.version(of: api, broker: versions)
        } catch let failure as KafkaWire.Failure {
            throw DatabaseError.failed(failure.message)
        }
    }

    /// The bootstrap connection, opened again when the broker closed it — a
    /// broker drops a connection idle for `connections.max.idle.ms` (10 min).
    private func liveBootstrap() async throws -> KafkaConnection {
        if let bootstrap, bootstrap.isActive { return bootstrap }
        await close()
        try await connect()
        guard let bootstrap else { throw DatabaseError.notConnected }
        return bootstrap
    }

    /// A broker's connection: the bootstrap's when it is that broker, or
    /// when only the address given can be reached. One open at a time a
    /// broker: a second asker waits for the first's.
    private func connection(to id: Int32) async throws -> KafkaConnection {
        let bootstrap = try await liveBootstrap()
        if oneAddress { return bootstrap }
        if let open = connections[id], open.isActive { return open }
        if let pending = opening[id] { return try await pending.value }
        guard let broker = metadata?.brokers.first(where: { $0.id == id }) else {
            throw DatabaseError.failed("Broker \(id) isn't in the cluster's metadata.")
        }
        if bootstrap.address == "\(broker.host):\(broker.port)" { return bootstrap }
        let task = Task { try await self.open(broker.host, Int(broker.port)) }
        opening[id] = task
        defer { opening[id] = nil }
        do {
            let opened = try await task.value
            if let old = connections[id], old !== opened { await old.close() }
            connections[id] = opened
            return opened
        } catch {
            throw DatabaseError.failed(
                "\(error.localizedDescription)\n\nBroker \(id) advertises \(broker.host):\(broker.port), which this Mac can't reach — the cluster's advertised.listeners name addresses for inside its network."
            )
        }
    }

    private func call(_ api: KafkaWire.API, _ body: (Int16) -> [UInt8], on connection: KafkaConnection? = nil) async throws -> ([UInt8], Int16) {
        let target: KafkaConnection
        if let connection { target = connection } else { target = try await liveBootstrap() }
        let version = try version(api)
        do {
            return (try await target.send(api, version: version, body: body(version), timeout: .seconds(30)), version)
        } catch let failure as KafkaWire.Failure {
            throw DatabaseError.failed(failure.message)
        }
    }

    private func decode<T>(_ read: () throws -> T) throws -> T {
        do {
            return try read()
        } catch let failure as KafkaWire.Failure {
            throw DatabaseError.failed(failure.message)
        }
    }

    /// The cluster's brokers and topics, read again.
    @discardableResult
    package func refresh() async throws -> KafkaWire.Metadata {
        let (body, version) = try await call(.metadata, { KafkaWire.metadataRequest(version: $0, topics: nil) })
        let read = try decode { try KafkaWire.metadata(body, version: version) }
        metadata = read
        return read
    }

    private func topic(_ name: String) async throws -> KafkaWire.Topic {
        let metadata = try await refresh()
        guard let topic = metadata.topics.first(where: { $0.name == name }) else { throw DatabaseError.failed("No topic “\(name)” in this cluster.") }
        guard topic.error == 0 else { throw DatabaseError.failed("“\(name)”: \(KafkaWire.error(topic.error)).") }
        return topic
    }

    /// The topic a PUBLISH writes to: made by the broker when it is missing
    /// and the cluster makes topics on first use, as a producer's would be —
    /// its partitions given a moment to have leaders.
    private func topicToWrite(_ name: String) async throws -> KafkaWire.Topic {
        if let known = try await refresh().topics.first(where: { $0.name == name && $0.error == 0 }) { return known }
        for attempt in 0..<10 {
            let (body, version) = try await call(.metadata, { KafkaWire.metadataRequest(version: $0, topics: [name], create: true) })
            let read = try decode { try KafkaWire.metadata(body, version: version) }
            if let made = read.topics.first(where: { $0.name == name }) {
                if made.error == 0, !made.partitions.isEmpty, made.partitions.allSatisfy({ $0.leader >= 0 }) {
                    metadata = try await refresh()
                    return made
                }
                // Only "not yet" is waited out; anything else is the answer.
                if ![3, 5].contains(made.error) { throw DatabaseError.failed("“\(name)”: \(KafkaWire.error(made.error)).") }
            }
            try await Task.sleep(nanoseconds: UInt64(200_000_000 * (attempt + 1)))
        }
        throw DatabaseError.failed("No topic “\(name)” in this cluster, and it doesn't make topics on first use (auto.create.topics.enable) — create it first.")
    }

    /// Partitions' offsets, asked of each leader: the next one's
    /// (`latest`) or the first kept (`earliest`).
    package func offsets(_ partitions: [String: [KafkaWire.Partition]], at timestamp: Int64) async throws -> [String: [Int32: Int64]] {
        var byLeader: [Int32: [String: [(partition: Int32, timestamp: Int64)]]] = [:]
        for (topic, list) in partitions {
            for partition in list where partition.leader >= 0 {
                byLeader[partition.leader, default: [:]][topic, default: []].append((partition.index, timestamp))
            }
        }
        var out: [String: [Int32: Int64]] = [:]
        for (leader, asks) in byLeader.sorted(by: { $0.key < $1.key }) {
            let connection = try await connection(to: leader)
            let (body, version) = try await call(.listOffsets, { KafkaWire.listOffsetsRequest(version: $0, asks) }, on: connection)
            for (topic, answers) in try decode({ try KafkaWire.listOffsets(body, version: version) }) {
                for case (let index, .success(let offset)) in answers { out[topic, default: [:]][index] = offset }
            }
        }
        return out
    }

    // MARK: Running

    package func execute(_ text: String, limit: Int) async throws -> QueryResult {
        let started = Date()
        let command: KafkaText.Command
        do {
            command = try KafkaText.parse(text)
        } catch let problem as KafkaText.Problem {
            throw DatabaseError.failed(problem.message)
        }
        if config.readOnly, case .publish = command { throw DatabaseError.readOnly("PUBLISH") }
        if bootstrap == nil { try await connect() }
        var result: QueryResult
        switch command {
        case .topics: result = try await topics()
        case .describe(let name): result = try await describe(name)
        case .peek(let topic, let count, let partition, let from): result = try await peek(topic, count: min(count, max(limit, 1)), partition: partition, from: from)
        case .publish(let topic, let partition, let key, let value): result = try await publish(topic, partition: partition, key: key, value: value)
        case .groups: result = try await groups()
        case .lag(let group): result = try await lag(group)
        }
        if result.rows.count > limit {
            result.rows = Array(result.rows.prefix(limit))
            result.truncated = true
        }
        result.duration = Date().timeIntervalSince(started)
        return result
    }

    private func topics() async throws -> QueryResult {
        let metadata = try await refresh()
        let listed = metadata.topics.filter { $0.error == 0 }
        let partitions = Dictionary(listed.map { ($0.name, $0.partitions) }, uniquingKeysWith: { first, _ in first })
        let latest = try await offsets(partitions, at: KafkaWire.latest)
        let earliest = try await offsets(partitions, at: KafkaWire.earliest)
        var result = QueryResult()
        result.columns = ["topic", "partitions", "replication", "messages", "internal"]
        result.types = ["string", "int", "int", "int", "bool"]
        result.rows = listed.sorted { ($0.isInternal ? 1 : 0, $0.name) < ($1.isInternal ? 1 : 0, $1.name) }.map { topic in
            let count = topic.partitions.reduce(Int64(0)) { sum, p in
                sum + max(0, (latest[topic.name]?[p.index] ?? 0) - (earliest[topic.name]?[p.index] ?? 0))
            }
            return [topic.name, "\(topic.partitions.count)", "\(topic.partitions.first?.replicas.count ?? 0)", "\(count)", topic.isInternal ? "true" : "false"]
        }
        return result
    }

    private func describe(_ name: String) async throws -> QueryResult {
        let topic = try await topic(name)
        let latest = try await offsets([name: topic.partitions], at: KafkaWire.latest)[name] ?? [:]
        let earliest = try await offsets([name: topic.partitions], at: KafkaWire.earliest)[name] ?? [:]
        var result = QueryResult()
        result.columns = ["partition", "leader", "replicas", "in sync", "earliest", "latest", "messages"]
        result.types = ["int", "int", "string", "string", "int", "int", "int"]
        result.rows = topic.partitions.map { p in
            let first = earliest[p.index]
            let next = latest[p.index]
            return [
                "\(p.index)", p.leader >= 0 ? "\(p.leader)" : "none", p.replicas.map(String.init).joined(separator: ", "),
                p.inSync.map(String.init).joined(separator: ", "), first.map(String.init), next.map(String.init),
                first.flatMap { f in next.map { String(max(0, $0 - f)) } },
            ]
        }
        return result
    }

    /// The newest `count` messages of the topic (of one partition), or the
    /// first `count` from the beginning or an offset: fetched by offset from
    /// each leader, never as a group.
    private func peek(_ name: String, count: Int, partition: Int32?, from: KafkaText.Start) async throws -> QueryResult {
        let topic = try await topic(name)
        var partitions = topic.partitions
        if let partition {
            guard let one = partitions.first(where: { $0.index == partition }) else {
                throw DatabaseError.failed("“\(name)” has partitions 0–\(max(0, partitions.count - 1)); there is no \(partition).")
            }
            partitions = [one]
        }
        let latest = try await offsets([name: partitions], at: KafkaWire.latest)[name] ?? [:]
        let earliest = try await offsets([name: partitions], at: KafkaWire.earliest)[name] ?? [:]
        var messages: [KafkaWire.Message] = []
        var notes: [String] = []
        // Kept to `count` across partitions as they come: never every partition's `count`.
        func keep(_ more: [KafkaWire.Message]) {
            messages += more
            guard messages.count > count else { return }
            if case .newest = from {
                messages.sort { ($0.timestamp, $0.partition, $0.offset) > ($1.timestamp, $1.partition, $1.offset) }
            } else {
                messages.sort { ($0.partition, $0.offset) < ($1.partition, $1.offset) }
            }
            messages = Array(messages.prefix(count))
        }
        for p in partitions {
            guard let end = latest[p.index], let first = earliest[p.index] else {
                notes.append("partition \(p.index): its offsets couldn't be read — its leader may be moving; run it again.")
                continue
            }
            guard end > first else { continue }
            let start: Int64
            switch from {
            case .newest: start = max(first, end - Int64(count))
            case .beginning: start = first
            case .offset(let offset): start = max(first, min(offset, end))
            }
            do {
                keep(try await fetch(name, partition: p, from: start, until: min(end, start + Int64(count)), count: count))
            } catch let error as DatabaseError {
                notes.append("partition \(p.index): \(error.localizedDescription)")
            }
        }
        // The newest first when reading the newest; else in offset order.
        if case .newest = from {
            messages.sort { ($0.timestamp, $0.partition, $0.offset) > ($1.timestamp, $1.partition, $1.offset) }
        } else {
            messages.sort { ($0.partition, $0.offset) < ($1.partition, $1.offset) }
        }
        var result = QueryResult()
        result.columns = ["partition", "offset", "timestamp", "key", "value", "headers"]
        result.types = ["int", "int", "timestamp", "bytes", "bytes", "string"]
        result.rows = messages.prefix(count).map { m in
            let headers = m.headers.map { "\($0.key)=\(KafkaText.text($0.value, cut: 200) ?? "null")" }.joined(separator: ", ")
            return [
                "\(m.partition)", "\(m.offset)", Self.time(m.timestamp), KafkaText.text(m.key), KafkaText.text(m.value, size: m.valueSize),
                headers.isEmpty ? nil : headers,
            ]
        }
        if !notes.isEmpty {
            if result.rows.isEmpty { throw DatabaseError.failed(notes.joined(separator: "\n")) }
            result.message = notes.joined(separator: "\n")
        }
        return result
    }

    /// A partition's messages from `start` until `end` (exclusive), at most
    /// `count`, a fetch at a time from its leader.
    private func fetch(_ topic: String, partition: KafkaWire.Partition, from start: Int64, until end: Int64, count: Int) async throws -> [KafkaWire.Message] {
        guard partition.leader >= 0 else { throw DatabaseError.failed("it has no leader now") }
        let connection = try await connection(to: partition.leader)
        var offset = start
        var out: [KafkaWire.Message] = []
        var maxBytes: Int32 = 1 << 20
        var rounds = 0
        while offset < end, out.count < count, rounds < 64 {
            rounds += 1
            let (body, version) = try await call(
                .fetch, { KafkaWire.fetchRequest(version: $0, topic: topic, partitions: [(partition.index, offset)], maxBytes: maxBytes) }, on: connection)
            guard let answer = try decode({ try KafkaWire.fetch(body, version: version) }).first(where: { $0.partition == partition.index }) else { break }
            guard answer.error == 0 else { throw DatabaseError.failed(KafkaWire.error(answer.error)) }
            let read = try decode { try KafkaWire.messages(answer.records, from: offset, wanted: count - out.count, inflate: KafkaCompression.inflate) }
            guard let next = read.next else {
                // Nothing whole: a batch bigger than what was asked for — ask for more, up to 16 MB.
                guard !answer.records.isEmpty, maxBytes < 16 << 20 else { break }
                maxBytes *= 4
                continue
            }
            for var message in read.messages where message.offset >= offset && message.offset < end {
                message.partition = partition.index
                out.append(message)
            }
            guard next > offset else { break }
            offset = next
        }
        return Array(out.prefix(count))
    }

    private func publish(_ name: String, partition: Int32?, key: String?, value: String) async throws -> QueryResult {
        let topic = try await topicToWrite(name)
        let index: Int32
        if let partition {
            guard topic.partitions.contains(where: { $0.index == partition }) else {
                throw DatabaseError.failed("“\(name)” has partitions 0–\(max(0, topic.partitions.count - 1)); there is no \(partition).")
            }
            index = partition
        } else if let key {
            index = KafkaWire.partition(forKey: Array(key.utf8), of: topic.partitions.count)
        } else {
            index = topic.partitions.randomElement()?.index ?? 0
        }
        guard let target = topic.partitions.first(where: { $0.index == index }), target.leader >= 0 else {
            throw DatabaseError.failed("Partition \(index) of “\(name)” has no leader now.")
        }
        let connection = try await connection(to: target.leader)
        let batch = KafkaWire.batch(key: key.map { Array($0.utf8) }, value: Array(value.utf8), timestamp: Int64(Date().timeIntervalSince1970 * 1000))
        let (body, version) = try await call(.produce, { KafkaWire.produceRequest(version: $0, topic: name, partition: index, batch: batch) }, on: connection)
        let offset = try decode { try KafkaWire.produce(body, version: version) }
        var result = QueryResult()
        result.affected = 1
        result.message = "Published to \(name), partition \(index), offset \(offset)."
        return result
    }

    // MARK: Groups

    /// Every consumer group: ListGroups asks each broker for the ones it coordinates.
    package func groupList() async throws -> [KafkaWire.GroupListing] {
        let metadata = try await refresh()
        var seen: [String: KafkaWire.GroupListing] = [:]
        let brokers = oneAddress ? [metadata.brokers.first?.id ?? -1] : metadata.brokers.map(\.id)
        for id in brokers {
            let connection = oneAddress ? bootstrap : try await self.connection(to: id)
            let (body, version) = try await call(.listGroups, { _ in [] }, on: connection)
            for group in try decode({ try KafkaWire.listGroups(body, version: version) }) { seen[group.id] = group }
        }
        return seen.values.sorted { $0.id < $1.id }
    }

    private func coordinator(_ group: String) async throws -> KafkaConnection {
        let (body, version) = try await call(.findCoordinator, { KafkaWire.findCoordinatorRequest(version: $0, group: group) })
        let broker = try decode { try KafkaWire.findCoordinator(body, version: version) }
        if oneAddress, let bootstrap { return bootstrap }
        if metadata?.brokers.contains(where: { $0.id == broker.id }) != true {
            metadata?.brokers.append(broker)
        }
        return try await connection(to: broker.id)
    }

    package func describeGroup(_ group: String) async throws -> KafkaWire.Group? {
        let connection = try await coordinator(group)
        let (body, version) = try await call(.describeGroups, { KafkaWire.describeGroupsRequest(version: $0, groups: [group]) }, on: connection)
        return try decode { try KafkaWire.describeGroups(body, version: version) }.first
    }

    /// A group's committed offsets, by topic and partition.
    package func committed(_ group: String) async throws -> [String: [Int32: Int64]] {
        let connection = try await coordinator(group)
        let (body, version) = try await call(.offsetFetch, { KafkaWire.offsetFetchRequest(version: $0, group: group) }, on: connection)
        return try decode { try KafkaWire.offsetFetch(body, version: version) }
    }

    private func groups() async throws -> QueryResult {
        var result = QueryResult()
        result.columns = ["group", "state", "protocol", "members"]
        result.types = ["string", "string", "string", "int"]
        for listing in try await groupList() {
            // One the user may not describe, or a KIP-848 group the classic API doesn't: a dash, not "0 members".
            let described = (try? await describeGroup(listing.id)).flatMap { $0?.error == 0 ? $0 : nil }
            result.rows.append([
                listing.id, described.map { $0.state.isEmpty ? "—" : $0.state } ?? "—",
                listing.protocolType.isEmpty ? (described?.protocolType ?? "") : listing.protocolType,
                described.map { "\($0.members.count)" },
            ])
        }
        return result
    }

    /// Each partition the group has committed for: its offset, the end, the lag.
    package func lagRows(_ group: String, metadata known: KafkaWire.Metadata? = nil) async throws -> [(
        topic: String, partition: Int32, committed: Int64, end: Int64?
    )] {
        let committed = try await committed(group)
        guard !committed.isEmpty else { return [] }
        let metadata: KafkaWire.Metadata
        if let known { metadata = known } else { metadata = try await refresh() }
        var partitions: [String: [KafkaWire.Partition]] = [:]
        for topic in metadata.topics where committed[topic.name] != nil { partitions[topic.name] = topic.partitions }
        let ends = try await offsets(partitions, at: KafkaWire.latest)
        var rows: [(String, Int32, Int64, Int64?)] = []
        for (topic, offsets) in committed.sorted(by: { $0.key < $1.key }) {
            for (partition, offset) in offsets.sorted(by: { $0.key < $1.key }) { rows.append((topic, partition, offset, ends[topic]?[partition])) }
        }
        return rows.map { (topic: $0.0, partition: $0.1, committed: $0.2, end: $0.3) }
    }

    private func lag(_ group: String) async throws -> QueryResult {
        // A group nobody has made: said so — a cluster with none yet has no
        // coordinator to ask either.
        guard try await groupList().contains(where: { $0.id == group }) else {
            throw DatabaseError.failed("No consumer group “\(group)” in this cluster.")
        }
        let rows = try await lagRows(group)
        guard !rows.isEmpty else { throw DatabaseError.failed("“\(group)” has committed no offsets.") }
        var result = QueryResult()
        result.columns = ["topic", "partition", "committed", "end", "lag"]
        result.types = ["string", "int", "int", "int", "int"]
        result.rows = rows.map { row in
            [row.topic, "\(row.partition)", "\(row.committed)", row.end.map(String.init), row.end.map { String(max(0, $0 - row.committed)) }]
        }
        return result
    }

    // MARK: The catalog

    package func schemas() async throws -> [String] { [KafkaText.topicsSchema, KafkaText.groupsSchema] }

    package func tables(in schema: String) async throws -> [CatalogTable] {
        if schema == KafkaText.groupsSchema {
            return try await groupList().map { CatalogTable(schema: schema, name: $0.id, detail: $0.protocolType.isEmpty ? nil : $0.protocolType) }
        }
        let metadata = try await refresh()
        return metadata.topics.filter { $0.error == 0 }.sorted { ($0.isInternal ? 1 : 0, $0.name) < ($1.isInternal ? 1 : 0, $1.name) }.map { topic in
            let partitions = "\(topic.partitions.count) partition\(topic.partitions.count == 1 ? "" : "s")"
            return CatalogTable(schema: schema, name: topic.name, detail: topic.isInternal ? "\(partitions), internal" : partitions)
        }
    }

    /// A topic's partitions with their offsets; a group's partitions with their lag.
    package func columns(in schema: String) async throws -> [CatalogColumn] {
        if schema == KafkaText.groupsSchema {
            var columns: [CatalogColumn] = []
            let groups = try await groupList()
            let metadata = try await refresh()
            for group in groups.prefix(200) {
                for row in (try? await lagRows(group.id, metadata: metadata)) ?? [] {
                    let lag = row.end.map { "lag \(max(0, $0 - row.committed))" } ?? "at \(row.committed)"
                    columns.append(CatalogColumn(table: group.id, name: "\(row.topic)/\(row.partition)", type: lag))
                }
            }
            return columns
        }
        let metadata = try await refresh()
        let listed = metadata.topics.filter { $0.error == 0 }
        let partitions = Dictionary(listed.map { ($0.name, $0.partitions) }, uniquingKeysWith: { first, _ in first })
        let latest = try await offsets(partitions, at: KafkaWire.latest)
        let earliest = try await offsets(partitions, at: KafkaWire.earliest)
        return listed.flatMap { topic in
            topic.partitions.map { p in
                let first = earliest[topic.name]?[p.index].map(String.init) ?? "?"
                let next = latest[topic.name]?[p.index].map(String.init) ?? "?"
                return CatalogColumn(table: topic.name, name: "partition \(p.index)", type: "\(first)–\(next) · leader \(p.leader)")
            }
        }
    }

    private static let timeFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    package static func time(_ milliseconds: Int64) -> String {
        milliseconds < 0 ? "—" : timeFormat.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
    }
}

/// One broker's socket: requests out, each answer to the one that waits
/// for its correlation id.
package final class KafkaConnection: @unchecked Sendable {
    package let address: String
    let handler: KafkaAnswerHandler
    var channel: Channel?
    private let lock = NSLock()
    private var next: Int32 = 1

    init(address: String) {
        self.address = address
        handler = KafkaAnswerHandler(address: address)
    }

    var isActive: Bool { channel?.isActive == true }

    func send(_ api: KafkaWire.API, version: Int16, body: [UInt8], timeout: TimeAmount) async throws -> [UInt8] {
        guard let channel else { throw DatabaseError.notConnected }
        guard channel.isActive else { throw DatabaseError.failed("\(address) closed the connection.") }
        let id = nextID()
        let frame = KafkaWire.request(api, version: version, correlation: id, body: body)
        let promise = channel.eventLoop.makePromise(of: [UInt8].self)
        let handler = handler
        let late = DatabaseError.failed("\(address) didn't answer \(api.name) in time.")
        channel.eventLoop.execute {
            handler.expect(id, promise)
            channel.writeAndFlush(channel.allocator.buffer(bytes: frame), promise: nil)
            channel.eventLoop.scheduleTask(in: timeout) { handler.fail(id, late) }
        }
        return try await promise.futureResult.get()
    }

    private func nextID() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        let id = next
        next = next == Int32.max ? 1 : next + 1
        return id
    }

    func close() async {
        try? await channel?.close().get()
        channel = nil
    }
}

/// The socket's end: bytes in, each answer to its request. Touched only on
/// its channel's event loop.
package final class KafkaAnswerHandler: ChannelInboundHandler, @unchecked Sendable {
    package typealias InboundIn = ByteBuffer

    private let address: String
    private var bytes: [UInt8] = []
    private var waiting: [Int32: EventLoopPromise<[UInt8]>] = [:]

    init(address: String) { self.address = address }

    func expect(_ id: Int32, _ promise: EventLoopPromise<[UInt8]>) { waiting[id] = promise }

    func fail(_ id: Int32, _ error: Error) { waiting.removeValue(forKey: id)?.fail(error) }

    package func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        bytes += buffer.readBytes(length: buffer.readableBytes) ?? []
        do {
            while let (correlation, body, length) = try KafkaWire.answer(bytes) {
                bytes.removeFirst(length)
                waiting.removeValue(forKey: correlation)?.succeed(body)
            }
        } catch {
            failAll(DatabaseError.failed("\(address) answered something that isn't Kafka's protocol: \(error.localizedDescription)"))
            context.close(promise: nil)
        }
    }

    package func errorCaught(context: ChannelHandlerContext, error: Error) {
        failAll(error)
        context.close(promise: nil)
    }

    package func channelInactive(context: ChannelHandlerContext) {
        failAll(DatabaseError.failed("\(address) closed the connection."))
        context.fireChannelInactive()
    }

    private func failAll(_ error: Error) {
        let pending = waiting
        waiting = [:]
        for promise in pending.values { promise.fail(error) }
    }
}
