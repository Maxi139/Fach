import Foundation

/// Selects only existing, unchanged file assignments for an explicitly
/// user-approved bulk confirmation. It never creates or changes a target.
public enum AssignmentReview {
    public static func batchCandidates(
        recommendations: [Recommendation],
        existingTargets: [URL],
        completedIDs: Set<UUID>,
        protectedIDs: Set<UUID>
    ) -> [Recommendation] {
        let knownTargetPaths = Set(existingTargets.map { $0.standardizedFileURL.path })

        return recommendations.filter { recommendation in
            guard let target = recommendation.targetFolder else { return false }
            return knownTargetPaths.contains(target.standardizedFileURL.path) &&
                !recommendation.file.isDirectory &&
                !recommendation.file.isProtected &&
                !(recommendation.requiresIndividualReview ?? false) &&
                !completedIDs.contains(recommendation.id) &&
                !protectedIDs.contains(recommendation.id)
        }
    }
}
