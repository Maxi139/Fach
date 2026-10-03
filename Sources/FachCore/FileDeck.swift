import Foundation

/// A stable, session-only sequence for reviewing files one at a time.
/// Filtering the surrounding UI never changes this deck. Call `reconcile` only
/// when a file is no longer safe to handle (for example after it was moved).
public struct FileDeck: Sendable, Equatable {
    public private(set) var orderedIDs: [UUID]
    public private(set) var handledIDs: Set<UUID>
    private var currentIndex: Int?

    public init(ids: [UUID] = [], preferredID: UUID? = nil) {
        var seen: Set<UUID> = []
        orderedIDs = ids.filter { seen.insert($0).inserted }
        handledIDs = []
        currentIndex = preferredID.flatMap { orderedIDs.firstIndex(of: $0) } ?? orderedIDs.indices.first
    }

    public var currentID: UUID? {
        guard let currentIndex, orderedIDs.indices.contains(currentIndex) else { return nil }
        return orderedIDs[currentIndex]
    }

    /// One-based position in the original deck, useful for a compact progress
    /// indicator. It is nil after the final item was handled.
    public var position: Int? { currentIndex.map { $0 + 1 } }
    public var count: Int { orderedIDs.count }
    public var remainingCount: Int { orderedIDs.filter { !handledIDs.contains($0) }.count }
    public var isFinished: Bool { remainingCount == 0 }

    /// Moves to the next (positive direction) or previous (negative direction)
    /// unhandled item. Reaching either edge leaves the current item in place.
    @discardableResult
    public mutating func navigate(direction: Int) -> UUID? {
        guard direction != 0, let currentIndex else { return currentID }
        let step = direction > 0 ? 1 : -1
        var index = currentIndex + step
        while orderedIDs.indices.contains(index) {
            if !handledIDs.contains(orderedIDs[index]) {
                self.currentIndex = index
                break
            }
            index += step
        }
        return currentID
    }

    /// Records the current file as handled and continues like a stack: prefer
    /// the following item, then use the preceding remaining item at the end.
    @discardableResult
    public mutating func handleCurrent() -> UUID? {
        guard let currentID, let currentIndex else { return nil }
        handledIDs.insert(currentID)

        if let next = firstUnprocessedIndex(startingAt: currentIndex + 1, step: 1) {
            self.currentIndex = next
        } else if let previous = firstUnprocessedIndex(startingAt: currentIndex - 1, step: -1) {
            self.currentIndex = previous
        } else {
            self.currentIndex = nil
        }
        return self.currentID
    }

    /// Removes files which have been moved, protected, or otherwise became
    /// unavailable outside the deck. UI filtering must not call this method.
    @discardableResult
    public mutating func reconcile(availableIDs: Set<UUID>) -> UUID? {
        let previousCurrent = currentID
        let previousOrder = orderedIDs
        let previousIndex = currentIndex
        orderedIDs.removeAll { !availableIDs.contains($0) }
        handledIDs.formIntersection(availableIDs)

        guard !orderedIDs.isEmpty else {
            currentIndex = nil
            return nil
        }
        if let previousCurrent, let preservedIndex = orderedIDs.firstIndex(of: previousCurrent), !handledIDs.contains(previousCurrent) {
            currentIndex = preservedIndex
        } else if let previousIndex,
                  let following = firstAvailableID(in: previousOrder, startingAt: previousIndex + 1, step: 1),
                  let nextIndex = orderedIDs.firstIndex(of: following) {
            currentIndex = nextIndex
        } else if let previousIndex,
                  let preceding = firstAvailableID(in: previousOrder, startingAt: previousIndex - 1, step: -1),
                  let previousIndex = orderedIDs.firstIndex(of: preceding) {
            currentIndex = previousIndex
        } else if let first = orderedIDs.indices.first(where: { !handledIDs.contains(orderedIDs[$0]) }) {
            currentIndex = first
        } else {
            currentIndex = nil
        }
        return currentID
    }

    private func firstUnprocessedIndex(startingAt start: Int, step: Int) -> Int? {
        var index = start
        while orderedIDs.indices.contains(index) {
            if !handledIDs.contains(orderedIDs[index]) { return index }
            index += step
        }
        return nil
    }

    private func firstAvailableID(in ids: [UUID], startingAt start: Int, step: Int) -> UUID? {
        var index = start
        while ids.indices.contains(index) {
            let id = ids[index]
            if orderedIDs.contains(id), !handledIDs.contains(id) { return id }
            index += step
        }
        return nil
    }
}
