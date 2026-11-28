import Foundation

/// ⌃⌘G as it is typed into (GRP-U1): the islands whose name, or one of
/// whose tabs' titles, matches what was typed — the palette's matching
/// (`FuzzyMatch`) — and, of the highlighted one, its tabs that match, or
/// all of them when its name does. Pure.
@MainActor
package enum GroupSwitcherFilter {
    /// Every island in the strip's order, stashed ones last.
    package static func order(_ store: TabStore) -> [TabGroup] {
        var seen: [TabGroup] = []
        for case .group(let g, _) in store.strip where !seen.contains(where: { $0.id == g.id }) { seen.append(g) }
        return seen + store.stashedGroups
    }

    package static func matches(_ text: String, _ query: String) -> Bool {
        query.isEmpty || FuzzyMatch.score(query, in: text) != nil
    }

    package static func groups(_ all: [TabGroup], tabs: (TabGroup) -> [Tab], query: String) -> [TabGroup] {
        guard !query.isEmpty else { return all }
        return all.filter { group in matches(group.name, query) || tabs(group).contains { matches($0.title, query) } }
    }

    package static func tabs(of group: TabGroup, _ tabs: [Tab], query: String) -> [Tab] {
        matches(group.name, query) ? tabs : tabs.filter { matches($0.title, query) }
    }

    /// What a typed key does to the query: a character added, ⌫ taking
    /// the last one off; nil for a key that types nothing (an arrow, a
    /// shortcut).
    package static func query(_ query: String, typing characters: String?, delete: Bool, modifiers: Bool) -> String? {
        if delete { return query.isEmpty ? nil : String(query.dropLast()) }
        guard !modifiers, let characters, !characters.isEmpty,
            characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 })
        else { return nil }
        return query + characters
    }
}
