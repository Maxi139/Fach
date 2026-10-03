import Foundation

/// A durable, local-only checkpoint for an unfinished analysis.  It deliberately
/// contains no credentials and no cloud-consent state.
public struct AnalysisDraft: Codable, Sendable {
    public static let schemaVersion = 1

    public var version: Int
    public var source: URL
    public var destination: URL?
    public var useSeparateDestination: Bool
    public var recursive: Bool
    public var context: String
    /// Opaque application configuration data. FachCore never interprets it, so it
    /// does not depend on FachAI.
    public var configurationData: Data?
    public var files: [FileSnapshot]
    public var folders: [URL]
    public var recommendations: [Recommendation]
    public var folderProposals: [FolderProposal]
    public var structureProposals: [FolderProposal]
    public var showStructureReview: Bool
    public var restructuring: Bool
    public var acceptedFolders: [URL]
    public var protectedIDs: Set<UUID>
    public var completedIDs: Set<UUID>
    public var manualSignatures: [UUID: String]
    public var inputSignature: String?
    public var analyzedSignature: String?
    public var spentUSD: Double
    public var reservedUSD: Double

    public init(source: URL, destination: URL? = nil, useSeparateDestination: Bool = false,
                recursive: Bool, context: String, configurationData: Data? = nil,
                files: [FileSnapshot], folders: [URL], recommendations: [Recommendation],
                folderProposals: [FolderProposal] = [], structureProposals: [FolderProposal] = [],
                showStructureReview: Bool = false, restructuring: Bool = false,
                acceptedFolders: [URL] = [], protectedIDs: Set<UUID> = [],
                completedIDs: Set<UUID> = [], manualSignatures: [UUID: String] = [:],
                inputSignature: String? = nil, analyzedSignature: String? = nil,
                spentUSD: Double = 0, reservedUSD: Double = 0) {
        version = Self.schemaVersion
        self.source = source.standardizedFileURL
        self.destination = destination?.standardizedFileURL
        self.useSeparateDestination = useSeparateDestination
        self.recursive = recursive
        self.context = context
        self.configurationData = configurationData
        self.files = files
        self.folders = folders
        self.recommendations = recommendations
        self.folderProposals = folderProposals
        self.structureProposals = structureProposals
        self.showStructureReview = showStructureReview
        self.restructuring = restructuring
        self.acceptedFolders = acceptedFolders
        self.protectedIDs = protectedIDs
        self.completedIDs = completedIDs
        self.manualSignatures = manualSignatures
        self.inputSignature = inputSignature
        self.analyzedSignature = analyzedSignature
        self.spentUSD = spentUSD
        self.reservedUSD = reservedUSD
    }

