import AppKit
import CryptoKit
import Foundation
import Observation
import FachCore
import FachAI

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case organize = "Aufräumen", questions = "Rückfragen", duplicates = "Dubletten", history = "Verlauf"
    var id: String { rawValue }
    var symbol: String { switch self { case .organize: "tray.2"; case .questions: "questionmark.bubble"; case .duplicates: "doc.on.doc"; case .history: "clock.arrow.circlepath" } }
}

@MainActor @Observable
final class AppModel {
    var configuration = AIConfiguration()
    var source: URL?
    var destination: URL?
    var useSeparateDestination = false
    var recursive = false
    var context = ""
    var files: [FileSnapshot] = []
    var folders: [URL] = []
    var recommendations: [Recommendation] = []
    var folderProposals: [FolderProposal] = []
    var structureProposals: [FolderProposal] = []
    var showStructureReview = false
    var restructuring = false
    var acceptedFolders: [URL] = []
    var selectedID: UUID?
    var section: WorkspaceSection = .organize
    var importanceFilter: Importance?
    var search = ""
    var busy = false
    var analyzing = false
    var sorting = false
    var paused = false
    var status = "Ordner auswählen"
    var progress = 0.0
    var spentUSD = 0.0
    var reservedUSD = 0.0
    var notices: [String] = []
    var error: String?
    var showSettings = false
    var showOnboarding = !UserDefaults.standard.bool(forKey: "onboardingComplete")
    var showCloudConsent = false
    var allowCloud = false
    var allowOriginals = true
    var completedIDs: Set<UUID> = []
    var protectedIDs: Set<UUID> = []
    var history: [RunEvent] = []
    var undoable: [UUID: Set<UUID>] = [:]
    var duplicateGroups: [[FileSnapshot]] = []
    var duplicateChecked = false
    var lastEvent: RunEvent?
    var lastRunID: UUID?
    var isDemo = false
    var ollama = OllamaManager()
    private var scanner = FileScanner()
    private var operationService: FileOperationService?
    private var access = FolderAccess()
    private var activeTask: Task<Void, Never>?
    private var aiService: AIService?
    private var serviceSignature: String?
    private var analyzedSignature: String?
    private var manualSignatures: [UUID: String] = [:]
    private var runModeOverride: AIConfiguration.Mode?
    private var carriedSpend = 0.0
    private var carriedReserve = 0.0
    private var inputSignature: String {
        [source?.path ?? "", targetRoot?.path ?? "", String(recursive), context, configuration.mode.rawValue, configuration.textModel, configuration.visionModel, configuration.cloudTextModel, configuration.cloudVisionModel, String(configuration.budgetUSD)].joined(separator: "\u{1f}")
    }

