import Foundation
import Testing
@testable import FachCore

private struct ReviewedPlanFixture {
    let base: URL
    let root: URL

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("FachReviewedPlanTests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func file(_ path: String, contents: String = "synthetic") throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func scan(recursive: Bool = false) async throws -> ScanResult {
        try await FileScanner().scan(root: root, recursive: recursive)
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }
}

@Suite("ReviewedSortingPlanTests") struct ReviewedSortingPlanTests {
    @Test func resolvesSafeAssignmentsAndReturnsOnlyNeededNewFoldersWithoutWrites() async throws {
        let fixture = try ReviewedPlanFixture(); defer { fixture.cleanup() }
        _ = try fixture.file("invoice.pdf")
        _ = try fixture.file("new-invoice.pdf")
        let receipts = try fixture.folder("Receipts")
        let scan = try await fixture.scan()
        let before = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted()
        let plan = ReviewedSortingPlan(
            source: fixture.root,
            newFolders: ["New invoices"],
            assignments: [
                .init(fileName: "invoice.pdf", relativeTargetFolder: "Receipts", reason: "Beleg für den Einkauf", summary: "Kaufbeleg."),
                .init(fileName: "new-invoice.pdf", relativeTargetFolder: "New invoices", reason: "Neuer Beleg"),
                .init(fileName: "missing.pdf", relativeTargetFolder: "New invoices", reason: "Alter Plan")
            ]
        )

        let resolution = try plan.resolve(scan: scan)

        #expect(resolution.recommendations.count == 2)
        let recommendation = try #require(resolution.recommendations.first)
        #expect(recommendation.targetFolder == receipts.standardizedFileURL)
        #expect(recommendation.importance == .open)
        #expect(recommendation.confidence == 0.95)
        #expect(recommendation.margin == 0.95)
        #expect(recommendation.evidence.sufficient)
        #expect(recommendation.evidence.summary == "Kaufbeleg.")
        #expect(!recommendation.needsQuestion)
        #expect(!recommendation.isApproved)
        #expect(recommendation.requiresIndividualReview == false)
        #expect(resolution.newFolders == [fixture.root.appendingPathComponent("New invoices", isDirectory: true).standardizedFileURL])
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted() == before)
        #expect(!FileSafety.exists(fixture.root.appendingPathComponent("New invoices")))
    }

    @Test func missingAssignedFileDoesNotResurrectButMakesItsNewFolderUnused() async throws {
        let fixture = try ReviewedPlanFixture(); defer { fixture.cleanup() }
        _ = try fixture.file("present.txt")
        let scan = try await fixture.scan()
        let plan = ReviewedSortingPlan(source: fixture.root, newFolders: ["Archive"], assignments: [
            .init(fileName: "gone.txt", relativeTargetFolder: "Archive", reason: "Alte Zuordnung")
        ])

        let resolution = try plan.resolve(scan: scan)

        #expect(resolution.recommendations.isEmpty)
        #expect(resolution.newFolders.isEmpty)
        #expect(!FileSafety.exists(fixture.root.appendingPathComponent("Archive")))
    }

    @Test func rejectsPathTraversalUnknownExistingAndDuplicateAssignmentsAtomically() async throws {
        let fixture = try ReviewedPlanFixture(); defer { fixture.cleanup() }
        _ = try fixture.file("safe.txt")
        let scan = try await fixture.scan()
        let invalidPlans = [
            ReviewedSortingPlan(source: fixture.root, assignments: [
                .init(fileName: "safe.txt", relativeTargetFolder: "../outside", reason: "Ungültig")
            ]),
            ReviewedSortingPlan(source: fixture.root, assignments: [
                .init(fileName: "safe.txt", relativeTargetFolder: "Unknown", reason: "Unbekannt")
            ]),
            ReviewedSortingPlan(source: fixture.root, assignments: [
                .init(fileName: "safe.txt", relativeTargetFolder: "Unknown", reason: "Erste"),
                .init(fileName: "safe.txt", relativeTargetFolder: "Unknown", reason: "Doppelt")
            ])
        ]

        for plan in invalidPlans {
            #expect(throws: (any Error).self) { try plan.resolve(scan: scan) }
        }
    }

    @Test func rejectsProtectedHiddenAndSymlinkTargetsAndProtectedSource() async throws {
        let fixture = try ReviewedPlanFixture(); defer { fixture.cleanup() }
        _ = try fixture.file("safe.txt")
        let project = try fixture.folder("Project")
        _ = try fixture.file("Project/.git/config")
        let hidden = try fixture.folder(".hidden")
        let real = try fixture.folder("Real")
        let alias = fixture.root.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let scan = try await fixture.scan()

        for target in ["Project", ".hidden", "Alias"] {
            let plan = ReviewedSortingPlan(source: fixture.root, assignments: [
                .init(fileName: "safe.txt", relativeTargetFolder: target, reason: "Unsicher")
            ])
            #expect(throws: (any Error).self) { try plan.resolve(scan: scan) }
        }
        let protectedSource = ReviewedSortingPlan(source: project, assignments: [])
        #expect(throws: (any Error).self) { try protectedSource.resolve(scan: scan) }
        #expect(FileSafety.exists(hidden))
        #expect(FileSafety.exists(alias))
    }

    @Test func rejectsUnboundedOrInvalidConfidenceAndSkipsNestedSameParentFile() async throws {
        let fixture = try ReviewedPlanFixture(); defer { fixture.cleanup() }
        let archive = try fixture.folder("Archive")
        let nested = try fixture.file("Archive/old.txt")
        let scan = try await fixture.scan(recursive: true)
        let tooLong = String(repeating: "x", count: 501)
        let invalidPlans = [
            ReviewedSortingPlan(source: fixture.root, assignments: [
                .init(fileName: "old.txt", relativeTargetFolder: "Archive", reason: "Ungültig", confidence: .infinity)
            ]),
            ReviewedSortingPlan(source: fixture.root, assignments: [
                .init(fileName: "old.txt", relativeTargetFolder: "Archive", reason: tooLong)
            ])
        ]
        for plan in invalidPlans {
            #expect(throws: (any Error).self) { try plan.resolve(scan: scan) }
        }

        let valid = ReviewedSortingPlan(source: fixture.root, assignments: [
            .init(fileName: nested.lastPathComponent, relativeTargetFolder: "Archive", reason: "Schon im Ziel")
        ])
        #expect(try valid.resolve(scan: scan).recommendations.isEmpty)
        #expect(archive == fixture.root.appendingPathComponent("Archive", isDirectory: true))
    }

    @Test func rejectsNewPackageFoldersAndEmptyPathComponents() async throws {
        let fixture = try ReviewedPlanFixture(); defer { fixture.cleanup() }
        _ = try fixture.file("safe.txt")
        _ = try fixture.folder("Archive")
        let scan = try await fixture.scan()
        for name in ["Danger.icon", "Danger.app", "Archive//"] {
            let plan = ReviewedSortingPlan(source: fixture.root, newFolders: [name], assignments: [
                .init(fileName: "safe.txt", relativeTargetFolder: name, reason: "Unsicher")
            ])
            #expect(throws: (any Error).self) { try plan.resolve(scan: scan) }
        }
    }

    @Test func decodingUsesDocumentedDefaults() throws {
        let data = Data("""
        {"source":"file:///tmp/ReviewedPlan/","assignments":[{"fileName":"note.txt","relativeTargetFolder":"Notes","reason":"Notiz"}]}
        """.utf8)
        let plan = try JSONDecoder().decode(ReviewedSortingPlan.self, from: data)

        #expect(plan.newFolders.isEmpty)
        #expect(plan.assignments[0].confidence == 0.95)
        #expect(plan.assignments[0].summary.isEmpty)
    }
}