    public static func load(from url: URL) throws -> AnalysisDraft {
        let draft = try JSONDecoder().decode(AnalysisDraft.self, from: Data(contentsOf: url))
        guard draft.version == schemaVersion else { throw FachError.message("Gesicherte Analyse hat ein unbekanntes Format.") }
        try validate(draft)
        return draft
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public struct Restoration: Sendable {
        public var files: [FileSnapshot]
        public var folders: [URL]
        public var recommendations: [Recommendation]
        public var folderProposals: [FolderProposal]
        public var structureProposals: [FolderProposal]
        public var acceptedFolders: [URL]
        public var protectedIDs: Set<UUID>
        public var completedIDs: Set<UUID>
        public var manualSignatures: [UUID: String]
        public var staleIDs: Set<UUID>
    }

    /// Re-check every saved snapshot before using a restored proposal. Changed
    /// files remain visible, but lose their automatic/manual eligibility until a
    /// user confirms them again.
    public func restore() -> Restoration {
        let root = (useSeparateDestination ? destination : source)?.standardizedFileURL ?? source.standardizedFileURL
        let savedIDs = Set(files.map(\.id))
        var restoredFiles: [FileSnapshot] = []
        var staleIDs: Set<UUID> = []

        for saved in files {
            guard isWithin(saved.url, root: source) else { continue }
            guard let current = try? FileSafety.snapshot(saved.url), snapshotsMatch(saved, current) else {
                staleIDs.insert(saved.id)
                if let current = try? FileSafety.snapshot(saved.url) {
                    var changed = current
                    changed.id = saved.id
                    restoredFiles.append(changed)
                }
                continue
            }
            var unchanged = current
            unchanged.id = saved.id
            restoredFiles.append(unchanged)
        }

        let validIDs = Set(restoredFiles.map(\.id))
        var restoredRecommendations: [Recommendation] = []
        for recommendation in recommendations where validIDs.contains(recommendation.id) && savedIDs.contains(recommendation.id) {
            var recommendation = recommendation
            guard let file = restoredFiles.first(where: { $0.id == recommendation.id }) else { continue }
            recommendation.file = file
            if !isWithin(recommendation.targetFolder, root: root) { recommendation.targetFolder = nil }
            if staleIDs.contains(recommendation.id) {
                recommendation.confidence = 0
                recommendation.margin = 0
                recommendation.isApproved = false
                recommendation.needsQuestion = true
                recommendation.requiresIndividualReview = true
                recommendation.reason = "Datei wurde seit der Analyse geändert. Bitte Zuordnung erneut bestätigen."
            }
            restoredRecommendations.append(recommendation)
        }

        let restoredIDs = Set(restoredRecommendations.map(\.id))
        let safeFolders = folders.filter { isWithin($0, root: root) }
        return Restoration(
            files: restoredFiles,
            folders: safeFolders,
            recommendations: restoredRecommendations,
            folderProposals: folderProposals,
            structureProposals: structureProposals,
            acceptedFolders: acceptedFolders.filter { isWithin($0, root: root) },
            protectedIDs: protectedIDs.intersection(validIDs).union(Set(restoredFiles.filter(\.isProtected).map(\.id))),
            completedIDs: completedIDs.intersection(restoredIDs).subtracting(staleIDs),
            manualSignatures: manualSignatures.filter { restoredIDs.contains($0.key) && !staleIDs.contains($0.key) },
            staleIDs: staleIDs)
    }

    private func snapshotsMatch(_ saved: FileSnapshot, _ current: FileSnapshot) -> Bool {
        saved.size == current.size && saved.modifiedAt == current.modifiedAt &&
        (saved.changedAt == nil || saved.changedAt == current.changedAt) &&
        (saved.resourceID == nil || saved.resourceID == current.resourceID)
    }

    private func isWithin(_ url: URL?, root: URL) -> Bool {
        guard let url else { return true }
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private static func validate(_ draft: AnalysisDraft) throws {
        let fileIDs = draft.files.map(\.id)
        guard Set(fileIDs).count == fileIDs.count else {
            throw FachError.message("Gesicherte Analyse enthält doppelte Dateikennungen.")
        }
        let recommendationIDs = draft.recommendations.map(\.id)
        guard Set(recommendationIDs).count == recommendationIDs.count else {
            throw FachError.message("Gesicherte Analyse enthält doppelte Zuordnungen.")
        }
    }
}

/// The one-time import format used to recover assignments from an older running
/// app. Its file names are intentionally flat, so path traversal is impossible.
public struct RecoveredAssignments: Codable, Sendable {
    public struct Assignment: Codable, Sendable {
        public var fileName: String
        public var relativeTargetFolder: String?
        public var importance: Importance
        public init(fileName: String, relativeTargetFolder: String?, importance: Importance) {
            self.fileName = fileName; self.relativeTargetFolder = relativeTargetFolder; self.importance = importance
        }
    }

    public var schemaVersion: Int
    public var sourceRoot: String
    public var context: String
    public var spentUSD: Double
    public var reservedUSD: Double
    public var assignments: [Assignment]

    public static func load(from url: URL) throws -> RecoveredAssignments {
        let recovered = try JSONDecoder().decode(RecoveredAssignments.self, from: Data(contentsOf: url))
        guard recovered.schemaVersion == 1 else { throw FachError.message("Wiederherstellungsdatei hat ein unbekanntes Format.") }
        return recovered
    }

    /// Produces only manual questions. The caller must pass a fresh safe scan of
    /// the recovered source directory; no model or cloud request is involved.
    public func importedDraft(scan: ScanResult, recursive: Bool) throws -> AnalysisDraft {
        let source = URL(fileURLWithPath: sourceRoot).standardizedFileURL
        let filesByName = Dictionary(grouping: scan.files, by: \.name)
        let knownFolders = Set(scan.folders.map { $0.standardizedFileURL.path })
        var usedNames: Set<String> = []
        var recommendations: [Recommendation] = []

        for assignment in assignments {
            guard validFileName(assignment.fileName), usedNames.insert(assignment.fileName).inserted,
                  let matches = filesByName[assignment.fileName], matches.count == 1, let file = matches.first else {
                continue
            }
            let target: URL?
            if let relativeTargetFolder = assignment.relativeTargetFolder {
                guard validRelativePath(relativeTargetFolder) else { continue }
                let resolved = source.appendingPathComponent(relativeTargetFolder, isDirectory: true).standardizedFileURL
                guard knownFolders.contains(resolved.path) else { continue }
                target = resolved
            } else {
                target = nil
            }
            recommendations.append(Recommendation(file: file, targetFolder: target, importance: assignment.importance,
                                                   confidence: 0, margin: 0,
                                                   reason: "Aus der vorherigen Sitzung wiederhergestellt. Bitte bestätigen.",
                                                   needsQuestion: true, isApproved: false))
        }
        return AnalysisDraft(source: source, recursive: recursive, context: context, files: recommendations.map(\.file),
                             folders: scan.folders, recommendations: recommendations, spentUSD: spentUSD, reservedUSD: reservedUSD)
    }

    private func validFileName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value == URL(fileURLWithPath: value).lastPathComponent &&
        !value.contains("/") && !value.contains("\\")
    }

    private func validRelativePath(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("/") && !value.hasPrefix("~") && !value.contains("\\") &&
        value.split(separator: "/").allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
