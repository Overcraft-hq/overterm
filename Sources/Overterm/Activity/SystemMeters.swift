import Darwin
import Foundation

/// The system's own counters, read in the full tick (docs/design/activity/
/// analysis.md, 3.8, 6.4's meters): each core's ticks, memory in pages,
/// swap, load, uptime, thermal state, Low Power Mode. Raw values, as the
/// kernel gives them: `SystemMeters` makes the page's numbers of two reads.
package struct SystemMeterCounters: Hashable, Sendable {
    /// Each core's ticks (`PROCESSOR_CPU_LOAD_INFO`): user, system, idle,
    /// nice — 32-bit counters that wrap.
    package var cores: [[UInt32]]
    /// The performance and efficiency cores (`hw.perflevel0`/`1.logicalcpu`):
    /// nil where the Mac has one kind.
    package var performanceCores: Int?
    package var efficiencyCores: Int?
    /// `hw.memsize`, bytes.
    package var memory: UInt64
    package var pageSize: UInt64
    /// `vm_statistics64`, pages.
    package var wired: UInt64
    package var compressed: UInt64
    /// Anonymous memory (`internal_page_count`), what apps hold…
    package var internalPages: UInt64
    /// …and file-backed (`external_page_count`): cached files.
    package var externalPages: UInt64
    package var purgeable: UInt64
    package var free: UInt64
    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4
    /// critical; nil when it can't be read.
    package var pressureLevel: Int32?
    /// `vm.swapusage`, bytes.
    package var swapUsed: UInt64
    package var swapTotal: UInt64
    /// `getloadavg`: 1, 5 and 15 minutes.
    package var load: [Double]
    /// Seconds since boot (`kern.boottime`).
    package var uptime: TimeInterval
    /// `ProcessInfo.thermalState`'s raw value.
    package var thermal: Int
    package var lowPower: Bool
}

/// The meters as the page shows them (6.4): CPU a bar a core since the last
/// read — none the first time —, memory in Activity Monitor's terms. Pure.
package struct SystemMeters: Hashable, Sendable {
    package enum Pressure: String, Sendable {
        case normal, warning, critical, unknown
    }

    package enum Thermal: String, Sendable {
        case nominal, fair, serious, critical
    }

    /// Each core's busy share since the last read, 0…1; empty for a first
    /// read: never 0 for what wasn't measured.
    package var cores: [Double]
    package var performanceCores: Int?
    package var efficiencyCores: Int?
    /// bytes.
    package var memory: UInt64
    /// Activity Monitor's Memory Used: app memory, wired and compressed.
    package var used: UInt64
    /// App memory: anonymous pages less the purgeable ones.
    package var app: UInt64
    package var wired: UInt64
    package var compressed: UInt64
    /// Cached Files: file-backed and purgeable pages.
    package var cached: UInt64
    package var pressure: Pressure
    package var swapUsed: UInt64
    package var swapTotal: UInt64
    package var load: [Double]
    package var uptime: TimeInterval
    package var thermal: Thermal
    package var lowPower: Bool

    /// The whole CPU's busy share, the cores' mean; nil for a first read.
    package var cpu: Double? { cores.isEmpty ? nil : cores.reduce(0, +) / Double(cores.count) }

    /// The meters of `current`, its CPU against `previous`: when a core's
    /// counters didn't move, or the read has a different core count, no core
    /// has a rate — never a 0 that wasn't measured (6.4). Differences wrap at
    /// 2³², as the counters do.
    package static func from(_ current: SystemMeterCounters, previous: SystemMeterCounters?) -> SystemMeters {
        var cores: [Double] = []
        if let previous, previous.cores.count == current.cores.count {
            for (now, then) in zip(current.cores, previous.cores) where now.count >= 4 && then.count >= 4 {
                let user = Double(now[0] &- then[0])
                let system = Double(now[1] &- then[1])
                let idle = Double(now[2] &- then[2])
                let nice = Double(now[3] &- then[3])
                let total = user + system + idle + nice
                guard total > 0 else {
                    cores = []
                    break
                }
                cores.append(min(max((user + system + nice) / total, 0), 1))
            }
            if cores.count != current.cores.count { cores = [] }
        }
        let page = current.pageSize
        let anonymous = current.internalPages > current.purgeable ? current.internalPages - current.purgeable : 0
        let app = anonymous &* page
        let wired = current.wired &* page
        let compressed = current.compressed &* page
        let pressure: Pressure =
            switch current.pressureLevel {
            case 1?: .normal
            case 2?: .warning
            case 4?: .critical
            default: .unknown
            }
        let thermal: Thermal =
            switch current.thermal {
            case 0: .nominal
            case 1: .fair
            case 2: .serious
            default: .critical
            }
        return SystemMeters(
            cores: cores, performanceCores: current.performanceCores, efficiencyCores: current.efficiencyCores, memory: current.memory,
            used: min(app &+ wired &+ compressed, current.memory), app: app, wired: wired, compressed: compressed,
            cached: (current.externalPages &+ current.purgeable) &* page, pressure: pressure, swapUsed: current.swapUsed,
            swapTotal: current.swapTotal, load: current.load, uptime: current.uptime, thermal: thermal, lowPower: current.lowPower)
    }
}

extension LiveActivityKernel {
    /// The system's counters now: Mach's host calls and sysctls, under
    /// 0.05 ms together (3.8). Nil when the processor or memory read fails.
    package func readMeterCounters() -> SystemMeterCounters? {
        let host = mach_host_self()
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        var cores: [[UInt32]] = []
        for core in 0..<Int(count) {
            let base = core * states
            cores.append([
                UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]), UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]), UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]),
            ])
        }
        var stats = vm_statistics64()
        var statsCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let read = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(statsCount)) { host_statistics64(host, HOST_VM_INFO64, $0, &statsCount) }
        }
        guard read == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        host_page_size(host, &pageSize)
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) != 0 { swap = xsw_usage() }
        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) != 3 { loads = [] }
        var boot = timeval()
        var bootSize = MemoryLayout<timeval>.size
        let uptime =
            sysctlbyname("kern.boottime", &boot, &bootSize, nil, 0) == 0
            ? max(Date().timeIntervalSince1970 - (Double(boot.tv_sec) + Double(boot.tv_usec) / 1_000_000), 0) : 0
        let levels = Self.integer("hw.nperflevels") ?? 1
        return SystemMeterCounters(
            cores: cores, performanceCores: levels > 1 ? Self.integer("hw.perflevel0.logicalcpu") : nil,
            efficiencyCores: levels > 1 ? Self.integer("hw.perflevel1.logicalcpu") : nil, memory: ProcessInfo.processInfo.physicalMemory,
            pageSize: UInt64(pageSize), wired: UInt64(stats.wire_count), compressed: UInt64(stats.compressor_page_count),
            internalPages: UInt64(stats.internal_page_count), externalPages: UInt64(stats.external_page_count),
            purgeable: UInt64(stats.purgeable_count), free: UInt64(stats.free_count),
            pressureLevel: Self.integer("kern.memorystatus_vm_pressure_level").map { Int32($0) }, swapUsed: swap.xsu_used,
            swapTotal: swap.xsu_total, load: loads, uptime: uptime, thermal: ProcessInfo.processInfo.thermalState.rawValue,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    /// A sysctl's 32-bit integer; nil when there is none.
    private static func integer(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }
}
