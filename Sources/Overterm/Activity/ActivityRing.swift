import Foundation

/// What `ActivityRing` keeps a history of (docs/design/activity/analysis.md,
/// 6.11).
package enum ActivityRingKey: Hashable, Sendable {
    /// One of the user's processes.
    case process(ActivityProcessID)
    /// An agent's subtree, summed: the agent and everything under it.
    case agent(ActivityProcessID)
    /// A tab's processes, summed: what its panes place.
    case tab(UUID)
    /// The Mac: its CPU as a share of every core (100 all of them) and the
    /// memory used — the meters'.
    case system

    /// A process's or an agent's: forgotten 15 minutes after it ends.
    package var identity: ActivityProcessID? {
        switch self {
        case .process(let identity), .agent(let identity): identity
        case .tab, .system: nil
        }
    }
}

/// One sample of a key: its rates over the census's last interval, its
/// footprint now. Nil is unread, never zero.
package struct ActivityRingSample: Equatable, Sendable {
    /// 100 is one core; the system's, 100 every core.
    package var cpu: Double
    /// Bytes: the footprint; the system's, the memory used.
    package var memory: Double?
    /// W, an estimate.
    package var energy: Double?
    package var idleWakeups: Double?
    /// Bytes a second.
    package var diskRead: Double?
    package var diskWritten: Double?

    package init(cpu: Double, memory: Double? = nil, energy: Double? = nil, idleWakeups: Double? = nil, diskRead: Double? = nil, diskWritten: Double? = nil) {
        self.cpu = cpu
        self.memory = memory
        self.energy = energy
        self.idleWakeups = idleWakeups
        self.diskRead = diskRead
        self.diskWritten = diskWritten
    }

    /// A process's: its rates and footprint.
    package init(_ rates: ActivityRates, usage: ActivityUsage?) {
        self.init(
            cpu: rates.cpuPercent, memory: usage.map { Double($0.footprint) }, energy: rates.energy, idleWakeups: rates.idleWakeupsPerSecond,
            diskRead: rates.diskReadPerSecond, diskWritten: rates.diskWrittenPerSecond)
    }

    /// Two samples added: a subtree's, a tab's. A part either lacks is left
    /// out of the sum — the sum unread only when both lack it.
    package static func + (a: ActivityRingSample, b: ActivityRingSample) -> ActivityRingSample {
        func add(_ x: Double?, _ y: Double?) -> Double? { x.map { $0 + (y ?? 0) } ?? y }
        return ActivityRingSample(
            cpu: a.cpu + b.cpu, memory: add(a.memory, b.memory), energy: add(a.energy, b.energy), idleWakeups: add(a.idleWakeups, b.idleWakeups),
            diskRead: add(a.diskRead, b.diskRead), diskWritten: add(a.diskWritten, b.diskWritten))
    }
}