    var sourceLabel: String { isDemo ? "Beispielordner" : source?.lastPathComponent ?? "Ordner" }
    var targetRoot: URL? { useSeparateDestination ? destination : source }
    var availableTargets: [URL] {
        guard let root = targetRoot else { return [] }
        return Array(Set(folders.filter { $0.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") } + acceptedFolders)).sorted { $0.path < $1.path }
    }
    var structureCheckAvailable: Bool { !folders.isEmpty && !recommendations.isEmpty && recommendations.filter { $0.targetFolder == nil }.count * 2 >= recommendations.count && recommendations.filter { $0.evidence.sufficient }.count >= 2 }
    var selected: Recommendation? { recommendations.first { $0.id == selectedID } }
    var pendingQuestions: [Recommendation] {
        let ready = Set(eligible.map(\.id))
        return recommendations.filter { !completedIDs.contains($0.id) && !protectedIDs.contains($0.id) && !ready.contains($0.id) }
    }
    var eligible: [Recommendation] { recommendations.filter { !completedIDs.contains($0.id) && !protectedIDs.contains($0.id) && $0.targetFolder != nil && (($0.autoEligible && (analyzedSignature == inputSignature)) || ($0.isApproved && manualSignatures[$0.id] == inputSignature)) } }
    var visible: [Recommendation] {
        let sourceList = section == .questions ? pendingQuestions : recommendations
        return sourceList.filter { (importanceFilter == nil || $0.importance == importanceFilter) && (search.isEmpty || $0.file.name.localizedCaseInsensitiveContains(search) || ($0.targetFolder?.lastPathComponent.localizedCaseInsensitiveContains(search) ?? false)) }
    }
    var runIDs: [UUID] { Array(Set(history.map(\.runID))).sorted { left, right in (history.first { $0.runID == left }?.date ?? .distantPast) > (history.first { $0.runID == right }?.date ?? .distantPast) } }
    func folderLabel(_ url: URL) -> String {
        guard let root = targetRoot else { return url.lastPathComponent }
        let path = url.standardizedFileURL.path, prefix = root.standardizedFileURL.path + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: "aiConfiguration"), let saved = try? JSONDecoder().decode(AIConfiguration.self, from: data) { configuration = saved }
        access.restore()
        do {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Fach")
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            operationService = try FileOperationService(databaseURL: support.appendingPathComponent("runs.sqlite3"))
        } catch { self.error = "Verlauf konnte nicht geöffnet werden: \(error.localizedDescription)" }
        Task {
            if let operationService {
                do { let recovered = try await operationService.recover(); if !recovered.isEmpty { notices.append("Unterbrochener Lauf geprüft. Ergebnisse stehen im Verlauf.") }; await refreshHistory() }
                catch { self.error = error.localizedDescription }
            }
        }
        if CommandLine.arguments.contains("--demo") { showOnboarding = false; Task { await createDemo() } }
    }

    func saveConfiguration() {
        if analyzing { activeTask?.cancel() }
        if let data = try? JSONEncoder().encode(configuration) { UserDefaults.standard.set(data, forKey: "aiConfiguration") }
        serviceSignature = nil
    }
    private func refreshHistory() async {
        guard let operationService else { return }
        do {
            history = try await operationService.history()
            for id in runIDs { undoable[id] = Set(try await operationService.undoableOperationIDs(runID: id)) }
        } catch { self.error = error.localizedDescription }
    }
    func finishOnboarding() { UserDefaults.standard.set(true, forKey: "onboardingComplete"); showOnboarding = false }
    func selectFolder(destination pickingDestination: Bool = false) {
        guard !busy, !paused else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = pickingDestination ? "Ziel wählen" : "Ordner wählen"
        if panel.runModal() == .OK, let url = panel.url {
            access.retain(url)
            if pickingDestination { destination = url; invalidateAnalysis(); Task { await loadTargetFolders() } }
            else { if isDemo { context = "" }; source = url; isDemo = false; Task { await scan() } }
        }
    }
    func invalidateAnalysis() {
        files.removeAll { completedIDs.contains($0.id) }
        allowCloud = false; aiService = nil; serviceSignature = nil; analyzedSignature = nil; manualSignatures = [:]; runModeOverride = nil
        acceptedFolders = []; folderProposals = []; structureProposals = []; restructuring = false; completedIDs = []; lastEvent = nil; spentUSD = 0; reservedUSD = 0; carriedSpend = 0; carriedReserve = 0
        recommendations = files.map { Recommendation(file: $0) }; status = "\(files.count) Dateien bereit"
    }
    func loadTargetFolders() async {
        guard let root = targetRoot, !busy else { return }
        do { folders = try await scanner.scan(root: root, recursive: recursive).folders }
        catch { self.error = error.localizedDescription }
    }
    func scan() async {
        guard let source, !busy, !paused else { return }
        busy = true; error = nil; status = "Dateien werden erfasst"; defer { busy = false }
        do {
            let result = try await scanner.scan(root: source, recursive: recursive)
            files = result.files; folders = result.folders; notices = result.warnings; protectedIDs = Set(files.filter(\.isProtected).map(\.id))
            invalidateAnalysis(); duplicateGroups = []; duplicateChecked = false; selectedID = files.first?.id
        } catch { self.error = error.localizedDescription; status = "Ordner konnte nicht gelesen werden" }
    }
    func requestAnalysis() {
        guard !busy, !paused, source != nil, targetRoot != nil else { return }
        if configuration.mode == .hybrid {
            guard KeychainStore.read() != nil else { showSettings = true; error = "Hinterlege einen OpenRouter-Key oder wähle ‚Nur lokal‘."; return }
            showCloudConsent = true
        } else { startAnalysis() }
    }
    func startAnalysis() {
        guard !busy, !paused else { return }
        showCloudConsent = false
        activeTask = Task { await analyze() }
    }
    func startLocalAnalysis() {
        runModeOverride = .local; allowCloud = false; startAnalysis()
    }
    func startCloudAnalysis() {
        runModeOverride = nil; allowCloud = true; startAnalysis()
    }
    private func analyze() async {
        guard let targetRoot else { return }
        let runInputSignature = inputSignature
        busy = true; analyzing = true; error = nil; progress = 0; status = "Analyse wird vorbereitet"
        defer { busy = false; analyzing = false }
        do {
            var runConfiguration = configuration
            if let runModeOverride { runConfiguration.mode = runModeOverride }
            let signature = [runConfiguration.mode.rawValue, runConfiguration.textModel, runConfiguration.visionModel, runConfiguration.cloudTextModel, runConfiguration.cloudVisionModel, String(configuration.budgetUSD)].joined(separator: "|")
            do { try await ollama.ensureRunning() }
            catch { if runConfiguration.mode == .local || !allowCloud { throw error }; notices.append("Ollama nicht verfügbar. Freigegebene Cloudanalyse wird verwendet.") }
            if aiService == nil || serviceSignature != signature {
                if let previous = aiService { let usage = await previous.usage(); carriedSpend += usage.spentUSD; carriedReserve += usage.reservedUSD }
                runConfiguration.budgetUSD = max(0, configuration.budgetUSD - carriedSpend - carriedReserve)
                aiService = AIService(configuration: runConfiguration, apiKey: runConfiguration.mode == .hybrid ? KeychainStore.read() : nil); serviceSignature = signature
            }
            guard let service = aiService else { return }
            analyzedSignature = nil
            for index in recommendations.indices where !completedIDs.contains(recommendations[index].id) && manualSignatures[recommendations[index].id] != runInputSignature {
                recommendations[index] = Recommendation(file: recommendations[index].file)
            }
            var targets = folders
            if targetRoot.standardizedFileURL != source?.standardizedFileURL {
                targets = try await scanner.scan(root: targetRoot, recursive: recursive).folders
            }
            if restructuring {
                let replaced = Set(structureProposals.flatMap(\.replaces))
                targets.removeAll { replaced.contains($0) }
            }
            targets = Array(Set(targets + acceptedFolders)).sorted { $0.path < $1.path }
            folders = targets
            let candidates = files.filter { !completedIDs.contains($0.id) && !protectedIDs.contains($0.id) && manualSignatures[$0.id] != runInputSignature }
            for (index, file) in candidates.enumerated() {
                try Task.checkCancellation()
                status = "\(file.name) wird geprüft"
                do {
                    let result = try await service.analyze(file: file, folders: targets, context: context, allowCloud: allowCloud, allowOriginals: allowOriginals)
                    if let position = recommendations.firstIndex(where: { $0.id == file.id }) { recommendations[position] = result }
                } catch {
                    if error is CancellationError { throw error }
                    if let position = recommendations.firstIndex(where: { $0.id == file.id }) { recommendations[position].reason = error.localizedDescription }
                    if error.localizedDescription.localizedCaseInsensitiveContains("budget") || error.localizedDescription.localizedCaseInsensitiveContains("kostenlimit") { notices.append(error.localizedDescription); break }
                    if error.localizedDescription.contains("HTTP 401") || error.localizedDescription.contains("HTTP 402") || error.localizedDescription.contains("HTTP 403") { throw error }
                }
                let usage = await service.usage(); spentUSD = carriedSpend + usage.spentUSD; reservedUSD = carriedReserve + usage.reservedUSD
                progress = Double(index + 1) / Double(max(candidates.count, 1))
            }
            try Task.checkCancellation()
            let unmatched = recommendations.filter { $0.targetFolder == nil && !protectedIDs.contains($0.id) }
            if !unmatched.isEmpty {
                status = "Passende Ordner werden gesucht"
                do { folderProposals = try await service.proposeFolders(files: unmatched, existingFolders: targets, context: context, allowCloud: allowCloud) }
                catch { notices.append(error.localizedDescription) }
            }
            let usage = await service.usage(); spentUSD = carriedSpend + usage.spentUSD; reservedUSD = carriedReserve + usage.reservedUSD
            try Task.checkCancellation()
            analyzedSignature = runInputSignature
            status = "\(eligible.count) bereit, \(pendingQuestions.count) offen"; progress = 1
        } catch is CancellationError { status = "Analyse angehalten" }
        catch { self.error = error.localizedDescription; status = "Analyse angehalten" }
        if let aiService {
            let usage = await aiService.usage()
            spentUSD = carriedSpend + usage.spentUSD; reservedUSD = carriedReserve + usage.reservedUSD
        }
    }
    func checkStructure() async {
        guard let service = aiService, structureCheckAvailable, !busy else { return }
        busy = true; error = nil; status = "Vorhandene Struktur wird geprüft"; defer { busy = false }
        do {
            structureProposals = try await service.proposeStructure(files: recommendations, existingFolders: folders, context: context, allowCloud: allowCloud)
            let usage = await service.usage(); spentUSD = carriedSpend + usage.spentUSD; reservedUSD = carriedReserve + usage.reservedUSD
            if structureProposals.isEmpty { status = "Vorhandene Struktur bleibt bestehen" }
            else { showStructureReview = true; status = "Strukturvorschlag bereit" }
        } catch { self.error = error.localizedDescription }
    }
    func acceptStructure() {
        guard let root = targetRoot else { return }
        acceptedFolders = structureProposals.map { root.appendingPathComponent($0.name, isDirectory: true) }
        restructuring = true; showStructureReview = false
        // Existing directories remain until their contents are explicitly moved.
        startAnalysis()
    }
    func stopAnalysis() { activeTask?.cancel() }
    func acceptFolder(_ proposal: FolderProposal) {
        guard let root = targetRoot else { return }
        let clean = proposal.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != ".", clean != "..", !clean.contains("/"), !clean.contains(":"), !clean.contains("\0"), !clean.hasPrefix(".") else { error = "Wähle einen gültigen Ordnernamen."; return }
        let url = root.appendingPathComponent(clean, isDirectory: true)
        if !acceptedFolders.contains(url) { acceptedFolders.append(url) }
        folderProposals.removeAll { $0.id == proposal.id }
        status = "Ordner ergänzt. Zuordnungen erneut prüfen."
    }
    func setTarget(id: UUID, target: URL?, importance: Importance? = nil) {
        guard let index = recommendations.firstIndex(where: { $0.id == id }) else { return }
        recommendations[index].targetFolder = target; recommendations[index].isApproved = target != nil; recommendations[index].needsQuestion = target == nil
        manualSignatures[id] = inputSignature
        if let importance { recommendations[index].importance = importance }
    }
    func keep(id: UUID) { protectedIDs.insert(id) }
    func sortEligible(confirmedStructure: Bool = false) {
        guard let source, let targetRoot, !busy, !paused else { return }
        if restructuring && !confirmedStructure { showStructureReview = true; return }
        var operations: [PlannedOperation] = []
        let sorted = eligible
        var destinations: Set<String> = []
        for recommendation in sorted {
            guard let folder = recommendation.targetFolder else { continue }
            let destination = folder.appendingPathComponent(recommendation.file.name)
            if destination.standardizedFileURL == recommendation.file.url.standardizedFileURL { continue }
            guard !FileManager.default.fileExists(atPath: destination.path), destinations.insert(destination.path.lowercased()).inserted else {
                notices.append("\(recommendation.file.name): Zielname bereits belegt."); continue
            }
            operations.append(.init(kind: .move, source: recommendation.file.url, destination: destination, snapshot: recommendation.file, requiresConfirmation: restructuring, reason: recommendation.reason))
        }
        let neededFolders = Set(operations.compactMap { $0.destination?.deletingLastPathComponent() })
        let creates = neededFolders.filter { !FileManager.default.fileExists(atPath: $0.path) }.sorted { $0.path < $1.path }.map { PlannedOperation(kind: .createDirectory, source: $0, destination: $0, reason: "Zielordner ergänzen") }
        let plan = OrganizationPlan(sourceRoot: source, destinationRoot: targetRoot, operations: creates + operations)
        guard !plan.operations.isEmpty else { status = "Keine Dateien zum Verschieben"; return }
        activeTask = Task { await execute(plan: plan, sensitive: confirmedStructure) }
    }
    func pauseRun() async {
        paused = true; status = "Lauf wird angehalten"; await operationService?.pause()
    }
    func resumeRun() async {
        paused = false; await operationService?.resume()
        if let pausedPlan { activeTask = Task { await execute(plan: pausedPlan, sensitive: pausedSensitive) } }
    }
    private var pausedPlan: OrganizationPlan?
    private var pausedSensitive = false
    private func execute(plan: OrganizationPlan, sensitive: Bool = false) async {
        guard let operationService else { return }
        busy = true; sorting = true; error = nil; lastRunID = plan.id; pausedPlan = plan; pausedSensitive = sensitive
        defer { busy = false; sorting = false }
        do {
            _ = try await operationService.execute(plan: plan, confirmedSensitive: sensitive, onEvent: { [weak self] event in await self?.receive(event) })
            await refreshHistory()
            let events = history.filter { $0.runID == plan.id }
            let conflicts = events.filter { $0.state == .failed || $0.state == .conflict }
            status = paused ? "Lauf angehalten" : conflicts.isEmpty ? "Aufgeräumt" : "Lauf beendet. \(conflicts.count) Aktionen bitte prüfen."
            if !paused { pausedPlan = nil }
        } catch { self.error = error.localizedDescription; status = "Lauf angehalten"; await refreshHistory() }
    }
    private func receive(_ event: RunEvent) {
        lastEvent = event
        if event.state == .completed, let snapshot = event.operation.snapshot { completedIDs.insert(snapshot.id) }
        if event.state == .completed, let snapshot = event.operation.snapshot { duplicateGroups = duplicateGroups.map { $0.filter { $0.id != snapshot.id } }.filter { $0.count > 1 } }
        if event.state == .failed || event.state == .conflict { notices.append(event.message) }
        if event.state == .completed { status = "\(event.operation.source.lastPathComponent) sortiert" }
    }
    func renameSelected() async {
        guard !busy, !paused, let recommendation = selected, let name = recommendation.suggestedName, let source else { return }
        let destination = recommendation.file.url.deletingLastPathComponent().appendingPathComponent(name)
        let operation = PlannedOperation(kind: .rename, source: recommendation.file.url, destination: destination, snapshot: recommendation.file, requiresConfirmation: true, reason: "Dateiname bestätigt")
        await execute(plan: .init(sourceRoot: source, destinationRoot: source, operations: [operation]), sensitive: true)
        await scan()
    }
    func trash(_ selectedFiles: [FileSnapshot]) async {
        guard !busy, !paused, let source, let targetRoot else { return }
        let operations = selectedFiles.map { PlannedOperation(kind: .trash, source: $0.url, snapshot: $0, requiresConfirmation: true, reason: "Papierkorb bestätigt") }
        await execute(plan: .init(sourceRoot: source, destinationRoot: targetRoot, operations: operations), sensitive: true)
        await scan()
    }
    func undo(_ runID: UUID) async {
        guard let operationService, !busy, !paused else { return }
        busy = true; error = nil
        do { let events = try await operationService.undo(runID: runID); await refreshHistory(); status = events.contains { $0.state == .conflict } ? "Einige Änderungen bitte im Verlauf prüfen" : "Lauf rückgängig gemacht" }
        catch { self.error = error.localizedDescription }
        busy = false; await scan()
    }
    func undoAction(runID: UUID, operationID: UUID) async {
        guard let operationService, !busy, !paused else { return }
        busy = true
        do { _ = try await operationService.undo(runID: runID, operationID: operationID); await refreshHistory() }
        catch { self.error = error.localizedDescription }
        busy = false; await scan()
    }
    func findDuplicates() async {
        guard !busy, !paused else { return }
        busy = true; status = "Dateiinhalte werden verglichen"; defer { busy = false }
        let candidates = files.filter { !$0.isDirectory && !$0.isProtected && !completedIDs.contains($0.id) }
        do {
            duplicateGroups = try await Task.detached(priority: .utility) {
                var matched: [String: [FileSnapshot]] = [:]
                let sizes = Dictionary(grouping: candidates, by: \.size).values.filter { $0.count > 1 }
                for group in sizes {
                    for file in group {
                        try Task.checkCancellation()
                        let handle = try FileHandle(forReadingFrom: file.url); defer { try? handle.close() }
                        var hasher = SHA256()
                        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hasher.update(data: data) }
                        let key = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                        matched[key, default: []].append(file)
                    }
                }
                return matched.values.filter { $0.count > 1 }.sorted { $0[0].name < $1[0].name }
            }.value
            duplicateChecked = true; status = "\(duplicateGroups.count) Gruppen mit gleichem Inhalt"
        } catch { self.error = error.localizedDescription }
    }
    func createDemo() async {
        guard !busy, !paused else { return }
        do {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Fach/Beispiele/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for name in ["Schule", "Reisen", "Rechnungen", "Archiv"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
            let examples = ["Mathe-Prüfung.txt": "Mathematik: Prüfungsvorbereitung. Aufgaben zu quadratischen Funktionen. Diese Woche weiter bearbeiten.", "Reiseplan.txt": "Sommerreise nach Kopenhagen: Museum, Fahrradtour und Hotel. Abgeschlossene Reise, als Erinnerung behalten.", "Rechnung-Beispiel.txt": "Beispielrechnung für ein Fahrrad. Betrag 180 Euro. Bezahlt. Kaufbeleg aufbewahren.", "Notizen.txt": "Notizen zu einem noch nicht zugeordneten Vorhaben.", "Rechnung-Kopie.txt": "Beispielrechnung für ein Fahrrad. Betrag 180 Euro. Bezahlt. Kaufbeleg aufbewahren."]
            for (name, content) in examples { try Data(content.utf8).write(to: root.appendingPathComponent(name), options: .atomic) }
            source = root; destination = nil; useSeparateDestination = false; recursive = false; isDemo = true; context = "Schulaufgaben sind aktiv. Abgeschlossene Reisen und bezahlte Belege aufbewahren."
            await scan()
            // Demonstration proposals use only the explicitly labeled sample corpus.
            recommendations = files.map { file in
                let target: String? = file.name.contains("Mathe") ? "Schule" : file.name.contains("Reise") ? "Reisen" : file.name.contains("Rechnung") ? "Rechnungen" : nil
                return Recommendation(file: file, targetFolder: target.map { root.appendingPathComponent($0) }, importance: file.name.contains("Mathe") ? .active : target == nil ? .open : .archive, confidence: target == nil ? 0 : 0.97, margin: target == nil ? 0 : 0.7, reason: target == nil ? "Zu welchem Vorhaben gehören diese Notizen?" : "Beispielzuordnung", evidence: .init(summary: examples[file.name] ?? "", sufficient: target != nil, origin: "Beispieldateien"), needsQuestion: target == nil)
            }
            analyzedSignature = inputSignature
            status = "Beispiel bereit"; showOnboarding = false
        } catch { self.error = error.localizedDescription }
    }
}
