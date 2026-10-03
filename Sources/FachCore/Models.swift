import Foundation

public enum Importance: String, Codable, CaseIterable, Sendable {
    case active = "Aktiv", archive = "Archiv", open = "Offen"
}

public struct FileSnapshot: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var url: URL
    public var size: Int64
    public var modifiedAt: Date
    public var changedAt: Date?
    public var resourceID: String?
    public var isDirectory: Bool
    public var isProtected: Bool
    public var name: String { url.lastPathComponent }
    public init(id: UUID = UUID(), url: URL, size: Int64, modifiedAt: Date, resourceID: String? = nil, changedAt: Date? = nil, isDirectory: Bool = false, isProtected: Bool = false) {
        self.id = id; self.url = url; self.size = size; self.modifiedAt = modifiedAt
        self.changedAt = changedAt; self.resourceID = resourceID; self.isDirectory = isDirectory; self.isProtected = isProtected
    }
}

public struct ScanResult: Sendable {
    public var files: [FileSnapshot]
    public var folders: [URL]
    public var warnings: [String]
    public init(files: [FileSnapshot], folders: [URL], warnings: [String] = []) {
        self.files = files; self.folders = folders; self.warnings = warnings
    }
}

public struct AnalysisEvidence: Codable, Sendable {
    public var summary: String
    public var extractedText: String
    public var sufficient: Bool
    public var origin: String
    public var imageData: Data?
    public init(summary: String = "", extractedText: String = "", sufficient: Bool = false, origin: String = "Dateiinformationen", imageData: Data? = nil) {
        self.summary = summary; self.extractedText = extractedText; self.sufficient = sufficient
        self.origin = origin; self.imageData = imageData
    }
}

public enum OperationKind: String, Codable, Sendable { case move, rename, trash, createDirectory }
public enum OperationState: String, Codable, Sendable { case pending, prepared, completed, failed, undone, conflict }

public struct PlannedOperation: Identifiable, Codable, Sendable {
    public var id: UUID
    public var kind: OperationKind
    public var source: URL
    public var destination: URL?
    public var snapshot: FileSnapshot?
    public var requiresConfirmation: Bool
    public var reason: String
    public init(id: UUID = UUID(), kind: OperationKind, source: URL, destination: URL? = nil, snapshot: FileSnapshot? = nil, requiresConfirmation: Bool = false, reason: String = "") {
        self.id = id; self.kind = kind; self.source = source; self.destination = destination
        self.snapshot = snapshot; self.requiresConfirmation = requiresConfirmation; self.reason = reason
    }
}

public struct OrganizationPlan: Identifiable, Codable, Sendable {
    public var id: UUID
    public var sourceRoot: URL
    public var destinationRoot: URL
    public var operations: [PlannedOperation]
    public var createdAt: Date
    public init(id: UUID = UUID(), sourceRoot: URL, destinationRoot: URL, operations: [PlannedOperation], createdAt: Date = Date()) {
        self.id = id; self.sourceRoot = sourceRoot; self.destinationRoot = destinationRoot
        self.operations = operations; self.createdAt = createdAt
    }
}

public struct RunEvent: Identifiable, Codable, Sendable {
    public var id: UUID
    public var runID: UUID
    public var operation: PlannedOperation
    public var state: OperationState
    public var message: String
    public var date: Date
    public init(id: UUID = UUID(), runID: UUID, operation: PlannedOperation, state: OperationState, message: String = "", date: Date = Date()) {
        self.id = id; self.runID = runID; self.operation = operation; self.state = state; self.message = message; self.date = date
    }
}

public struct Recommendation: Identifiable, Codable, Sendable {
    public var id: UUID { file.id }
    public var file: FileSnapshot
    public var targetFolder: URL?
    public var importance: Importance
    public var confidence: Double
    public var margin: Double
    public var reason: String
    public var evidence: AnalysisEvidence
    public var suggestedName: String?
    public var needsQuestion: Bool
    public var isApproved: Bool
    /// Set when the saved file snapshot no longer matches the current file.
    /// The app must keep these recommendations out of bulk confirmation.
    public var requiresIndividualReview: Bool?
    public var autoEligible: Bool { targetFolder != nil && confidence >= 0.9 && margin >= 0.2 && evidence.sufficient && !needsQuestion && !file.isProtected }
    public init(file: FileSnapshot, targetFolder: URL? = nil, importance: Importance = .open, confidence: Double = 0, margin: Double = 0, reason: String = "Zuordnung prüfen", evidence: AnalysisEvidence = .init(), suggestedName: String? = nil, needsQuestion: Bool = true, isApproved: Bool = false, requiresIndividualReview: Bool? = nil) {
        self.file = file; self.targetFolder = targetFolder; self.importance = importance; self.confidence = confidence
        self.margin = margin; self.reason = reason; self.evidence = evidence; self.suggestedName = suggestedName
        self.needsQuestion = needsQuestion; self.isApproved = isApproved
        self.requiresIndividualReview = requiresIndividualReview
    }
}

public struct FolderProposal: Identifiable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var reason: String
    public var replaces: [URL]
    public init(id: UUID = UUID(), name: String, reason: String, replaces: [URL] = []) {
        self.id = id; self.name = name; self.reason = reason; self.replaces = replaces
    }
}

public enum FachError: LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? { if case let .message(text) = self { text } else { nil } }
}
