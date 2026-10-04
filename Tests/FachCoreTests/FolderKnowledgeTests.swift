import Foundation
import Testing
@testable import FachCore

private struct FolderKnowledgeFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderKnowledgeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func file(_ name: String, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? root).appendingPathComponent(name)
        try Data().write(to: url)
        return url
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Suite("FolderKnowledgeTests") struct FolderKnowledgeTests {
    @Test func inspectionOnlyReturnsSafeImmediateRegularChildren() async throws {
        let fixture = try FolderKnowledgeFixture(); defer { fixture.cleanup() }
        let folder = try fixture.folder("References")
        _ = try fixture.file("B.png", in: folder)
        _ = try fixture.file(".hidden.jpg", in: folder)
        let nested = try fixture.folder("References/Nested")
        _ = try fixture.file("inside.png", in: nested)
        let link = folder.appendingPathComponent("outside")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.root)
        let project = try fixture.folder("Project")
        _ = try fixture.file("Package.swift", in: project)

        let profiles = await FolderKnowledge.inspect(folders: [project, folder, link])
        #expect(profiles.count == 1)
        #expect(profiles.first?.url == folder.standardizedFileURL)
        #expect(profiles.first?.fileNames == ["B.png"])
    }

    @Test func knownSidecarsRequireAnExactNontrivialReferenceStem() throws {
        let fixture = try FolderKnowledgeFixture(); defer { fixture.cleanup() }
        let source = try fixture.folder("Incoming")
        let target = try fixture.folder("Camera")
        let sidecar = try fixture.file("20261004_123456.drx", in: source)
        let snapshot = try FileSafety.snapshot(sidecar)
        let profile = FolderProfile(url: target, fileNames: ["20261004_123456.PNG", "other.jpg"])
        #expect(ExistingFolderPlanner.match(file: snapshot, evidence: .init(), profiles: [profile])?.targetFolder == target)

        let short = try fixture.file("test.xmp", in: source)
        #expect(ExistingFolderPlanner.match(file: try FileSafety.snapshot(short), evidence: .init(), profiles: [profile]) == nil)
        let unrelated = FolderProfile(url: try fixture.folder("Unrelated"), fileNames: ["20261004_999999.png"])
        #expect(ExistingFolderPlanner.match(file: snapshot, evidence: .init(), profiles: [unrelated]) == nil)
    }

    @Test func duplicateReferenceStemsAndExistingParentAreNoOps() throws {
        let fixture = try FolderKnowledgeFixture(); defer { fixture.cleanup() }
        let source = try fixture.folder("Incoming")
        let sidecar = try fixture.file("20261004_123456.drx", in: source)
        let snapshot = try FileSafety.snapshot(sidecar)
        let one = try fixture.folder("One")
        let two = try fixture.folder("Two")
        let profiles = [FolderProfile(url: one, fileNames: ["20261004_123456.png"]), FolderProfile(url: two, fileNames: ["20261004_123456.png"])]
        #expect(ExistingFolderPlanner.match(file: snapshot, evidence: .init(), profiles: profiles) == nil)

        let local = FolderProfile(url: source, fileNames: ["20261004_123456.png"])
        #expect(ExistingFolderPlanner.match(file: snapshot, evidence: .init(), profiles: [local]) == nil)
    }

    @Test func drxStillCollectionUsesThreePNGReferencesWhenTheExactReferenceIsMissing() throws {
        let fixture = try FolderKnowledgeFixture(); defer { fixture.cleanup() }
        let source = try fixture.folder("Incoming")
        let target = try fixture.folder("DaVinci Stills")
        let export = try fixture.file("Still 2026-10-04 123456_4.1.drx", in: source)
        let profile = FolderProfile(url: target, fileNames: [
            "Still 2026-10-04 123456_1.1.png",
            "Still 2026-10-04 123456_2.1.png",
            "Still 2026-10-04 123456_3.1.png"
        ])
        let result = ExistingFolderPlanner.match(file: try FileSafety.snapshot(export), evidence: .init(), profiles: [profile])
        #expect(result?.targetFolder == target)
        #expect(result?.reason == "Gehört zur vorhandenen DaVinci-Still-Serie.")
        #expect(result?.confidence == 0.94)
    }

    @Test func drxStillCollectionNeedsThreeReferencesAndExactStemWins() throws {
        let fixture = try FolderKnowledgeFixture(); defer { fixture.cleanup() }
        let source = try fixture.folder("Incoming")
        let export = try fixture.file("Still 2026-10-04 123456_4.1.drx", in: source)
        let sparse = try fixture.folder("Sparse")
        let sparseProfile = FolderProfile(url: sparse, fileNames: ["Still 2026-10-04 123456_1.1.png"])
        #expect(ExistingFolderPlanner.match(file: try FileSafety.snapshot(export), evidence: .init(), profiles: [sparseProfile]) == nil)

        let collection = try fixture.folder("Collection")
        let exact = try fixture.folder("Exact")
        let collectionProfile = FolderProfile(url: collection, fileNames: [
            "Still 2026-10-04 123456_1.1.png", "Still 2026-10-04 123456_2.1.png", "Still 2026-10-04 123456_3.1.png"
        ])
        let exactProfile = FolderProfile(url: exact, fileNames: ["Still 2026-10-04 123456_4.1.png"])
        #expect(ExistingFolderPlanner.match(file: try FileSafety.snapshot(export), evidence: .init(), profiles: [collectionProfile, exactProfile])?.targetFolder == exact)
    }

    @Test func ambiguousDRXStillCollectionsReturnNoTarget() throws {
        let fixture = try FolderKnowledgeFixture(); defer { fixture.cleanup() }
        let source = try fixture.folder("Incoming")
        let export = try fixture.file("Still 2026-10-04 123456_4.1.drx", in: source)
        let names = ["Still 2026-10-04 123456_1.1.png", "Still 2026-10-04 123456_2.1.png", "Still 2026-10-04 123456_3.1.png"]
        let one = FolderProfile(url: try fixture.folder("One"), fileNames: names)
        let two = FolderProfile(url: try fixture.folder("Two"), fileNames: names)
        #expect(ExistingFolderPlanner.match(file: try FileSafety.snapshot(export), evidence: .init(), profiles: [one, two]) == nil)
    }

    @Test func projectNamesMatchWholeWordsAndSpaceFreeOCROnly() throws {
        let fixture = try FolderKnowledgeFixture(); defer { fixture.cleanup() }
        let source = try fixture.folder("Incoming")
        let document = try fixture.file("note.pdf", in: source)
        let catalog = try fixture.folder("Catalog Studio")
        let evidence = AnalysisEvidence(extractedText: "Invoice for CatalogStudio")
        #expect(ExistingFolderPlanner.match(file: try FileSafety.snapshot(document), evidence: evidence,
                                            profiles: [FolderProfile(url: catalog, fileNames: [])])?.targetFolder == catalog)

        let joined = try fixture.folder("CatalogStudio")
        let splitOCR = AnalysisEvidence(extractedText: "Invoice for Catalog Studio")
        #expect(ExistingFolderPlanner.match(file: try FileSafety.snapshot(document), evidence: splitOCR,
                                            profiles: [FolderProfile(url: joined, fileNames: [])])?.targetFolder == joined)

        let partial = try fixture.folder("Catalog")
        let weak = AnalysisEvidence(extractedText: "catalogue information")
        #expect(ExistingFolderPlanner.match(file: try FileSafety.snapshot(document), evidence: weak,
                                            profiles: [FolderProfile(url: partial, fileNames: [])]) == nil)
    }

    @Test func genericMediaRoutingIsLimitedAndScreenshotsNeedProjectEvidence() throws {
        let fixture = try FolderKnowledgeFixture(); defer { fixture.cleanup() }
        let source = try fixture.folder("Incoming")
        let movie = try fixture.file("clip.mov", in: source)
        let screenshot = try fixture.file("Screenshot 2026-10-04.png", in: source)
        let videos = try fixture.folder("Videos")
        let arbitrary = try fixture.folder("Client Project")
        let videoProfile = FolderProfile(url: videos, fileNames: [])
        let projectProfile = FolderProfile(url: arbitrary, fileNames: [])
        #expect(ExistingFolderPlanner.match(file: try FileSafety.snapshot(movie), evidence: .init(), profiles: [videoProfile])?.targetFolder == videos)
        #expect(ExistingFolderPlanner.match(file: try FileSafety.snapshot(movie), evidence: .init(), profiles: [projectProfile]) == nil)
        #expect(ExistingFolderPlanner.match(file: try FileSafety.snapshot(screenshot), evidence: .init(), profiles: [FolderProfile(url: try fixture.folder("Photos"), fileNames: [])]) == nil)
        let xnapper = try fixture.file("Xnapper 2026-10-04.png", in: source)
        #expect(ExistingFolderPlanner.match(file: try FileSafety.snapshot(xnapper), evidence: .init(), profiles: [FolderProfile(url: try fixture.folder("Fotos"), fileNames: [])]) == nil)
    }

    @Test func inaccessibleTargetsFailClosed() throws {
        let fixture = try FolderKnowledgeFixture(); defer { fixture.cleanup() }
        let source = try fixture.folder("Incoming")
        let movie = try fixture.file("clip.mov", in: source)
        let missing = fixture.root.appendingPathComponent("Videos", isDirectory: true)
        #expect(ExistingFolderPlanner.match(file: try FileSafety.snapshot(movie), evidence: .init(),
                                            profiles: [FolderProfile(url: missing, fileNames: [])]) == nil)
    }
}
