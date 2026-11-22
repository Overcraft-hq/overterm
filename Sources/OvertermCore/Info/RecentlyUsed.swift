/// A dictionary that keeps only the `capacity` keys set most recently —
/// for per-file parse state that would otherwise grow with every Claude
/// session ever read, over a week of agents working.
package struct RecentlyUsed<Key: Hashable, Value> {
    package let capacity: Int
    private var entries: [Key: (value: Value, stamp: UInt64)] = [:]
    private var clock: UInt64 = 0

    package init(capacity: Int) {
        self.capacity = capacity
    }

    package var count: Int { entries.count }

    /// Reading doesn't count as use; setting does (the readers read, parse
    /// what was appended, then set).
    package subscript(key: Key) -> Value? {
        get { entries[key]?.value }
        set {
            guard let newValue else {
                entries[key] = nil
                return
            }
            clock += 1
            entries[key] = (newValue, clock)
            if entries.count > capacity, let oldest = entries.min(by: { $0.value.stamp < $1.value.stamp })?.key {
                entries[oldest] = nil
            }
        }
    }
}
