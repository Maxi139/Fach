import Foundation
import Testing
@testable import FachCore

@Suite("FileSelectionTests") struct FileSelectionTests {
    private let ids = [UUID(), UUID(), UUID(), UUID()]

    @Test func plainClickAddsAndRemovesAnEntry() {
        let added = FileSelection.toggled(id: ids[1], selected: [ids[0]], orderedIDs: ids, anchor: ids[0])
        #expect(added == Set([ids[0], ids[1]]))
        let removed = FileSelection.toggled(id: ids[1], selected: added, orderedIDs: ids, anchor: ids[1])
        #expect(removed == Set([ids[0]]))
    }

    @Test func shiftClickAddsTheContiguousRangeInEitherDirection() {
        let forward = FileSelection.toggled(id: ids[3], selected: [ids[0]], orderedIDs: ids, anchor: ids[1], extendingRange: true)
        #expect(forward == Set(ids))
        let backward = FileSelection.toggled(id: ids[0], selected: [], orderedIDs: ids, anchor: ids[3], extendingRange: true)
        #expect(backward == Set(ids))
    }

    @Test func missingAnchorFallsBackToAnOrdinaryToggle() {
        let result = FileSelection.toggled(id: ids[2], selected: [ids[0]], orderedIDs: ids, anchor: UUID(), extendingRange: true)
        #expect(result == Set([ids[0], ids[2]]))
    }

    @Test func hiddenAndProtectedIDsCannotRemainSelected() {
        let visible = [ids[0], ids[2]]
        let result = FileSelection.toggled(id: ids[2], selected: Set(ids), orderedIDs: visible, anchor: ids[0], extendingRange: true)
        #expect(result == Set(visible))
        let ignored = FileSelection.toggled(id: ids[1], selected: result, orderedIDs: visible, anchor: ids[0])
        #expect(ignored == Set(visible))
    }
}
