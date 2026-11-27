import Foundation

/// A Kafka cluster's page: the overview alone — its brokers and controller,
/// topics and partitions, those under-replicated or without a leader, its
/// consumer groups. From Metadata and ListGroups; nothing a broker doesn't
/// say over the protocol (no JMX). docs/architecture.md, Kafka.
extension KafkaDriver: DatabaseMonitoring {
    package static func monitorParts(for kind: DatabaseKind) -> [MonitorPart] { [.overview] }

    package func overview() async throws -> ServerOverview {
        let metadata = try await refresh()
        let groups = (try? await groupList())?.count
        let health = KafkaOps.health(metadata)
        var facts = [
            ServerFact(title: "Cluster", value: metadata.clusterID ?? "—", detail: "its id"),
            ServerFact(
                title: "Brokers", value: "\(metadata.brokers.count)",
                detail: metadata.controller >= 0 ? "controller \(metadata.controller)" : nil),
            ServerFact(title: "Topics", value: "\(health.topics)", detail: health.internalTopics > 0 ? "and \(health.internalTopics) internal" : nil),
            ServerFact(title: "Partitions", value: "\(health.partitions)"),
            ServerFact(
                title: "Under-replicated", value: "\(health.underReplicated)",
                detail: health.underReplicated > 0 ? "fewer in sync than replicas" : "every replica in sync"),
            ServerFact(title: "Offline", value: "\(health.leaderless)", detail: health.leaderless > 0 ? "partitions without a leader" : "every partition led"),
        ]
        facts.append(ServerFact(title: "Consumer groups", value: groups.map(String.init) ?? "—", detail: groups == nil ? "not listed — no permission?" : nil))
        var notes: [String] = []
        if config.sshEnabled { notes.append("Through an SSH tunnel: every request goes to the one broker given.") }
        notes += metadata.brokers.sorted { $0.id < $1.id }.map { "Broker \($0.id): \($0.host):\($0.port)\($0.rack.map { ", rack \($0)" } ?? "")" }
        return ServerOverview(facts: facts, notes: notes)
    }
}

/// What a cluster's metadata says of its health. Pure.
package enum KafkaOps {
    package struct Health: Equatable {
        package var topics = 0
        package var internalTopics = 0
        package var partitions = 0
        package var underReplicated = 0
        package var leaderless = 0
    }

    package static func health(_ metadata: KafkaWire.Metadata) -> Health {
        var health = Health()
        for topic in metadata.topics where topic.error == 0 {
            if topic.isInternal { health.internalTopics += 1 } else { health.topics += 1 }
            for partition in topic.partitions {
                health.partitions += 1
                if partition.inSync.count < partition.replicas.count { health.underReplicated += 1 }
                if partition.leader < 0 { health.leaderless += 1 }
            }
        }
        return health
    }
}
