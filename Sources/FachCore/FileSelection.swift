import Foundation

/// Pure selection rules for the file grid. The caller passes only files that
/// are currently selectable, so hidden or protected entries can never enter a
/// selection through a range action.
public enum FileSelection {
    public static func toggled(
        id: UUID,
        selected: Set<UUID>,
        orderedIDs: [UUID],
        anchor: UUID?,
        extendingRange: Bool = false
    ) -> Set<UUID> {
        let selectable = Set(orderedIDs)
        guard selectable.contains(id) else { return selected.intersection(selectable) }

        var result = selected.intersection(selectable)
        if extendingRange, let anchor, let start = orderedIDs.firstIndex(of: anchor), let end = orderedIDs.firstIndex(of: id) {
            result.formUnion(orderedIDs[min(start, end)...max(start, end)])
            return result
        }

        if result.contains(id) { result.remove(id) }
        else { result.insert(id) }
        return result
    }
}
