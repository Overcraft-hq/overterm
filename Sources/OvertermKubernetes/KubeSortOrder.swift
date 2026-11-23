import Foundation

/// `ResourceSort.sorted`, kept in this module: a generic in another module
/// is never specialised here (`@inlinable` doesn't carry its body across
/// the package's modules), and the unspecialised one boxes every key —
/// Activity's 5,000 rows took 8 ms instead of 0.9 that way. Same order:
/// by `key`, either way; equal keys, and those with none (last either
/// way), in the order they came. Pure.
enum KubeSortOrder {
    static func sorted<Item, Key: Comparable>(_ items: [Item], _ sort: ResourceSort, by key: (Item) -> Key?) -> [Item] {
        let keyed = items.map(key)
        let ascending = sort.ascending
        return items.indices
            .sorted { a, b in
                switch (keyed[a], keyed[b]) {
                case (let x?, let y?) where x != y: ascending ? x < y : x > y
                case (.some, nil): true
                case (nil, .some): false
                default: a < b
                }
            }
            .map { items[$0] }
    }
}
