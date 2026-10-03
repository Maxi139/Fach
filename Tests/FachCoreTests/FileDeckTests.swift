import Foundation
import Testing
@testable import FachCore

@Suite("FileDeckTests") struct FileDeckTests {
    private let ids = [UUID(), UUID(), UUID(), UUID()]

    @Test func emptyDeckHasNoCurrentFile() {
        var deck = FileDeck()
        #expect(deck.currentID == nil)
        #expect(deck.count == 0)
        #expect(deck.remainingCount == 0)
        #expect(deck.navigate(direction: 1) == nil)
    }

    @Test func preferredFileStartsTheDeckAndEdgesDoNotWrap() {
        var deck = FileDeck(ids: ids, preferredID: ids[2])
        #expect(deck.currentID == ids[2])
        #expect(deck.position == 3)
        #expect(deck.navigate(direction: 1) == ids[3])
        #expect(deck.navigate(direction: 1) == ids[3])
        #expect(deck.navigate(direction: -1) == ids[2])
    }

    @Test func handlingCurrentAdvancesAndFallsBackToPreviousAtEnd() {
        var deck = FileDeck(ids: ids)
        #expect(deck.handleCurrent() == ids[1])
        #expect(deck.handleCurrent() == ids[2])
        #expect(deck.handleCurrent() == ids[3])
        #expect(deck.remainingCount == 1)
        #expect(deck.handleCurrent() == nil)
        #expect(deck.isFinished)
        #expect(deck.handledIDs == Set(ids))
    }

    @Test func handlingTheLastFileContinuesWithThePreviousRemainingFile() {
        var deck = FileDeck(ids: ids, preferredID: ids[3])
        #expect(deck.handleCurrent() == ids[2])
        #expect(deck.currentID == ids[2])
        #expect(deck.remainingCount == 3)
    }

    @Test func navigationSkipsHandledFiles() {
        var deck = FileDeck(ids: ids)
        _ = deck.handleCurrent()
        #expect(deck.currentID == ids[1])
        #expect(deck.navigate(direction: -1) == ids[1])
        #expect(deck.navigate(direction: 1) == ids[2])
    }

    @Test func reconciliationDropsRemovedFilesWithoutChangingFilteringContract() {
        var deck = FileDeck(ids: ids, preferredID: ids[2])
        _ = deck.reconcile(availableIDs: Set([ids[0], ids[2], ids[3]]))
        #expect(deck.orderedIDs == [ids[0], ids[2], ids[3]])
        #expect(deck.currentID == ids[2])
        #expect(deck.count == 3)

        _ = deck.reconcile(availableIDs: Set([ids[0], ids[3]]))
        #expect(deck.currentID == ids[3])
        #expect(deck.remainingCount == 2)
    }

    @Test func duplicateIDsAreOnlyIncludedOnce() {
        let deck = FileDeck(ids: [ids[0], ids[1], ids[0]])
        #expect(deck.orderedIDs == [ids[0], ids[1]])
    }
}
