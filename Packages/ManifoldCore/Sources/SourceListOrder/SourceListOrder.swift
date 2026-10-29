//
//  SourceListOrder.swift
//  Manifold — the order a discovered-source list is shown in, and whether a poll changed it.
//
//  Measured 2026-10-29 (the NDI flyout jitter, docs/BUGS.md): NDI discovery polls once a second, and
//  publishing every poll re-applied the whole streaming menu under the pointer, sources or not. And the
//  SDK's order is its own: a source that arrives can land ABOVE the row the pointer is on and push it down.
//  So a poll is folded into the list already shown: rows still present keep their places, new rows go at
//  the end, gone rows leave. The caller publishes only when `changed` says the result differs.
//

public enum SourceListOrder {

    /// `polled`'s sources, in `shown`'s order: each source still present keeps its place, sources new to the
    /// list follow in the order `polled` gives them, and sources no longer polled are dropped. The elements
    /// are `polled`'s, never `shown`'s, so a source's other fields are always the latest. A repeated id in
    /// `polled` keeps its first occurrence.
    public static func merged<Element, ID: Hashable>(shown: [Element], polled: [Element],
                                                     id: (Element) -> ID) -> [Element] {
        var latest: [ID: Element] = [:]
        var arrivals: [Element] = []
        for element in polled where latest[id(element)] == nil {
            latest[id(element)] = element
            arrivals.append(element)
        }
        var result: [Element] = []
        var placed = Set<ID>()
        for element in shown {
            let key = id(element)
            if let fresh = latest[key], placed.insert(key).inserted { result.append(fresh) }
        }
        for element in arrivals where !placed.contains(id(element)) { result.append(element) }
        return result
    }

    /// Whether `next` differs from `shown` in membership, order or any compared field.
    public static func changed<Element, Fields: Equatable>(_ shown: [Element], _ next: [Element],
                                                           fields: (Element) -> Fields) -> Bool {
        !shown.map(fields).elementsEqual(next.map(fields))
    }
}