/// Activity's history, in memory only (docs/design/activity/analysis.md,
/// 6.11), after `KubeUsageRing`'s design. Pure; the sampler merges each
/// census into it on its own queue (`merge`) and hands it on with the
/// snapshot — a value. Times are the census's continuous clock
/// (`ActivitySnapshot.historyTime`: `CLOCK_MONOTONIC_RAW`, ns, which runs
/// while the Mac sleeps, so a sleep is a gap, never minutes moved up to
/// now); a test's fake clock fills fifteen minutes at once, and the main
/// actor turns them into dates with the snapshot's own pair.
///
/// Two tiers:
/// - **a strip** for every key a census rated: 60 cells of 15 s (15 min),
///   each the highest and the lowest CPU of its samples and the last
///   footprint — a row's heat strip, and what "held a core" and "idle but
///   burning" read. A cell nothing was sampled in is a gap, never zero:
///   the page was hidden, the app napped, the Mac slept. Every strip's
///   cells are one flat buffer, 8 bytes a cell, written in place: a tick
///   copies it once — the snapshot still holds the last one — never an
///   array a key;
/// - **the detail** for at most `detailLimit` keys, picked once a merge
///   (`detailKeys`) — the focus, the Mac, the agents' subtrees, each tab's
///   total, busiest first —: every sample for 15 minutes, and min/mean/max
///   a minute for an hour. Two samples further apart than `breakAfter` are
///   a break, drawn as a gap.
///
/// A process's history is forgotten `keepEnded` after it ends — a stopped
/// server still shows its last minutes —, a tab's once nothing fed it for
/// as long. Both copies alive at once — the sampler's and the one the last
/// snapshot holds — stay under `byteCap` (4 MB) as `heldBytes` counts
/// them: ended strips go first, then the quietest, then the details.
package struct ActivityRing: Sendable {
    package static let second: UInt64 = 1_000_000_000
    package static let cellLength: UInt64 = 15 * second
    package static let cellCount = 60
    package static let detailSpan: UInt64 = 15 * 60 * second
    /// 15 minutes at the fastest cadence, 1 s.
    package static let detailPoints = 900
    package static let foldLength: UInt64 = 60 * second
    package static let foldCount = 60
    package static let detailLimit = 50
    package static let keepEnded: UInt64 = 15 * 60 * second
    /// The longest interval a rate spans (`ProcessUsage.maximumInterval`):
    /// samples further apart lie across a gap.
    package static let breakAfter: UInt64 = ProcessUsage.maximumInterval
    package static let defaultByteCap = 4 * 1_048_576
    /// The copies alive at once: the sampler's, and the one the last
    /// snapshot (the page's too) still holds while the next tick merges.
    package static let copies = 2

    /// A strip's 15 s, 8 bytes: CPU in tenths of a percent (at most
    /// 6,553.4%), the footprint in KiB; all ones where nothing was sampled.
    package struct Cell: Equatable, Sendable {
        package static let unread = UInt16.max
        package var high = Cell.unread
        package var low = Cell.unread
        package var memory = UInt32.max

        package var isEmpty: Bool { high == Cell.unread }

        package static func tenths(_ cpu: Double) -> UInt16 {
            guard cpu.isFinite else { return 0 }
            return UInt16(min(max(cpu * 10, 0), 65_534).rounded())
        }

        package static func percent(_ tenths: UInt16) -> Double? { tenths == unread ? nil : Double(tenths) / 10 }

        package static func kibibytes(_ bytes: Double) -> UInt32 {
            guard bytes.isFinite else { return .max }
            return UInt32(min(max(bytes / 1_024, 0), 4_294_967_294).rounded())
        }

        /// Bytes; nil unread.
        package var footprint: Double? { memory == .max ? nil : Double(memory) * 1_024 }
    }

    /// A detail's sample; a NaN CPU marks a break.
    package struct Point: Equatable, Sendable {
        package var time: UInt64
        package var cpu: Float32
        package var memory: Float32
        package var energy: Float32
        package var idleWakeups: Float32
        package var diskRead: Float32
        package var diskWritten: Float32

        package var isBreak: Bool { cpu.isNaN }
    }

    /// A minute of a detail's samples, folded.
    package struct Fold: Equatable, Sendable {
        package var minute: UInt64
        package var count: UInt32
        package var lowCPU: Float32
        package var meanCPU: Float32
        package var highCPU: Float32
        package var lowMemory: Float32
        package var meanMemory: Float32
        package var highMemory: Float32
    }

    package struct Strip: Sendable {
        /// Its cells' place in the buffer: `slot × cellCount`, the cell
        /// number modulo the count after it.
        package var slot: Int
        /// The newest cell's number (its time ÷ `cellLength`), and the first's.
        package var newest: UInt64
        package var first: UInt64
        /// When its process was first found gone.
        package var ended: UInt64?
        /// The last CPU sampled, in the newest cell.
        package var last: Float32 = .nan
    }

    package struct Detail: Sendable {
        package var points: [Point] = []
        package var folds: [Fold] = []
        /// When it was last fed: the least recently fed goes first.
        package var fed: UInt64
    }

    package var byteCap: Int
    package private(set) var strips: [ActivityRingKey: Strip] = [:]
    package private(set) var details: [ActivityRingKey: Detail] = [:]
    /// Every strip's cells, `cellCount` a slot.
    private var cells: [Cell] = []
    /// Slots a forgotten strip left, reused first.
    private var freeSlots: [Int] = []
    /// The newest time recorded.
    package private(set) var now: UInt64 = 0

    package init(byteCap: Int = ActivityRing.defaultByteCap) { self.byteCap = byteCap }

    // MARK: Recording

    /// One key's sample at `time`; kept in the detail tier too when
    /// `detail`.
    package mutating func record(_ key: ActivityRingKey, _ sample: ActivityRingSample, at time: UInt64, detail: Bool = false) {
        now = max(now, time)
        let cell = time / Self.cellLength
        let count = UInt64(Self.cellCount)
        if strips[key] == nil { strips[key] = Strip(slot: takeSlot(), newest: cell, first: cell) }
        // In place: the strip's entry and the buffer, never a copy a key.
        withStrip(key) { strip, cells in
            let base = strip.slot * Self.cellCount
            if cell > strip.newest {
                // The cells between are gaps: emptied, at most the whole strip.
                let skipped = min(cell - strip.newest, count)
                for step in 1...skipped { cells[base + Int((strip.newest + step) % count)] = Cell() }
                strip.newest = cell
                strip.last = .nan
            }
            if cell + count > strip.newest {
                let index = base + Int(cell % count)
                let cpu = Cell.tenths(sample.cpu)
                if cells[index].isEmpty {
                    cells[index].high = cpu
                    cells[index].low = cpu
                } else {
                    cells[index].high = max(cells[index].high, cpu)
                    cells[index].low = min(cells[index].low, cpu)
                }
                if cell == strip.newest { strip.last = Float32(sample.cpu) }
                if let memory = sample.memory { cells[index].memory = Cell.kibibytes(memory) }
                strip.first = min(strip.first, cell)
            }
            strip.ended = nil
        }
        if detail { recordDetail(key, sample, at: time) }
    }

    /// `body` over `key`'s strip and the buffer, both written in place.
    private mutating func withStrip(_ key: ActivityRingKey, _ body: (inout Strip, inout [Cell]) -> Void) {
        guard strips[key] != nil else { return }
        body(&strips[key]!, &cells)
    }

    /// A slot for a new strip: a free one emptied, else one more.
    private mutating func takeSlot() -> Int {
        if let slot = freeSlots.popLast() {
            let base = slot * Self.cellCount
            for index in base..<base + Self.cellCount { cells[index] = Cell() }
            return slot
        }
        cells.append(contentsOf: repeatElement(Cell(), count: Self.cellCount))
        return cells.count / Self.cellCount - 1
    }

    /// `key`'s strip and detail forgotten; its slot free.
    private mutating func forget(_ key: ActivityRingKey) {
        if let strip = strips.removeValue(forKey: key) { freeSlots.append(strip.slot) }
        details[key] = nil
    }

    /// The buffer rewritten with the live strips only, when the free slots
    /// are many — `force`d, whenever it holds more than they need: the
    /// forgotten ones' bytes given back.
    private mutating func compact(force: Bool = false) {
        if force {
            guard !freeSlots.isEmpty || cells.capacity > strips.count * Self.cellCount else { return }
        } else {
            guard freeSlots.count > max(16, strips.count / 8) else { return }
        }
        var packed: [Cell] = []
        packed.reserveCapacity(strips.count * Self.cellCount)
        for key in Array(strips.keys) {
            let base = strips[key]!.slot * Self.cellCount
            strips[key]!.slot = packed.count / Self.cellCount
            packed.append(contentsOf: cells[base..<base + Self.cellCount])
        }
        cells = packed
        freeSlots = []
    }

    private mutating func recordDetail(_ key: ActivityRingKey, _ sample: ActivityRingSample, at time: UInt64) {
        if details[key] == nil, details.count >= Self.detailLimit {
            // Outside a merge, which picks its keys first: the least
            // recently fed goes; the Mac's never.
            if let oldest = details.filter({ $0.key != .system }).min(by: { $0.value.fed < $1.value.fed })?.key { details[oldest] = nil }
        }
        if details[key] == nil { details[key] = Detail(fed: time) }
        details[key]!.fed = max(details[key]!.fed, time)
        if let last = details[key]!.points.last(where: { !$0.isBreak }) {
            // A second census within half a second adds nothing.
            if time < last.time + Self.second / 2 { return }
            if time - last.time > Self.breakAfter {
                details[key]!.points.append(
                    Point(time: last.time + 1, cpu: .nan, memory: .nan, energy: .nan, idleWakeups: .nan, diskRead: .nan, diskWritten: .nan))
            }
        }
        func float(_ value: Double?) -> Float32 { value.map { Float32($0) } ?? .nan }
        if details[key]!.points.isEmpty { details[key]!.points.reserveCapacity(64) }
        details[key]!.points.append(
            Point(
                time: time, cpu: Float32(sample.cpu), memory: float(sample.memory), energy: float(sample.energy), idleWakeups: float(sample.idleWakeups),
                diskRead: float(sample.diskRead), diskWritten: float(sample.diskWritten)))
        let oldest = time > Self.detailSpan ? time - Self.detailSpan : 0
        var drop = 0
        let points = details[key]!.points
        while drop < points.count, points[drop].time < oldest || points.count - drop > Self.detailPoints { drop += 1 }
        // A break left first stands for nothing.
        while drop < points.count, points[drop].isBreak { drop += 1 }
        if drop > 0 { details[key]!.points.removeFirst(drop) }

        let minute = time / Self.foldLength
        let cpu = Float32(sample.cpu)
        let memory = float(sample.memory)
        if var fold = details[key]!.folds.last, fold.minute == minute {
            let count = Float32(fold.count)
            fold.lowCPU = min(fold.lowCPU, cpu)
            fold.highCPU = max(fold.highCPU, cpu)
            fold.meanCPU = (fold.meanCPU * count + cpu) / (count + 1)
            if !memory.isNaN {
                fold.lowMemory = fold.lowMemory.isNaN ? memory : min(fold.lowMemory, memory)
                fold.highMemory = fold.highMemory.isNaN ? memory : max(fold.highMemory, memory)
                fold.meanMemory = fold.meanMemory.isNaN ? memory : (fold.meanMemory * count + memory) / (count + 1)
            }
            fold.count += 1
            details[key]!.folds[details[key]!.folds.count - 1] = fold
        } else {
            details[key]!.folds.append(
                Fold(minute: minute, count: 1, lowCPU: cpu, meanCPU: cpu, highCPU: cpu, lowMemory: memory, meanMemory: memory, highMemory: memory))
            let first = minute >= UInt64(Self.foldCount) ? minute - UInt64(Self.foldCount) + 1 : 0
            details[key]!.folds.removeAll { $0.minute < first }
        }
    }

    /// The detail tier's keys for one merge (6.11), at most `detailLimit`,
    /// in order: the focus, the Mac, the agents' subtrees, then the tabs —
    /// each busiest first. Pure.
    package static func detailKeys(
        focus: [ActivityProcessID], system: Bool, agents: [(ActivityProcessID, Double)], tabs: [(UUID, Double)]
    ) -> Set<ActivityRingKey> {
        var keys: [ActivityRingKey] = focus.sorted().map { .process($0) }
        if system { keys.append(.system) }
        keys += agents.sorted { ($0.1, $1.0) > ($1.1, $0.0) }.map { .agent($0.0) }
        keys += tabs.sorted { ($0.1, $1.0.uuidString) > ($1.1, $0.0.uuidString) }.map { .tab($0.0) }
        return Set(keys.prefix(Self.detailLimit))
    }

    /// One census merged (6.11): every rated process of the user's, each
    /// pane's agent's subtree summed, each tab's processes summed, the
    /// Mac's meters, at the snapshot's continuous time. The detail tier's
    /// keys are picked once (`detailKeys`) — a key this merge feeds never
    /// pushes out another it feeds, so no detail is lost and made again
    /// each tick —; the rest are recorded as strips alone. Then what ended
    /// is forgotten in its time, and the cap kept.
    package mutating func merge(_ snapshot: ActivitySnapshot, detail: Set<ActivityProcessID> = []) {
        let time = snapshot.historyNow
        func sample(_ identity: ActivityProcessID) -> ActivityRingSample? {
            guard let facts = snapshot.facts[identity], let rates = facts.rates else { return nil }
            return ActivityRingSample(rates, usage: facts.usage)
        }
        var agents: [(ActivityProcessID, ActivityRingSample)] = []
        var seen = Set<ActivityProcessID>()
        var tabMembers: [UUID: Set<ActivityProcessID>] = [:]
        for slice in snapshot.panes {
            tabMembers[slice.tab, default: []].formUnion(slice.placed)
            guard let agent = slice.agent, seen.insert(agent).inserted, var sum = sample(agent) else { continue }
            for process in snapshot.table.descendants(of: agent, limit: 2_000) {
                if let part = sample(process.identity) { sum = sum + part }
            }
            agents.append((agent, sum))
        }
        var tabs: [(UUID, ActivityRingSample)] = []
        for (tab, members) in tabMembers {
            var sum: ActivityRingSample?
            for member in members {
                guard let part = sample(member) else { continue }
                sum = sum.map { $0 + part } ?? part
            }
            if let sum { tabs.append((tab, sum)) }
        }
        let system = snapshot.meters.flatMap { meters in meters.cpu.map { ActivityRingSample(cpu: $0 * 100, memory: Double(meters.used)) } }
        let focus = detail.filter { sample($0) != nil }
        let chosen = Self.detailKeys(
            focus: Array(focus), system: system != nil, agents: agents.map { ($0.0, $0.1.cpu) }, tabs: tabs.map { ($0.0, $0.1.cpu) })
        // Room for the chosen first: keys not chosen this merge go, the
        // least recently fed first — the Mac's never.
        let wanted = chosen.count { details[$0] == nil }
        if details.count + wanted > Self.detailLimit {
            let spare = details.filter { !chosen.contains($0.key) && $0.key != .system }.sorted { $0.value.fed < $1.value.fed }
            for (key, _) in spare.prefix(details.count + wanted - Self.detailLimit) { details[key] = nil }
        }
        for (identity, facts) in snapshot.facts {
            guard let rates = facts.rates else { continue }
            record(.process(identity), ActivityRingSample(rates, usage: facts.usage), at: time, detail: chosen.contains(.process(identity)))
        }
        for (agent, sum) in agents { record(.agent(agent), sum, at: time, detail: chosen.contains(.agent(agent))) }
        for (tab, sum) in tabs { record(.tab(tab), sum, at: time, detail: chosen.contains(.tab(tab))) }
        if let system { record(.system, system, at: time, detail: chosen.contains(.system)) }
        forgetEnded(live: { snapshot.table.process($0) != nil }, at: time)
        keepUnderCap()
    }

    /// What ended `keepEnded` ago goes, and a tab nothing fed for as long.
    package mutating func forgetEnded(live: (ActivityProcessID) -> Bool, at time: UInt64) {
        let oldestCell = time / Self.cellLength
        var gone: [ActivityRingKey] = []
        for (key, strip) in strips {
            if let identity = key.identity {
                if live(identity) {
                    if strip.ended != nil { strips[key]?.ended = nil }
                    continue
                }
                guard let ended = strip.ended else {
                    strips[key]?.ended = time
                    continue
                }
                if time >= ended + Self.keepEnded { gone.append(key) }
            } else if key != .system, (oldestCell - min(oldestCell, strip.newest)) * Self.cellLength >= Self.keepEnded {
                gone.append(key)
            }
        }
        for key in gone { forget(key) }
        for key in details.keys where strips[key] == nil { details[key] = nil }
        compact()
    }

    /// Back under `byteCap`, both copies counted (`heldBytes`): ended
    /// strips first, oldest ended first, then the quietest, then the
    /// details least recently fed.
    package mutating func keepUnderCap() {
        compact()
        guard heldBytes > byteCap else { return }
        // Counted as packed — the buffer holding the live strips alone —,
        // with room for malloc's rounding of it.
        let cellBytes = MemoryLayout<Cell>.stride
        var total = heldBytes - Self.copies * (cells.capacity - strips.count * Self.cellCount) * cellBytes + Self.copies * Self.rounding
        let stripBytes = Self.copies * Self.bytesPerStrip
        var peaks: [ActivityRingKey: UInt16] = [:]
        for (key, strip) in strips where details[key] == nil && key != .system && strip.ended == nil { peaks[key] = peak(strip) }
        let stripsByOrder = strips.filter { details[$0.key] == nil && $0.key != .system }
            .sorted { a, b in
                switch (a.value.ended, b.value.ended) {
                case (let x?, let y?): return x < y
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return (peaks[a.key] ?? 0) < (peaks[b.key] ?? 0)
                }
            }
        for (key, _) in stripsByOrder {
            guard total > byteCap else { break }
            total -= stripBytes
            forget(key)
        }
        for (key, detail) in details.filter({ $0.key != .system }).sorted(by: { $0.value.fed < $1.value.fed }) {
            guard total > byteCap else { break }
            total -= Self.copies * Self.bytes(of: detail)
            if strips[key] != nil { total -= stripBytes }
            forget(key)
        }
        compact(force: true)
    }

    private func peak(_ strip: Strip) -> UInt16 {
        let base = strip.slot * Self.cellCount
        var high: UInt16 = 0
        var any = false
        for index in base..<base + Self.cellCount where !cells[index].isEmpty {
            high = max(high, cells[index].high)
            any = true
        }
        return any ? high + 1 : 0
    }

    /// `strip`'s cell `number`.
    private func cell(_ strip: Strip, _ number: UInt64) -> Cell {
        cells[strip.slot * Self.cellCount + Int(number % UInt64(Self.cellCount))]
    }

    // MARK: Reading

    /// `key`'s CPU, a cell each, oldest first, the last the cell `now` is
    /// in: nil where nothing was sampled — or nil when it has no strip.
    package func cpuStrip(_ key: ActivityRingKey, now: UInt64? = nil) -> [Double?]? {
        guard let strip = strips[key] else { return nil }
        let current = (now ?? self.now) / Self.cellLength
        return (0..<Self.cellCount).map { index in
            let number = current + UInt64(index) + 1
            guard number >= UInt64(Self.cellCount) else { return nil }
            let cell = number - UInt64(Self.cellCount)
            guard cell <= strip.newest, cell + UInt64(Self.cellCount) > strip.newest else { return nil }
            return Cell.percent(self.cell(strip, cell).high)
        }
    }

    /// When `key`'s strip began, when that is inside the 15 minutes shown:
    /// "since 13:40". Nil for one older than the window, or none.
    package func since(_ key: ActivityRingKey, now: UInt64? = nil) -> UInt64? {
        guard let strip = strips[key] else { return nil }
        let current = (now ?? self.now) / Self.cellLength
        guard strip.first + UInt64(Self.cellCount) > current + 1 else { return nil }
        return strip.first * Self.cellLength
    }

    /// Since when `key`'s CPU has stayed at `atLeast` or more, cell by
    /// cell, up to its newest — no gap between, and the newest no older
    /// than the cell before `now`'s: the start of that run, nil when there
    /// is none. glances' rule: a level must last before it is an event —
    /// the caller asks how long.
    package func sustained(_ key: ActivityRingKey, atLeast threshold: Double, now: UInt64? = nil) -> UInt64? {
        guard let strip = strips[key], strip.ended == nil else { return nil }
        let current = (now ?? self.now) / Self.cellLength
        guard strip.newest + 1 >= current else { return nil }
        var start: UInt64?
        var number = strip.newest
        for _ in 0..<Self.cellCount {
            guard number + UInt64(Self.cellCount) > strip.newest, number >= strip.first else { break }
            guard let low = Cell.percent(cell(strip, number).low), low >= threshold else { break }
            start = number
            guard number > 0 else { break }
            number -= 1
        }
        return start.map { $0 * Self.cellLength }
    }

    /// `key`'s last CPU sampled, in its newest cell.
    package func lastCPU(_ key: ActivityRingKey) -> Double? {
        guard let strip = strips[key], !strip.last.isNaN else { return nil }
        return Double(strip.last)
    }

    /// `key`'s samples for the last 15 minutes, breaks among them.
    package func points(_ key: ActivityRingKey) -> [Point] { details[key]?.points ?? [] }

    /// `key`'s strip as points, for a key with no detail yet (a row just
    /// selected): each cell's highest CPU and last footprint at its
    /// middle, a break between cells not side by side.
    package func cellPoints(_ key: ActivityRingKey, now: UInt64? = nil) -> [Point] {
        guard let strip = strips[key] else { return [] }
        let current = (now ?? self.now) / Self.cellLength
        var points: [Point] = []
        var previous: UInt64?
        let first = current >= UInt64(Self.cellCount - 1) ? current - UInt64(Self.cellCount - 1) : 0
        for number in first...current {
            guard number <= strip.newest, number + UInt64(Self.cellCount) > strip.newest, number >= strip.first else { continue }
            let kept = cell(strip, number)
            guard let high = Cell.percent(kept.high) else { continue }
            let time = number * Self.cellLength + Self.cellLength / 2
            if let previous, number > previous + 1 {
                points.append(Point(time: time - 1, cpu: .nan, memory: .nan, energy: .nan, idleWakeups: .nan, diskRead: .nan, diskWritten: .nan))
            }
            points.append(
                Point(
                    time: time, cpu: Float32(high), memory: kept.footprint.map { Float32($0) } ?? .nan, energy: .nan, idleWakeups: .nan, diskRead: .nan,
                    diskWritten: .nan))
            previous = number
        }
        return points
    }

    /// `key`'s minutes for the last hour.
    package func folds(_ key: ActivityRingKey) -> [Fold] { details[key]?.folds ?? [] }

    /// The least, the mean and the most of `key`'s CPU over its folded hour.
    package func hourCPU(_ key: ActivityRingKey) -> (low: Double, mean: Double, high: Double, minutes: Int)? {
        let folds = folds(key)
        guard !folds.isEmpty else { return nil }
        let count = folds.reduce(0) { $0 + Double($1.count) }
        let mean = folds.reduce(0) { $0 + Double($1.meanCPU) * Double($1.count) } / max(count, 1)
        return (Double(folds.map(\.lowCPU).min() ?? 0), mean, Double(folds.map(\.highCPU).max() ?? 0), folds.count)
    }

    /// The footprint over the folded hour: the first minute's mean and the
    /// last's, bytes — its trend. Nil without two minutes read.
    package func hourMemory(_ key: ActivityRingKey) -> (first: Double, last: Double, high: Double, minutes: Int)? {
        let read = folds(key).filter { !$0.meanMemory.isNaN }
        guard read.count >= 2, let first = read.first, let last = read.last else { return nil }
        return (Double(first.meanMemory), Double(last.meanMemory), Double(read.map(\.highMemory).max() ?? 0), read.count)
    }

    /// The least, the mean and the most of `key`'s CPU over its 15 minutes
    /// of samples, breaks left out.
    package func spanCPU(_ key: ActivityRingKey) -> (low: Double, mean: Double, high: Double, samples: Int)? {
        let read = points(key).filter { !$0.isBreak }
        guard !read.isEmpty else { return nil }
        let values = read.map { Double($0.cpu) }
        return (values.min() ?? 0, values.reduce(0, +) / Double(values.count), values.max() ?? 0, values.count)
    }

    /// Whether `key` has a detail tier.
    package func hasDetail(_ key: ActivityRingKey) -> Bool { details[key] != nil }

    // MARK: Size

    /// A heap buffer's header (object header, count, capacity) and malloc's rounding, about.
    private static let bufferHeader = 48
    /// A dictionary entry: its key, its value's inline part, its bucket.
    private static let entry = MemoryLayout<ActivityRingKey>.stride + 1
    /// What malloc may round a packed buffer up by, about.
    private static let rounding = 4_096
    /// A strip, packed: its entry and its cells.
    package static let bytesPerStrip = entry + MemoryLayout<Strip>.stride + cellCount * MemoryLayout<Cell>.stride

    private static func bytes(of detail: Detail) -> Int {
        var total = entry + MemoryLayout<Detail>.stride
        if detail.points.capacity > 0 { total += bufferHeader + detail.points.capacity * MemoryLayout<Point>.stride }
        if detail.folds.capacity > 0 { total += bufferHeader + detail.folds.capacity * MemoryLayout<Fold>.stride }
        return total
    }

    /// What one copy takes on the heap, as `KubeUsageRing.bytes` counts it:
    /// each array's whole capacity with its header, each entry.
    package var bytes: Int {
        var total = strips.count * (Self.entry + MemoryLayout<Strip>.stride) + details.values.reduce(0) { $0 + Self.bytes(of: $1) }
        if cells.capacity > 0 { total += Self.bufferHeader + cells.capacity * MemoryLayout<Cell>.stride }
        if freeSlots.capacity > 0 { total += Self.bufferHeader + freeSlots.capacity * MemoryLayout<Int>.stride }
        return total
    }

    /// What the history holds on the heap at once: the sampler's copy and
    /// the one the last snapshot still holds (`copies`) — what the cap is.
    package var heldBytes: Int { Self.copies * bytes }

    package var keyCount: Int { strips.count }
    package var detailCount: Int { details.count }
}
