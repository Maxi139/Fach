import Foundation
import Testing
@testable import FachCore

@Suite("AssignmentReviewTests") struct AssignmentReviewTests {
    @Test func bulkCandidatesIncludeLowConfidenceAndRecoveredAssignmentsWithKnownTargets() {
        let root = URL(fileURLWithPath: "/synthetic-review")
        let archive = root.appendingPathComponent("Archive", isDirectory: true)
        let candidate = recommendation(root: root, name: "low-confidence.txt", target: archive,
                                       confidence: 0.12, requiresIndividualReview: nil)
        let recovered = recommendation(root: root, name: "recovered.txt", target: archive,
                                       confidence: 0, requiresIndividualReview: nil)
        let candidates = AssignmentReview.batchCandidates(
            recommendations: [candidate, recovered], existingTargets: [archive],
            completedIDs: [], protectedIDs: [])

        #expect(Set(candidates.map(\.id)) == Set([candidate.id, recovered.id]))
    }

    @Test func bulkCandidatesExcludeMissingUnsafeOrStaleAssignments() {
        let root = URL(fileURLWithPath: "/synthetic-review")
        let archive = root.appendingPathComponent("Archive", isDirectory: true)
        let newTarget = root.appendingPathComponent("New folder", isDirectory: true)
        let noTarget = recommendation(root: root, name: "unassigned.txt", target: nil)
        let unknownTarget = recommendation(root: root, name: "new-target.txt", target: newTarget)
        let directory = recommendation(root: root, name: "folder", target: archive, isDirectory: true)
        let protectedFile = recommendation(root: root, name: "protected.txt", target: archive, isProtected: true)
        let completed = recommendation(root: root, name: "completed.txt", target: archive)
        let protectedID = recommendation(root: root, name: "protected-id.txt", target: archive)
        let stale = recommendation(root: root, name: "changed.txt", target: archive, requiresIndividualReview: true)

        let candidates = AssignmentReview.batchCandidates(
            recommendations: [noTarget, unknownTarget, directory, protectedFile, completed, protectedID, stale],
            existingTargets: [archive], completedIDs: [completed.id], protectedIDs: [protectedID.id])

        #expect(candidates.isEmpty)
    }

    @Test func legacyRecommendationWithoutReviewFlagDecodes() throws {
        let root = URL(fileURLWithPath: "/synthetic-review")
        let original = recommendation(root: root, name: "legacy.txt", target: root.appendingPathComponent("Archive"))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "requiresIndividualReview")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Recommendation.self, from: legacyData)

        #expect(decoded.requiresIndividualReview == nil)
        #expect(decoded.id == original.id)
    }

    private func recommendation(
        root: URL,
        name: String,
        target: URL?,
        confidence: Double = 0.75,
        isDirectory: Bool = false,
        isProtected: Bool = false,
        requiresIndividualReview: Bool? = nil
    ) -> Recommendation {
        let file = FileSnapshot(url: root.appendingPathComponent(name), size: 1, modifiedAt: .now,
                                isDirectory: isDirectory, isProtected: isProtected)
        return Recommendation(file: file, targetFolder: target, confidence: confidence,
                              needsQuestion: true, requiresIndividualReview: requiresIndividualReview)
    }
}
