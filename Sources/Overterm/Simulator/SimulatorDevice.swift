import Foundation

/// One simulator this Mac has, as `simctl list devices --json` describes
/// it. Pure: the parsing is all here, so the tests need no Xcode.
struct SimulatorDevice: Equatable, Identifiable, Sendable {
    let udid: String
    let name: String
    /// "iOS 26.2" — read from the runtime's identifier.
    let runtime: String
    let isBooted: Bool

    var id: String { udid }
    var label: String { "\(name) — \(runtime)" }
}

enum SimulatorList {
    /// The available devices, booted first, then the newest runtime, then
    /// by name — the order the picker shows and `first` is what we mirror.
    static func devices(fromJSON data: Data) -> [SimulatorDevice] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let byRuntime = root["devices"] as? [String: Any]
        else { return [] }
        var devices: [(order: (Int, Int, Int, String), device: SimulatorDevice)] = []
        for (identifier, value) in byRuntime {
            guard let entries = value as? [[String: Any]] else { continue }
            let runtime = runtimeName(identifier)
            for entry in entries {
                guard let udid = entry["udid"] as? String, let name = entry["name"] as? String else { continue }
                // A runtime that isn't installed any more leaves its devices
                // behind; they can't be booted and don't belong in the list.
                if let available = entry["isAvailable"] as? Bool, !available { continue }
                let booted = (entry["state"] as? String) == "Booted"
                let version = version(of: identifier)
                devices.append(
                    (
                        (booted ? 0 : 1, -(version.first ?? 0), -(version.dropFirst().first ?? 0), runtime),
                        SimulatorDevice(udid: udid, name: name, runtime: runtime, isBooted: booted)
                    ))
            }
        }
        // Booted first, then the newest runtime, a runtime's own devices
        // together (iOS 26.2 before watchOS 26.2), then by name.
        return devices.sorted {
            ($0.order.0, $0.order.1, $0.order.2, $0.order.3, $0.device.name)
                < ($1.order.0, $1.order.1, $1.order.2, $1.order.3, $1.device.name)
        }
        .map(\.device)
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-2` → `iOS 26.2`.
    static func runtimeName(_ identifier: String) -> String {
        let tail = identifier.components(separatedBy: "SimRuntime.").last ?? identifier
        let parts = tail.split(separator: "-")
        guard let platform = parts.first, parts.count > 1 else { return tail }
        let version = parts.dropFirst()
        // `iOS-26-2` is a platform and a version; anything else is a name we
        // don't know the shape of, and is left as it is.
        guard version.allSatisfy({ Int($0) != nil }) else { return tail }
        return "\(platform) \(version.joined(separator: "."))"
    }

    /// The runtime's version as numbers, for ordering: iOS 26.2 over iOS 18.6.
    private static func version(of identifier: String) -> [Int] {
        let tail = identifier.components(separatedBy: "SimRuntime.").last ?? identifier
        return tail.split(separator: "-").dropFirst().compactMap { Int($0) }
    }
}
