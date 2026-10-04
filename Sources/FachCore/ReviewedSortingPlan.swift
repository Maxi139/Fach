import Foundation

/// A local, user-curated set of assignments. Resolving a plan only produces
/// recommendations; it never changes the filesystem.
public struct ReviewedSortingPlan: Codable, Sendable {
    public struct Assignment: Codable, Sendable {
        public var fileName: String
        public var relativeTargetFolder: String
        public var reason: String
        public var confidence: Double
        public var summary: String

        public init(fileName: String, relativeTargetFolder: String, reason: String,
                    confidence: Double = 0.95, summary: String = "") {
            self.fileName = fileName
            self.relativeTargetFolder = relativeTargetFolder
            self.reason = reason
            self.confidence = confidence
            self.summary = summary
        }

        private enum CodingKeys: String, CodingKey {
            case fileName, relativeTargetFolder, reason, confidence, summary
        }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            fileName = try values.decode(String.self, forKey: .fileName)
            relativeTargetFolder = try values.decode(String.self, forKey: .relativeTargetFolder)
            reason = try values.decode(String.self, forKey: .reason)
            confidence = try values.decodeIfPresent(Double.self, forKey: .confidence) ?? 0.95
            summary = try values.decodeIfPresent(String.self, forKey: .summary) ?? ""
        }
    }

    public struct Resolution: Sendable {
        public var recommendations: [Recommendation]
        public var newFolders: [URL]

        public init(recommendations: [Recommendation], newFolders: [URL]) {
            self.recommendations = recommendations
            self.newFolders = newFolders
        }
    }

    public var source: URL
    public var newFolders: [String]
    public var assignments: [Assignment]

    public init(source: URL, newFolders: [String] = [], assignments: [Assignment]) {
        self.source = source
        self.newFolders = newFolders
        self.assignments = assignments
    }

    private enum CodingKeys: String, CodingKey { case source, newFolders, assignments }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        source = try values.decode(URL.self, forKey: .source)
        newFolders = try values.decodeIfPresent([String].self, forKey: .newFolders) ?? []
        assignments = try values.decode([Assignment].self, forKey: .assignments)
    }

    /// Validates every untrusted plan value before producing any recommendation.
    /// Files no longer present in this fresh scan are deliberately ignored.
    public func resolve(scan: ScanResult) throws -> Resolution {
        let root = source.standardizedFileURL
        try validateSource(root)

        var declaredFolders: [String: URL] = [:]
        for name in newFolders {
            guard isFlatName(name), declaredFolders[name] == nil else {
                throw FachError.message("Ordnerplan enthält einen ungültigen oder doppelten Ordnernamen.")
            }
            let folder = root.appendingPathComponent(name, isDirectory: true).standardizedFileURL
            guard !FileSafety.protectedDirectory(folder) else { throw FachError.message("Geschützte Ordner dürfen nicht als Ziel ergänzt werden.") }
            if FileSafety.exists(folder) {
                try validateSafeFolder(folder, within: root)
            } else {
                try FileSafety.validatePath(folder, within: root, allowMissingLeaf: true)
            }
            declaredFolders[name] = folder
        }

        var validatedTargets: [String: URL] = [:]
        var assignmentNames: Set<String> = []
        for assignment in assignments {
            guard isFlatName(assignment.fileName), assignmentNames.insert(assignment.fileName).inserted,
                  isRelativeFolderPath(assignment.relativeTargetFolder),
                  assignment.confidence.isFinite, (0...1).contains(assignment.confidence),
                  isBounded(assignment.reason, maximum: 500, requireContent: true),
                  isBounded(assignment.summary, maximum: 2_000, requireContent: false) else {
                throw FachError.message("Sortierplan enthält eine ungültige Zuordnung.")
            }

            let target = root.appendingPathComponent(assignment.relativeTargetFolder, isDirectory: true)
                .standardizedFileURL
            if let newFolder = declaredFolders[assignment.relativeTargetFolder] {
                guard target == newFolder else { throw FachError.message("Sortierplan enthält einen ungültigen Zielordner.") }
                if FileSafety.exists(target) { try validateSafeFolder(target, within: root) }
            } else {
                try validateSafeFolder(target, within: root)
                guard scan.folders.contains(where: { $0.standardizedFileURL == target }) else {
                    throw FachError.message("Zielordner ist nicht Teil des aktuellen Scans.")
                }
            }
            validatedTargets[assignment.fileName] = target
        }

        let filesByName = Dictionary(grouping: scan.files.filter {
            $0.url.deletingLastPathComponent().standardizedFileURL == root &&
            $0.name == $0.url.lastPathComponent && !$0.isDirectory && !$0.isProtected
        }, by: \.name)

        var recommendations: [Recommendation] = []
        var neededNewFolders: Set<URL> = []
        for assignment in assignments {
            guard let matches = filesByName[assignment.fileName], matches.count == 1,
                  let file = matches.first, let target = validatedTargets[assignment.fileName],
                  file.url.deletingLastPathComponent().standardizedFileURL != target else { continue }
            recommendations.append(Recommendation(
                file: file,
                targetFolder: target,
                importance: .open,
                confidence: assignment.confidence,
                margin: assignment.confidence,
                reason: assignment.reason,
                evidence: AnalysisEvidence(summary: assignment.summary, sufficient: true, origin: "Geprüfter Sortierplan"),
                needsQuestion: false,
                isApproved: false,
                requiresIndividualReview: false
            ))
            if declaredFolders[assignment.relativeTargetFolder] == target, !FileSafety.exists(target) {
                neededNewFolders.insert(target)
            }
        }
        return Resolution(recommendations: recommendations,
                          newFolders: newFolders.compactMap { declaredFolders[$0] }.filter { neededNewFolders.contains($0) })
    }

    private func validateSource(_ root: URL) throws {
        try FileSafety.validatePath(root, within: root)
        let info = try FileSafety.stat(root)
        guard FileSafety.isDirectory(info), !FileSafety.isLink(info), !FileSafety.protectedDirectory(root) else {
            throw FachError.message("Sortierplan benötigt einen normalen Ordner als Quelle.")
        }
    }

    private func validateSafeFolder(_ folder: URL, within root: URL) throws {
        try FileSafety.validatePath(folder, within: root)
        let info = try FileSafety.stat(folder)
        guard FileSafety.isDirectory(info), !FileSafety.isLink(info), !FileSafety.protectedDirectory(folder),
              !folder.lastPathComponent.hasPrefix(".") else {
            throw FachError.message("Zielordner ist nicht sicher.")
        }
    }

    private func isFlatName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 180 && value != "." && value != ".." && !value.hasPrefix(".") &&
        !value.contains("/") && !value.contains("\\") && !value.contains(":") &&
        !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private func isRelativeFolderPath(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("/") && !value.hasPrefix("~") && !value.contains("\\") &&
        value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { component in
            isFlatName(String(component))
        }
    }

    private func isBounded(_ value: String, maximum: Int, requireContent: Bool) -> Bool {
        value.utf8.count <= maximum && (!requireContent || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
