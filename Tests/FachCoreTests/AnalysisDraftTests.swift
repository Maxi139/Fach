import Foundation
import Testing
@testable import FachCore

private struct DraftFixture {
    let base: URL
    let root: URL
    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("FachDraftTests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func file(_ name: String, content: String = "original") throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        return url
    }
    func cleanup() { try? FileManager.default.removeItem(at: base) }
}

@Suite("AnalysisDraftTests") struct AnalysisDraftTests {
    @Test func atomicRoundTripPreservesDraftState() async throws {
        let fixture = try DraftFixture(); defer { fixture.cleanup() }
        _ = try fixture.file("letter.txt")
        let scan = try await FileScanner().scan(root: fixture.root, recursive: false)
        let recommendation = Recommendation(file: try #require(scan.files.first), targetFolder: nil, importance: .open,
                                            reason: "Bitte prüfen")
        let draft = AnalysisDraft(source: fixture.root, recursive: false, context: "Wichtig",
                                  configurationData: Data("configuration".utf8), files: scan.files,
                                  folders: scan.folders, recommendations: [recommendation], spentUSD: 0.018, reservedUSD: 0.003)
        let destination = fixture.base.appendingPathComponent("analysis-draft.json")
        try draft.save(to: destination)
        let loaded = try AnalysisDraft.load(from: destination)
        let permissions = try #require((try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions]) as? NSNumber)
        #expect(loaded.source == fixture.root.standardizedFileURL)
        #expect(loaded.context == "Wichtig")
        #expect(loaded.recommendations.count == 1)
        #expect(loaded.spentUSD == 0.018)
        #expect(loaded.reservedUSD == 0.003)
        #expect(permissions.intValue == 0o600)
    }

    @Test func changedSnapshotCannotBecomeEligibleAfterRestore() async throws {
        let fixture = try DraftFixture(); defer { fixture.cleanup() }
        let url = try fixture.file("letter.txt", content: "old")
        let scan = try await FileScanner().scan(root: fixture.root, recursive: false)
        let file = try #require(scan.files.first)
        let folder = fixture.root.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let recommendation = Recommendation(file: file, targetFolder: folder, importance: .archive, confidence: 0.99,
                                            margin: 0.8, reason: "Automatisch", evidence: .init(summary: "evidence", sufficient: true),
                                            needsQuestion: false, isApproved: true)
        let draft = AnalysisDraft(source: fixture.root, recursive: false, context: "", files: [file], folders: [folder],
                                  recommendations: [recommendation], manualSignatures: [file.id: "signature"],
                                  inputSignature: "signature", analyzedSignature: "signature")
        try Data("new content".utf8).write(to: url)
        let restored = draft.restore()
        let changed = try #require(restored.recommendations.first)
        #expect(restored.staleIDs.contains(file.id))
        #expect(changed.confidence == 0)
        #expect(changed.needsQuestion)
        #expect(!changed.isApproved)
        #expect(restored.manualSignatures[file.id] == nil)
    }

    @Test func legacyImportRejectsPathEscapes() async throws {
        let fixture = try DraftFixture(); defer { fixture.cleanup() }
        _ = try fixture.file("safe.txt")
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("Archive"), withIntermediateDirectories: true)
        let scan = try await FileScanner().scan(root: fixture.root, recursive: false)
        let recovered = RecoveredAssignments(schemaVersion: 1, sourceRoot: fixture.root.path, context: "", spentUSD: 0, reservedUSD: 0,
                                             assignments: [
                                                .init(fileName: "../safe.txt", relativeTargetFolder: nil, importance: .open),
                                                .init(fileName: "safe.txt", relativeTargetFolder: "../Archive", importance: .archive)
                                             ])
        let draft = try recovered.importedDraft(scan: scan, recursive: false)
        #expect(draft.recommendations.isEmpty)
    }

    @Test func persistedDraftContainsNoConsentOrCredentialFields() throws {
        let fixture = try DraftFixture(); defer { fixture.cleanup() }
        let draft = AnalysisDraft(source: fixture.root, recursive: false, context: "", files: [], folders: [], recommendations: [])
        let json = String(decoding: try JSONEncoder().encode(draft), as: UTF8.self)
        #expect(!json.contains("allowCloud"))
        #expect(!json.localizedCaseInsensitiveContains("apikey"))
        #expect(!json.localizedCaseInsensitiveContains("secret"))
    }

    @Test func corruptedDraftReturnsSafeError() throws {
        let fixture = try DraftFixture(); defer { fixture.cleanup() }
        let url = fixture.base.appendingPathComponent("analysis-draft.json")
        try Data("not json".utf8).write(to: url)
        #expect(throws: (any Error).self) { try AnalysisDraft.load(from: url) }
    }

    @Test func unchangedManualConfirmationSurvivesRestore() async throws {
        let fixture = try DraftFixture(); defer { fixture.cleanup() }
        _ = try fixture.file("letter.txt")
        let folder = fixture.root.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let scan = try await FileScanner().scan(root: fixture.root, recursive: false)
        let file = try #require(scan.files.first)
        let recommendation = Recommendation(file: file, targetFolder: folder, importance: .archive,
                                            reason: "Selbst bestätigt", needsQuestion: false, isApproved: true)
        let draft = AnalysisDraft(source: fixture.root, recursive: false, context: "", files: [file], folders: [folder],
                                  recommendations: [recommendation], manualSignatures: [file.id: "manual-input"])
        let restored = draft.restore()
        let restoredRecommendation = try #require(restored.recommendations.first)
        #expect(restored.staleIDs.isEmpty)
        #expect(restored.manualSignatures[file.id] == "manual-input")
        #expect(restoredRecommendation.targetFolder == folder.standardizedFileURL)
        #expect(restoredRecommendation.isApproved)
        #expect(!restoredRecommendation.needsQuestion)
    }

    @Test func duplicateFileIDsAreRejectedBeforeRestore() throws {
        let fixture = try DraftFixture(); defer { fixture.cleanup() }
        let id = UUID()
        let first = FileSnapshot(id: id, url: fixture.root.appendingPathComponent("one.txt"), size: 0, modifiedAt: .now)
        let second = FileSnapshot(id: id, url: fixture.root.appendingPathComponent("two.txt"), size: 0, modifiedAt: .now)
        let draft = AnalysisDraft(source: fixture.root, recursive: false, context: "", files: [first, second], folders: [], recommendations: [])
        let url = fixture.base.appendingPathComponent("analysis-draft.json")
        try draft.save(to: url)
        #expect(throws: (any Error).self) { try AnalysisDraft.load(from: url) }
    }
}
