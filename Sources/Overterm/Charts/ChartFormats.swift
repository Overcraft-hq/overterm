import Foundation

/// Usage as `kubectl top` says it: cpu in millicores, memory in Mi (Ki
/// below one). Pure.
package enum KubeMetricsFormat {
    package static func cpu(_ cores: Double) -> String { "\(Int((cores * 1000).rounded()))m" }

    package static func memory(_ bytes: Double) -> String {
        if bytes > 0, bytes < 1_048_576 { return "\(Int((bytes / 1024).rounded()))Ki" }
        return "\(Int((bytes / 1_048_576).rounded()))Mi"
    }

    /// `used` of `total`, a whole percent; nil without a total.
    package static func percent(_ used: Double, of total: Double?) -> Int? {
        guard let total, total > 0 else { return nil }
        return Int((used / total * 100).rounded())
    }
}

/// Bytes as `kubectl` says capacities: Ki, Mi, Gi, Ti, one decimal under ten. Pure.
package enum KubeVolumeFormat {
    package static func bytes(_ value: Double) -> String {
        let units: [(String, Double)] = [
            ("Ei", 1_152_921_504_606_846_976), ("Pi", 1_125_899_906_842_624), ("Ti", 1_099_511_627_776), ("Gi", 1_073_741_824), ("Mi", 1_048_576), ("Ki", 1024),
        ]
        for (unit, scale) in units where value >= scale {
            let scaled = value / scale
            return (scaled < 10 ? String(format: "%.1f", scaled) : String(Int(scaled.rounded()))) + unit
        }
        return "\(Int(value.rounded()))B"
    }
}
