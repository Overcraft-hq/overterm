import Foundation

/// A workload's rollout, read as `kubectl rollout status` reads it
/// (kubectl's `polymorphichelpers/rollout_status.go`): the spec seen by the
/// controller (`observedGeneration`), then the updated, ready and available
/// replicas against those wanted — and, for a Deployment, its Progressing
/// condition: `ProgressDeadlineExceeded` is a rollout that is stuck. A
/// paused Deployment says so rather than "waiting". Pure.
struct KubeRollout: Equatable, Sendable {
    enum State: Equatable, Sendable {
        /// kubectl's "successfully rolled out".
        case complete
        /// Still going: kubectl's "Waiting for…".
        case progressing
        /// The controller hasn't seen the spec yet.
        case waitingForSpec
        /// `ProgressDeadlineExceeded`, kubectl's error.
        case stuck
        /// `spec.paused`: it won't go on until resumed.
        case paused
        /// kubectl reads no status for this strategy (`OnDelete`).
        case notTracked
    }

    var state: State
    /// kubectl's words, without its trailing "...".
    var message: String

    var isProblem: Bool { state == .stuck }

    /// The rollout of a Deployment, StatefulSet or DaemonSet; nil for any other kind.
    static func of(_ object: [String: Any]) -> KubeRollout? {
        let name = (object["metadata"] as? [String: Any])?["name"] as? String ?? ""
        switch object["kind"] as? String {
        case "Deployment": return deployment(object, name: name)
        case "StatefulSet": return statefulSet(object, name: name)
        case "DaemonSet": return daemonSet(object, name: name)
        default: return nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: number.intValue
        case let text as String: Int(text)
        default: nil
        }
    }

    private static func parts(_ object: [String: Any]) -> (generation: Int, spec: [String: Any], status: [String: Any]) {
        let metadata = object["metadata"] as? [String: Any] ?? [:]
        return (int(metadata["generation"]) ?? 0, object["spec"] as? [String: Any] ?? [:], object["status"] as? [String: Any] ?? [:])
    }

    static func deployment(_ object: [String: Any], name: String) -> KubeRollout {
        let (generation, spec, status) = parts(object)
        let observed = int(status["observedGeneration"]) ?? 0
        guard generation <= observed else { return KubeRollout(state: .waitingForSpec, message: "Waiting for deployment spec update to be observed") }
        let progressing = (status["conditions"] as? [[String: Any]] ?? []).first { $0["type"] as? String == "Progressing" }
        if progressing?["reason"] as? String == "ProgressDeadlineExceeded" {
            return KubeRollout(state: .stuck, message: "deployment \"\(name)\" exceeded its progress deadline")
        }
        if spec["paused"] as? Bool == true {
            return KubeRollout(state: .paused, message: "deployment \"\(name)\" is paused: its rollout goes on once it is resumed")
        }
        let updated = int(status["updatedReplicas"]) ?? 0
        let replicas = int(status["replicas"]) ?? 0
        let available = int(status["availableReplicas"]) ?? 0
        if let wanted = int(spec["replicas"]), updated < wanted {
            return KubeRollout(
                state: .progressing, message: "Waiting for deployment \"\(name)\" rollout to finish: \(updated) out of \(wanted) new replicas have been updated")
        }
        if replicas > updated {
            return KubeRollout(
                state: .progressing, message: "Waiting for deployment \"\(name)\" rollout to finish: \(replicas - updated) old replicas are pending termination")
        }
        if available < updated {
            return KubeRollout(
                state: .progressing, message: "Waiting for deployment \"\(name)\" rollout to finish: \(available) of \(updated) updated replicas are available")
        }
        return KubeRollout(state: .complete, message: "deployment \"\(name)\" successfully rolled out")
    }

    static func statefulSet(_ object: [String: Any], name: String) -> KubeRollout {
        let (generation, spec, status) = parts(object)
        let strategy = spec["updateStrategy"] as? [String: Any] ?? [:]
        guard (strategy["type"] as? String ?? "RollingUpdate") == "RollingUpdate" else {
            return KubeRollout(state: .notTracked, message: "rollout status is only available for the RollingUpdate strategy")
        }
        let observed = int(status["observedGeneration"]) ?? 0
        guard observed != 0, generation <= observed else {
            return KubeRollout(state: .waitingForSpec, message: "Waiting for statefulset spec update to be observed")
        }
        let wanted = int(spec["replicas"])
        let ready = int(status["readyReplicas"]) ?? 0
        if let wanted, ready < wanted { return KubeRollout(state: .progressing, message: "Waiting for \(wanted - ready) pods to be ready") }
        let updated = int(status["updatedReplicas"]) ?? 0
        if let partition = int((strategy["rollingUpdate"] as? [String: Any])?["partition"]), partition > 0 {
            if let wanted, updated < wanted - partition {
                return KubeRollout(
                    state: .progressing, message: "Waiting for partitioned roll out to finish: \(updated) out of \(wanted - partition) new pods have been updated")
            }
            return KubeRollout(state: .complete, message: "partitioned roll out complete: \(updated) new pods have been updated")
        }
        let updateRevision = status["updateRevision"] as? String ?? ""
        let currentRevision = status["currentRevision"] as? String ?? ""
        if updateRevision != currentRevision {
            return KubeRollout(
                state: .progressing, message: "waiting for statefulset rolling update to complete \(updated) pods at revision \(updateRevision)")
        }
        let current = int(status["currentReplicas"]) ?? 0
        return KubeRollout(state: .complete, message: "statefulset rolling update complete \(current) pods at revision \(currentRevision)")
    }

    static func daemonSet(_ object: [String: Any], name: String) -> KubeRollout {
        let (generation, spec, status) = parts(object)
        guard ((spec["updateStrategy"] as? [String: Any])?["type"] as? String ?? "RollingUpdate") == "RollingUpdate" else {
            return KubeRollout(state: .notTracked, message: "rollout status is only available for the RollingUpdate strategy")
        }
        let observed = int(status["observedGeneration"]) ?? 0
        guard generation <= observed else { return KubeRollout(state: .waitingForSpec, message: "Waiting for daemon set spec update to be observed") }
        let desired = int(status["desiredNumberScheduled"]) ?? 0
        let updated = int(status["updatedNumberScheduled"]) ?? 0
        let available = int(status["numberAvailable"]) ?? 0
        if updated < desired {
            return KubeRollout(
                state: .progressing, message: "Waiting for daemon set \"\(name)\" rollout to finish: \(updated) out of \(desired) new pods have been updated")
        }
        if available < desired {
            return KubeRollout(
                state: .progressing, message: "Waiting for daemon set \"\(name)\" rollout to finish: \(available) of \(desired) updated pods are available")
        }
        return KubeRollout(state: .complete, message: "daemon set \"\(name)\" successfully rolled out")
    }
}
