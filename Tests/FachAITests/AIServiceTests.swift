import XCTest
import Darwin
import FachCore
@testable import FachAI

private actor MockTransport: HTTPTransport {
    var requests: [URLRequest] = []
    let response: @Sendable (URLRequest) throws -> [String: Any]
    init(response: @escaping @Sendable (URLRequest) throws -> [String: Any]) { self.response = response }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (try JSONSerialization.data(withJSONObject: response(request)), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func urls() -> [String] { requests.compactMap { $0.url?.absoluteString } }
}
@MainActor
final class AIServiceTests: XCTestCase {
    private func snapshot(_ url: URL) throws -> FileSnapshot {
        var info = Darwin.stat(); guard lstat(url.path, &info) == 0 else { throw URLError(.fileDoesNotExist) }
        return FileSnapshot(url: url, size: info.st_size,
                            modifiedAt: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000),
                            resourceID: "\(info.st_dev):\(info.st_ino)",
                            changedAt: Date(timeIntervalSince1970: Double(info.st_ctimespec.tv_sec) + Double(info.st_ctimespec.tv_nsec) / 1_000_000_000))
    }
    private func fixture(extension ext: String = "bin") throws -> FileSnapshot {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
        try Data("Invented fixture".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try snapshot(url)
    }
    func testLocalCannotBecomeAutomaticAndNeverSendsCloud() async throws {
        let transport = MockTransport { request in
            if request.url!.path == "/api/show" { return ["capabilities": ["completion"]] }
            return ["message": ["content": "{\"target\":\"f0\",\"importance\":\"active\",\"reason\":\"Passender Ordner\"}"]]
        }
        var config = AIConfiguration(); config.mode = .local
        let service = AIService(configuration: config, apiKey: "invented-test-key", transport: transport)
        let file = try fixture()
        let result = try await service.analyze(file: file, folders: [URL(fileURLWithPath: "/invented/Arbeit")], context: "Test", allowCloud: true, allowOriginals: true)
        XCTAssertTrue(result.needsQuestion); XCTAssertFalse(result.autoEligible)
        let urls = await transport.urls(); XCTAssertTrue(urls.allSatisfy { $0.hasPrefix("http://localhost:") })
    }
    func testSummaryOnlyConsentDoesNotUploadExcerpt() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("PRIVATE ORIGINAL SENTINEL".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let transport = MockTransport { request in
            if request.url!.path == "/api/show" { return ["capabilities": ["completion"]] }
            if request.url!.path == "/api/chat" { return ["message": ["content": "{\"summary\":\"Erfundene lokale Beschreibung\"}"]] }
            if request.url!.path.hasSuffix("/endpoints") { return ["data": ["endpoints": [["pricing": ["prompt": "0.0000001", "completion": "0"]]]]] }
            XCTAssertFalse(String(data: request.httpBody ?? Data(), encoding: .utf8)!.contains("PRIVATE ORIGINAL SENTINEL"))
            if request.url!.path.hasSuffix("/systemone") {
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                let state = body["state"] as! [String: Any]
                XCTAssertEqual(state["content"] as? String, "")
                return ["answers": ["target": ["choice": "other", "confidence": 1, "probabilities": ["other": 1]], "importance": ["choice": "open", "confidence": 1, "probabilities": ["open": 1, "active": 0, "archive": 0]], "question": ["noul": 1]], "usage": ["cost": 0.0001]]
            }
            return ["choices": [["message": ["content": "{\"name\":\"Datei.txt\"}"]]], "usage": ["cost": 0.0001]]
        }
        let service = AIService(configuration: .init(), apiKey: "invented", transport: transport)
        _ = try await service.analyze(file: try snapshot(url), folders: [], context: "Erfundener Test", allowCloud: true, allowOriginals: false)
        let urls = await transport.urls(); XCTAssertTrue(urls.contains { $0.contains("openrouter") })
    }
    func testUnknownFolderRejected() async throws {
        let transport = MockTransport { request in
            if request.url!.path == "/api/show" { return ["capabilities": ["completion"]] }
            return ["message": ["content": "{\"target\":\"f999\",\"importance\":\"archive\",\"reason\":\"x\"}"]]
        }
        let service = AIService(configuration: .init(), apiKey: nil, transport: transport)
        do { _ = try await service.analyze(file: try fixture(), folders: [], context: "", allowCloud: false, allowOriginals: false); XCTFail("Unknown target accepted") } catch {}
    }
    func testBudgetBlocksBeforePaidRequest() async throws {
        let transport = MockTransport { _ in ["data": ["endpoints": [["pricing": ["prompt": "0.01", "completion": "0.01"]]]]] }
        var config = AIConfiguration(); config.budgetUSD = 0.001
        let service = AIService(configuration: config, apiKey: "invented", transport: transport)
        do { _ = try await service.checkConnection(); XCTFail("Exceeded budget") } catch {}
        let urls = await transport.urls(); XCTAssertEqual(urls.count, 1); XCTAssertTrue(urls[0].hasSuffix("/endpoints"))
    }
    func testUnsafeNamesRejected() {
        for name in ["../Secret", "A/B", "A:B", "A\\B", ".hidden", "\u{0}", ""] { XCTAssertNil(AIService.safeName(name)) }
        XCTAssertEqual(AIService.safeName("  Reise  "), "Reise")
    }
    func testSymlinkReplacementAfterScanIsRejectedBeforeExtraction() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("private.txt")
        let target = directory.appendingPathComponent("other.txt")
        try Data("PRIVATE ORIGINAL SENTINEL".utf8).write(to: original)
        try Data("UNRELATED TARGET".utf8).write(to: target)
        let scanned = try snapshot(original)
        try FileManager.default.removeItem(at: original)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: target)

        do {
            _ = try await ContentExtractor.extract(scanned)
            XCTFail("Symlink replacement was extracted")
        } catch {}
    }
    func testRestoredModificationTimeCannotHideSameInodeRewrite() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("PRIVATE".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let scanned = try snapshot(url)
        var original = Darwin.stat()
        XCTAssertEqual(lstat(url.path, &original), 0)

        usleep(20_000)
        try Data("PUBLIC!".utf8).write(to: url)
        var times = [original.st_atimespec, original.st_mtimespec]
        XCTAssertEqual(utimensat(AT_FDCWD, url.path, &times, 0), 0)
        let rewritten = try snapshot(url)
        XCTAssertEqual(rewritten.resourceID, scanned.resourceID)
        XCTAssertEqual(rewritten.modifiedAt, scanned.modifiedAt)
        XCTAssertNotEqual(rewritten.changedAt, scanned.changedAt)

        do {
            _ = try await ContentExtractor.extract(scanned)
            XCTFail("Same-inode rewrite with restored modification time was extracted")
        } catch {}
    }
    func testIdentityReplacementBetweenExtractionAndCloudRequestIsRejected() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("private.txt")
        try Data("PRIVATE ORIGINAL SENTINEL".utf8).write(to: url)
        let scanned = try snapshot(url)
        let transport = MockTransport { request in
            if request.url!.path.hasSuffix("/endpoints") {
                try Data("REPLACED AFTER EXTRACTION".utf8).write(to: url)
                return ["data": ["endpoints": [["pricing": ["prompt": "0.0000001", "completion": "0"]]]]]
            }
            XCTFail("Cloud request received replaced file content")
            return [:]
        }
        let service = AIService(configuration: .init(), apiKey: "invented", transport: transport)

        do {
            _ = try await service.analyze(file: scanned, folders: [], context: "Test", allowCloud: true, allowOriginals: true)
            XCTFail("Replacement was sent to cloud")
        } catch {}
        let urls = await transport.urls()
        XCTAssertEqual(urls.filter { $0.hasSuffix("chat/completions") }.count, 0)
    }
    func testRemoteOllamaModelNameAndMetadataNeverReceivePrivateChat() async throws {
        let file = try fixture(extension: "txt")

        var namedRemote = AIConfiguration(); namedRemote.mode = .local; namedRemote.textModel = "remote-model"
        let nameTransport = MockTransport { _ in XCTFail("Remote-named model made a request"); return [:] }
        do {
            _ = try await AIService(configuration: namedRemote, apiKey: nil, transport: nameTransport)
                .analyze(file: file, folders: [], context: "Test", allowCloud: false, allowOriginals: false)
            XCTFail("Remote-named model was accepted")
        } catch {}
        let nameURLs = await nameTransport.urls()
        XCTAssertTrue(nameURLs.isEmpty)

        var metadataRemote = AIConfiguration(); metadataRemote.mode = .local; metadataRemote.textModel = "local-looking-model"
        let metadataTransport = MockTransport { request in
            if request.url!.path == "/api/show" {
                return ["capabilities": ["completion"], "details": ["cloud": "https://provider.example"]]
            }
            XCTFail("Remote metadata model received a private chat")
            return [:]
        }
        do {
            _ = try await AIService(configuration: metadataRemote, apiKey: nil, transport: metadataTransport)
                .analyze(file: file, folders: [], context: "Test", allowCloud: false, allowOriginals: false)
            XCTFail("Remote metadata model was accepted")
        } catch {}
        let metadataURLs = await metadataTransport.urls()
        XCTAssertEqual(metadataURLs.filter { $0.hasSuffix("/api/chat") }.count, 0)
        XCTAssertEqual(metadataURLs.filter { $0.hasSuffix("/api/show") }.count, 1)
    }
    func testRedirectDelegateRejectsEveryRedirect() {
        final class Result: @unchecked Sendable { var request: URLRequest? }
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "https://localhost/original")!)
        let redirect = URLRequest(url: URL(string: "https://attacker.example/redirected")!)
        let response = HTTPURLResponse(url: URL(string: "https://localhost/original")!, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://attacker.example/redirected"])!
        let result = Result()

        NoRedirectDelegate().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirect) { result.request = $0 }
        XCTAssertNil(result.request)
    }
    func testValidatedJevRoutingAndActualCost() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Rechnung.txt")
        try Data("Erfundene abgeschlossene Rechnung für Testprojekt.".utf8).write(to: url)
        let transport = MockTransport { request in
            if request.url!.path.hasSuffix("/endpoints") { return ["data": ["endpoints": [["pricing": ["prompt": "0.0000001", "completion": "0"]]]]] }
            if request.url!.path.hasSuffix("/systemone") {
                return ["answers": ["target": ["choice": "f0", "confidence": 0.98, "probabilities": ["f0": 0.99, "other": 0.01]], "importance": ["choice": "archive", "confidence": 0.99, "probabilities": ["open": 0.01, "active": 0, "archive": 0.99]], "question": ["noul": 0.01]], "usage": ["cost": 0.0001, "input_tokens": 100, "output_tokens": 20]]
            }
            return ["choices": [["message": ["content": "{\"name\":\"Rechnung.txt\"}"]]], "usage": ["cost": 0.0002, "prompt_tokens": 80, "completion_tokens": 10]]
        }
        let service = AIService(configuration: .init(), apiKey: "invented", transport: transport)
        let result = try await service.analyze(file: try snapshot(url), folders: [directory.appendingPathComponent("Rechnungen")], context: "Abgeschlossen", allowCloud: true, allowOriginals: true)
        XCTAssertEqual(result.importance, .archive); XCTAssertTrue(result.autoEligible)
        let usage = await service.usage(); XCTAssertEqual(usage.spentUSD, 0.0003, accuracy: 0.0000001); XCTAssertEqual(usage.reservedUSD, 0, accuracy: 0.0000001); XCTAssertEqual(usage.inputTokens, 180)
    }
    func testFailedPaidRequestKeepsReservationAndDoesNotRetry() async throws {
        let transport = MockTransport { request in
            if request.url!.path.hasSuffix("/endpoints") { return ["data": ["endpoints": [["pricing": ["prompt": "0.0000001", "completion": "0"]]]]] }
            throw URLError(.timedOut)
        }
        let service = AIService(configuration: .init(), apiKey: "invented", transport: transport)
        do { _ = try await service.checkConnection(); XCTFail("Expected timeout") } catch {}
        let urls = await transport.urls(); XCTAssertEqual(urls.filter { $0.hasSuffix("chat/completions") }.count, 1)
        let usage = await service.usage(); XCTAssertGreaterThan(usage.reservedUSD, 0)
    }
    func testFolderProposalsRejectPathsAndDuplicates() async throws {
        let transport = MockTransport { request in
            if request.url!.path == "/api/show" { return ["capabilities": ["completion"]] }
            return ["message": ["content": "{\"folders\":[{\"name\":\"../Secret\",\"reason\":\"x\"},{\"name\":\"Rechnungen\",\"reason\":\"x\"},{\"name\":\"Bilder\",\"reason\":\"Bildsammlung\"}]}"]]
        }
        var config = AIConfiguration(); config.mode = .local
        let service = AIService(configuration: config, apiKey: nil, transport: transport)
        let recommendations = [Recommendation(file: try fixture(), evidence: AnalysisEvidence(summary: "Erfundene Rechnung", sufficient: true))]
        let folders = try await service.proposeFolders(files: recommendations, existingFolders: [URL(fileURLWithPath: "/invented/Rechnungen")], context: "", allowCloud: false)
        XCTAssertEqual(folders.map(\.name), ["Bilder"]); XCTAssertTrue(folders.allSatisfy { $0.replaces.isEmpty })
    }
    func testFolderProposalsSkipInsufficientEvidenceWithoutCallingModel() async throws {
        let transport = MockTransport { _ in XCTFail("Insufficient file content reached a model"); return [:] }
        var config = AIConfiguration(); config.mode = .local
        let service = AIService(configuration: config, apiKey: nil, transport: transport)
        let files = [Recommendation(file: try fixture(), evidence: AnalysisEvidence(summary: "Only a filename", sufficient: false))]

        let proposals = try await service.proposeFolders(files: files, existingFolders: [], context: "", allowCloud: false)
        XCTAssertTrue(proposals.isEmpty)
        let urls = await transport.urls()
        XCTAssertTrue(urls.isEmpty)
    }
    private func structureFiles(matched: Bool = false) -> [Recommendation] {
        (0..<2).map { index in
            Recommendation(file: FileSnapshot(url: URL(fileURLWithPath: "/invented/Datei\(index).txt"), size: 0, modifiedAt: .now), targetFolder: matched ? URL(fileURLWithPath: "/invented/Sonstiges") : nil, evidence: AnalysisEvidence(summary: index == 0 ? "Erfundene Rechnung" : "Erfundene Urlaubsnotiz", sufficient: true))
        }
    }
    private func structureTransport(replaceID: String = "f0", kind: String = "vague") -> MockTransport {
        MockTransport { request in
            if request.url!.path == "/api/show" { return ["capabilities": ["completion"]] }
            let result: [String: Any] = ["diagnosis": ["kind": kind, "reason": "Sammelordner benennt keinen konkreten Inhalt.", "folderIDs": ["f0"], "fileIDs": ["d0", "d1"]], "folders": [["name": "Dokumente", "reason": "Konkrete Dokumentgruppe", "replaces": [replaceID]]]]
            return ["message": ["content": String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!]]
        }
    }
    func testHealthyStructureSkipsModel() async throws {
        let transport = structureTransport()
        let service = AIService(configuration: .init(), apiKey: nil, transport: transport)
        let proposals = try await service.proposeStructure(files: structureFiles(matched: true), existingFolders: [URL(fileURLWithPath: "/invented/Sonstiges")], context: "", allowCloud: false)
        XCTAssertTrue(proposals.isEmpty)
        let requests = await transport.urls(); XCTAssertTrue(requests.isEmpty)
    }
    func testStructureIDsResolveOnlyToSuppliedFolders() async throws {
        let service = AIService(configuration: .init(), apiKey: nil, transport: structureTransport())
        let existing = URL(fileURLWithPath: "/invented/Sonstiges")
        let proposals = try await service.proposeStructure(files: structureFiles(), existingFolders: [existing], context: "", allowCloud: false)
        XCTAssertEqual(proposals.map(\.name), ["Dokumente"]); XCTAssertEqual(proposals.first?.replaces, [existing])
    }
    func testStructureRejectsGeneratedReplacementPaths() async throws {
        let service = AIService(configuration: .init(), apiKey: nil, transport: structureTransport(replaceID: "/outside/secret"))
        do {
            _ = try await service.proposeStructure(files: structureFiles(), existingFolders: [URL(fileURLWithPath: "/invented/Sonstiges")], context: "", allowCloud: false)
            XCTFail("Generated replacement accepted")
        } catch {}
    }
    func testUnmatchedCountDoesNotProvePoorStructure() async throws {
        let service = AIService(configuration: .init(), apiKey: nil, transport: structureTransport())
        let proposals = try await service.proposeStructure(files: structureFiles(), existingFolders: [URL(fileURLWithPath: "/invented/Rechnungen")], context: "", allowCloud: false)
        XCTAssertTrue(proposals.isEmpty)
    }
    func testMixedDiagnosisNeedsFilesActuallyInsideFolder() async throws {
        let service = AIService(configuration: .init(), apiKey: nil, transport: structureTransport(kind: "mixed"))
        let proposals = try await service.proposeStructure(files: structureFiles(), existingFolders: [URL(fileURLWithPath: "/invented/Sonstiges")], context: "", allowCloud: false)
        XCTAssertTrue(proposals.isEmpty)
    }
}
