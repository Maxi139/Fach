import AppKit
import CryptoKit
import Foundation
import Observation
import FachCore
import FachAI

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case organize = "Aufräumen", questions = "Ohne Ziel", duplicates = "Dubletten", history = "Verlauf"
    var id: String { rawValue }
    var symbol: String { switch self { case .organize: "tray.2"; case .questions: "questionmark.bubble"; case .duplicates: "doc.on.doc"; case .history: "clock.arrow.circlepath" } }
}

enum FileGroupFilter: String, CaseIterable, Identifiable {
    case all = "Alle", images = "Bilder", videos = "Videos", documents = "Dokumente", audio = "Audio", other = "Andere"
    var id: String { rawValue }

    func includes(_ file: FileSnapshot) -> Bool {
        guard self != .all else { return true }
        let ext = file.url.pathExtension.lowercased()
        let image = ["jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp", "raw"]
        let video = ["mov", "mp4", "m4v", "avi", "mkv", "webm"]
        let audio = ["mp3", "m4a", "aac", "wav", "aiff", "flac", "ogg"]
        let document = ["pdf", "txt", "rtf", "md", "doc", "docx", "pages", "xls", "xlsx", "numbers", "ppt", "pptx", "key", "csv", "json", "swift", "py", "js", "ts", "zip"]
        return switch self {
        case .all: true
        case .images: image.contains(ext)
        case .videos: video.contains(ext)
        case .documents: document.contains(ext)
        case .audio: audio.contains(ext)
        case .other: !image.contains(ext) && !video.contains(ext) && !audio.contains(ext) && !document.contains(ext)
        }
    }
}

enum OrganizationFilter: String, CaseIterable, Identifiable {
    case all = "Alle", withTarget = "Mit Ziel", withoutTarget = "Ohne Ziel", kept = "Bleibt hier", sorted = "Sortiert", trash = "Zum Löschen"
    var id: String { rawValue }
}

@MainActor @Observable
final class AppModel {
    var configuration = AIConfiguration()
    var source: URL?
    var destination: URL?
    var useSeparateDestination = false
    var recursive = false
    var context = "" {
        didSet { if context != oldValue { persistDraft() } }
    }
    var files: [FileSnapshot] = []
    var folders: [URL] = []
    var recommendations: [Recommendation] = []
    var folderProposals: [FolderProposal] = []
    var structureProposals: [FolderProposal] = []
    var showStructureReview = false
    var restructuring = false
    var acceptedFolders: [URL] = []
    var selectedID: UUID?
    var selectedIDs: Set<UUID> = []
    var selectionAnchor: UUID?
    /// The focused, keyboard-first review sequence. It is intentionally not
    /// persisted: a new review should always begin from the user's live view.
    var stackMode = false
    private(set) var fileDeck = FileDeck()
    var stackLastAction: String?
    var section: WorkspaceSection = .organize { didSet { pruneSelection() } }
    var importanceFilter: Importance? { didSet { pruneSelection() } }
    var fileGroupFilter: FileGroupFilter = .all { didSet { pruneSelection() } }
    var organizationFilter: OrganizationFilter = .all { didSet { pruneSelection() } }
    var search = "" { didSet { pruneSelection() } }
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
    var showSortReview = false
    var showSettings = false
    var showOnboarding = !UserDefaults.standard.bool(forKey: "onboardingComplete")
    var showCloudConsent = false
    var allowCloud = false
    var allowOriginals = true
    var completedIDs: Set<UUID> = []
    var protectedIDs: Set<UUID> = []
    var markedTrashIDs: Set<UUID> = []
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
    private var draftURL: URL?
    private var restoringDraft = false
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
    var stackCurrent: Recommendation? {
        guard let id = fileDeck.currentID,
              let recommendation = recommendations.first(where: { $0.id == id }),
              !completedIDs.contains(id), !protectedIDs.contains(id),
              !recommendation.file.isProtected, !recommendation.file.isDirectory
        else { return nil }
        return recommendation
    }
    var stackRemainingCount: Int { fileDeck.remainingCount }
    var pendingQuestions: [Recommendation] {
        return recommendations.filter {
            !completedIDs.contains($0.id) && !protectedIDs.contains($0.id) && !markedTrashIDs.contains($0.id) &&
            ($0.targetFolder == nil || ($0.requiresIndividualReview ?? false))
        }
    }
    var confirmedAssignmentCount: Int { recommendations.filter { isConfirmed($0.id) }.count }
    var pendingManualConfirmationCount: Int {
        recommendations.filter { !completedIDs.contains($0.id) && !protectedIDs.contains($0.id) && $0.targetFolder != nil && !isConfirmed($0.id) }.count
    }
    var batchCandidates: [Recommendation] {
        guard !restructuring else { return [] }
        let existing = availableTargets.filter {
            if acceptedFolders.contains($0), !FileManager.default.fileExists(atPath: $0.path) { return true }
            guard let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
        return AssignmentReview.batchCandidates(recommendations: recommendations.filter { !markedTrashIDs.contains($0.id) }, existingTargets: existing,
            completedIDs: completedIDs, protectedIDs: protectedIDs)
    }
    var sortReviewCandidates: [Recommendation] {
        let batchIDs = Set(batchCandidates.map(\.id))
        let eligibleIDs = Set(eligible.map(\.id))
        return recommendations.filter { batchIDs.contains($0.id) || eligibleIDs.contains($0.id) }
    }
    var canReviewBatch: Bool { batchCandidates.contains { !isConfirmed($0.id) } }
    func acceptBatchAndSort(ids: Set<UUID>) {
        guard !busy, !paused, !ids.isEmpty else { return }
        let current = Set(batchCandidates.map(\.id))
        guard ids.isSubset(of: current) else {
            error = "Vorschläge haben sich geändert. Bitte Übersicht erneut öffnen."
            return
        }
        for index in recommendations.indices where ids.contains(recommendations[index].id) {
            recommendations[index].isApproved = true
            recommendations[index].needsQuestion = false
            manualSignatures[recommendations[index].id] = inputSignature
        }
        refreshManualStatus()
        persistDraft()
        sortEligible(onlyIDs: ids)
    }
    var eligible: [Recommendation] { recommendations.filter { !completedIDs.contains($0.id) && !protectedIDs.contains($0.id) && !markedTrashIDs.contains($0.id) && $0.targetFolder != nil && $0.isApproved && manualSignatures[$0.id] == inputSignature && !($0.requiresIndividualReview ?? false) } }
    var visible: [Recommendation] {
        let sourceList = recommendations
        return sourceList.filter {
            (importanceFilter == nil || $0.importance == importanceFilter) &&
            fileGroupFilter.includes($0.file) &&
            matchesOrganizationFilter($0) &&
            (search.isEmpty || $0.file.name.localizedCaseInsensitiveContains(search) || ($0.targetFolder?.lastPathComponent.localizedCaseInsensitiveContains(search) ?? false))
        }.sorted { left, right in
            let leftGroup = left.targetFolder?.path ?? "\u{ffff}"
            let rightGroup = right.targetFolder?.path ?? "\u{ffff}"
            if leftGroup != rightGroup { return leftGroup.localizedStandardCompare(rightGroup) == .orderedAscending }
            return left.file.name.localizedStandardCompare(right.file.name) == .orderedAscending
        }
    }
    var visibleSelectable: [Recommendation] {
        visible.filter { !completedIDs.contains($0.id) && !protectedIDs.contains($0.id) && !$0.file.isProtected && !$0.file.isDirectory }
    }
    var selectedFiles: [Recommendation] { visible.filter { selectedIDs.contains($0.id) } }
    var selectedEligible: [Recommendation] {
        let eligibleIDs = Set(eligible.map(\.id))
        return selectedFiles.filter { eligibleIDs.contains($0.id) }
    }
    var unassignedCount: Int {
        recommendations.filter { !completedIDs.contains($0.id) && !protectedIDs.contains($0.id) && !markedTrashIDs.contains($0.id) && $0.targetFolder == nil }.count
    }
    var markedTrashFiles: [FileSnapshot] {
        recommendations.filter { markedTrashIDs.contains($0.id) && !completedIDs.contains($0.id) && !protectedIDs.contains($0.id) && !$0.file.isProtected && !$0.file.isDirectory }.map(\.file)
    }
    var runIDs: [UUID] { Array(Set(history.map(\.runID))).sorted { left, right in (history.first { $0.runID == left }?.date ?? .distantPast) > (history.first { $0.runID == right }?.date ?? .distantPast) } }
    func folderLabel(_ url: URL) -> String {
        guard let root = targetRoot else { return url.lastPathComponent }
        let path = url.standardizedFileURL.path, prefix = root.standardizedFileURL.path + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
    }
    private func matchesOrganizationFilter(_ recommendation: Recommendation) -> Bool {
        return switch organizationFilter {
        case .all: true
        case .withTarget: recommendation.targetFolder != nil && !markedTrashIDs.contains(recommendation.id) && !completedIDs.contains(recommendation.id)
        case .withoutTarget: recommendation.targetFolder == nil && !markedTrashIDs.contains(recommendation.id) && !completedIDs.contains(recommendation.id) && !protectedIDs.contains(recommendation.id)
        case .kept: protectedIDs.contains(recommendation.id) || recommendation.file.isProtected
        case .sorted: completedIDs.contains(recommendation.id)
        case .trash: markedTrashIDs.contains(recommendation.id)
        }
    }
    func pruneSelection() {
        let visibleIDs = Set(visibleSelectable.map(\.id))
        selectedIDs.formIntersection(visibleIDs)
        if let selectionAnchor, !visibleIDs.contains(selectionAnchor) { self.selectionAnchor = nil }
        let allVisibleIDs = Set(visible.map(\.id))
        if let selectedID, !allVisibleIDs.contains(selectedID) { self.selectedID = selectedIDs.first }
        if selectedIDs.count == 1 { selectedID = selectedIDs.first }
    }
    func selectFile(id: UUID, extendingRange: Bool = false) {
        let orderedIDs = visibleSelectable.map(\.id)
        guard orderedIDs.contains(id) else { return }
        let anchorIsVisible = selectionAnchor.map { orderedIDs.contains($0) } ?? false
        selectedIDs = FileSelection.toggled(id: id, selected: selectedIDs, orderedIDs: orderedIDs,
                                            anchor: selectionAnchor, extendingRange: extendingRange)
        if !extendingRange || !anchorIsVisible { selectionAnchor = id }
        selectedID = id
    }
    func selectAllVisible() {
        let visible = visibleSelectable
        selectedIDs = Set(visible.map(\.id))
        selectionAnchor = visible.first?.id
        selectedID = visible.first?.id
    }
    func selectGroup(ids: Set<UUID>) {
        let visibleIDs = Set(visibleSelectable.map(\.id))
        let group = ids.intersection(visibleIDs)
        guard !group.isEmpty else { return }
        if group.isSubset(of: selectedIDs) { selectedIDs.subtract(group) }
        else { selectedIDs.formUnion(group) }
        selectionAnchor = group.sorted { $0.uuidString < $1.uuidString }.first
    }
    func clearSelection() {
        selectedIDs = []
        selectionAnchor = nil
    }

    /// Starts from the currently visible files, rather than the current
    /// selection, so a user can quickly review a whole filtered collection.
    func startStackMode() {
        guard !busy, !paused else { return }
        let candidates = visibleSelectable.filter { !markedTrashIDs.contains($0.id) }
        fileDeck = FileDeck(ids: candidates.map(\.id), preferredID: selectedID)
        stackMode = fileDeck.currentID != nil
        stackLastAction = nil
        if stackMode {
            focusStackCurrent()
        } else {
            status = "Keine offenen Dateien für den Schnellmodus"
        }
    }

    func endStackMode() {
        stackMode = false
        fileDeck = FileDeck()
        stackLastAction = nil
        selectedID = nil
        clearSelection()
    }

    func stackNavigate(direction: Int) {
        guard stackMode, !busy, !paused else { return }
        refreshStackDeck()
        _ = fileDeck.navigate(direction: direction)
        focusStackCurrent()
    }

    /// Assigns only the currently previewed file. The existing draft path
    /// records the manual decision; it does not move a file.
    @discardableResult
    func assignStackCurrent(target: URL) -> Bool {
        guard stackMode, !busy, !paused, let root = targetRoot,
              let current = stackCurrent else { return false }
        let normalized = target.standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        let knownTargetPaths = Set(availableTargets.map { $0.standardizedFileURL.path })
        guard (normalized.path == rootPath || normalized.path.hasPrefix(rootPath + "/")),
              knownTargetPaths.contains(normalized.path) else {
            error = "Dieser Zielordner ist nicht verfügbar."
            return false
        }
        setTarget(id: current.id, target: normalized, importance: current.importance)
        stackLastAction = "Zugeordnet zu \(folderLabel(normalized))"
        _ = fileDeck.handleCurrent()
        focusStackCurrent()
        return true
    }

    /// Delete only records a reversible mark. It never sends the file to the
    /// Trash from the keyboard review mode.
    @discardableResult
    func markStackCurrentForTrash() -> Bool {
        guard stackMode, !busy, !paused, let current = stackCurrent else { return false }
        markedTrashIDs.insert(current.id)
        stackLastAction = "Für den Papierkorb vorgemerkt"
        refreshManualStatus()
        persistDraft()
        _ = fileDeck.handleCurrent()
        focusStackCurrent()
        return true
    }

    /// Remove only files that the core model says can no longer be handled.
    /// This is deliberately never called by filtering or searching.
    func refreshStackDeck() {
        guard stackMode else { return }
        let available = Set(recommendations.filter {
            !completedIDs.contains($0.id) && !protectedIDs.contains($0.id) &&
            !$0.file.isProtected && !$0.file.isDirectory
        }.map(\.id))
        _ = fileDeck.reconcile(availableIDs: available)
    }

    private func focusStackCurrent() {
        guard stackMode, let id = fileDeck.currentID else {
            selectedID = nil
            clearSelection()
            return
        }
        selectedID = id
        selectedIDs = [id]
        selectionAnchor = id
    }
    func assignSelection(target: URL) {
        guard !busy, !paused, let root = targetRoot else { return }
        let normalized = target.standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        let knownTargetPaths = Set(availableTargets.map { $0.standardizedFileURL.path })
        guard (normalized.path == rootPath || normalized.path.hasPrefix(rootPath + "/")), knownTargetPaths.contains(normalized.path) else {
            error = "Dieser Zielordner ist nicht verfügbar."
            return
        }
        let ids = Set(selectedFiles.map(\.id)).intersection(Set(visibleSelectable.map(\.id)))
        guard !ids.isEmpty else { return }
        for index in recommendations.indices where ids.contains(recommendations[index].id) {
            recommendations[index].targetFolder = normalized
            recommendations[index].isApproved = true
            recommendations[index].needsQuestion = false
            recommendations[index].requiresIndividualReview = false
            manualSignatures[recommendations[index].id] = inputSignature
        }
        markedTrashIDs.subtract(ids)
        refreshManualStatus()
        persistDraft()
    }
    func keepSelection() {
        guard !busy, !paused else { return }
        let ids = Set(selectedFiles.map(\.id)).intersection(Set(visibleSelectable.map(\.id)))
        guard !ids.isEmpty else { return }
        protectedIDs.formUnion(ids)
        markedTrashIDs.subtract(ids)
        clearSelection()
        refreshManualStatus()
        persistDraft()
    }
    func sortSelection() {
        let ids = Set(selectedEligible.map(\.id))
        guard !ids.isEmpty else { return }
        sortEligible(onlyIDs: ids)
    }
    func markSelectionForTrash() {
        guard !busy, !paused else { return }
        let ids = Set(selectedFiles.map(\.id)).intersection(Set(visibleSelectable.map(\.id)))
        guard !ids.isEmpty else { return }
        if ids.isSubset(of: markedTrashIDs) { markedTrashIDs.subtract(ids) }
        else { markedTrashIDs.formUnion(ids) }
        persistDraft()
    }
    func cancelTrashMarks(ids: Set<UUID>) {
        guard !busy, !paused else { return }
        markedTrashIDs.subtract(ids)
        pruneSelection()
        persistDraft()
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: "aiConfiguration"), let saved = try? JSONDecoder().decode(AIConfiguration.self, from: data) { configuration = saved }
        access.restore()
        do {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Fach")
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            operationService = try FileOperationService(databaseURL: support.appendingPathComponent("runs.sqlite3"))
            draftURL = support.appendingPathComponent("analysis-draft.json")
        } catch { self.error = "Verlauf konnte nicht geöffnet werden: \(error.localizedDescription)" }
        Task {
            if let operationService {
                do { let recovered = try await operationService.recover(); if !recovered.isEmpty { notices.append("Unterbrochener Lauf geprüft. Ergebnisse stehen im Verlauf.") }; await refreshHistory() }
                catch { self.error = error.localizedDescription }
            }
        }
        if CommandLine.arguments.contains("--demo") { showOnboarding = false; Task { await createDemo() } }
        else { Task {
            await restoreAnalysisDraft()
            if let index = CommandLine.arguments.firstIndex(of: "--sorting-plan"), CommandLine.arguments.indices.contains(index + 1) {
                await importSortingPlan(URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            }
        } }
    }

    func saveConfiguration() {
        if analyzing { activeTask?.cancel() }
        if let data = try? JSONEncoder().encode(configuration) { UserDefaults.standard.set(data, forKey: "aiConfiguration") }
        serviceSignature = nil
        persistDraft()
    }

    private func makeDraft(includeDemo: Bool = false) -> AnalysisDraft? {
        guard let source, (!isDemo || includeDemo) else { return nil }
        return AnalysisDraft(source: source, destination: destination, useSeparateDestination: useSeparateDestination,
                             recursive: recursive, context: context,
                             configurationData: try? JSONEncoder().encode(configuration), files: files, folders: folders,
                             recommendations: recommendations, folderProposals: folderProposals,
                             structureProposals: structureProposals, showStructureReview: showStructureReview,
                             restructuring: restructuring, acceptedFolders: acceptedFolders, protectedIDs: protectedIDs,
                             completedIDs: completedIDs, markedTrashIDs: markedTrashIDs, manualSignatures: manualSignatures,
                             inputSignature: inputSignature, analyzedSignature: analyzedSignature,
                             spentUSD: spentUSD, reservedUSD: reservedUSD)
    }

    private func persistDraft() {
        guard !restoringDraft, let draftURL, let draft = makeDraft() else { return }
        do { try draft.save(to: draftURL) }
        catch { notices.append("Analyse konnte nicht gesichert werden: \(error.localizedDescription)") }
    }

    private func restoreAnalysisDraft() async {
        guard let draftURL else { return }
        do {
            if FileManager.default.fileExists(atPath: draftURL.path) {
                try applyRestoredDraft(AnalysisDraft.load(from: draftURL))
                return
            }
            let recoveryURL = draftURL.deletingLastPathComponent().appendingPathComponent("recovered-assignments.json")
            guard FileManager.default.fileExists(atPath: recoveryURL.path) else { return }
            let recovered = try RecoveredAssignments.load(from: recoveryURL)
            let root = URL(fileURLWithPath: recovered.sourceRoot).standardizedFileURL
            let freshScan = try await scanner.scan(root: root, recursive: false)
            let imported = try recovered.importedDraft(scan: freshScan, recursive: false)
            try applyRestoredDraft(imported)
            persistDraft() // Keep recovered-assignments.json intact as the original backup.
            notices.append("Vorherige Zuordnungen wurden als offene Bestätigungen wiederhergestellt.")
        } catch {
            self.error = "Gesicherte Analyse konnte nicht wiederhergestellt werden: \(error.localizedDescription)"
        }
    }

    private func applyRestoredDraft(_ draft: AnalysisDraft) throws {
        restoringDraft = true
        defer { restoringDraft = false }
        let restored = draft.restore()
        source = draft.source; destination = draft.destination; useSeparateDestination = draft.useSeparateDestination
        recursive = draft.recursive; context = draft.context; isDemo = false
        if let data = draft.configurationData, let saved = try? JSONDecoder().decode(AIConfiguration.self, from: data) {
            configuration = saved
        }
        files = restored.files; folders = restored.folders; recommendations = restored.recommendations
        folderProposals = restored.folderProposals; structureProposals = restored.structureProposals
        showStructureReview = draft.showStructureReview; restructuring = draft.restructuring
        acceptedFolders = restored.acceptedFolders; protectedIDs = restored.protectedIDs; completedIDs = restored.completedIDs; markedTrashIDs = restored.markedTrashIDs
        manualSignatures = restored.manualSignatures
        spentUSD = draft.spentUSD; reservedUSD = draft.reservedUSD; carriedSpend = spentUSD; carriedReserve = reservedUSD
        allowCloud = false; showCloudConsent = false; aiService = nil; serviceSignature = nil; runModeOverride = nil
        analyzedSignature = restored.staleIDs.isEmpty && draft.analyzedSignature == inputSignature ? draft.analyzedSignature : nil
        selectedID = recommendations.first?.id
        clearSelection()
        status = "Analyse wiederhergestellt: \(eligible.count) bereit, \(pendingQuestions.count) offen"
        if !restored.staleIDs.isEmpty { notices.append("\(restored.staleIDs.count) geänderte Dateien bitte erneut bestätigen.") }
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
        endStackMode()
        files.removeAll { completedIDs.contains($0.id) }
        allowCloud = false; aiService = nil; serviceSignature = nil; analyzedSignature = nil; manualSignatures = [:]; runModeOverride = nil
        acceptedFolders = []; folderProposals = []; structureProposals = []; restructuring = false; completedIDs = []; markedTrashIDs = []; lastEvent = nil; spentUSD = 0; reservedUSD = 0; carriedSpend = 0; carriedReserve = 0
        recommendations = files.map { Recommendation(file: $0) }; status = "\(files.count) Dateien bereit"
        clearSelection()
    }
    func loadTargetFolders() async {
        guard let root = targetRoot, !busy else { return }
        do { folders = try await scanner.scan(root: root, recursive: recursive).folders; persistDraft() }
        catch { self.error = error.localizedDescription }
    }
    func scan() async {
        guard let source, !busy, !paused else { return }
        busy = true; error = nil; status = "Dateien werden erfasst"; defer { busy = false }
        do {
            let result = try await scanner.scan(root: source, recursive: recursive)
            files = result.files; folders = result.folders; notices = result.warnings; protectedIDs = Set(files.filter(\.isProtected).map(\.id))
            invalidateAnalysis(); duplicateGroups = []; duplicateChecked = false; selectedID = files.first?.id
            clearSelection()
            persistDraft()
        } catch { self.error = error.localizedDescription; status = "Ordner konnte nicht gelesen werden" }
    }
    private func refreshPreservingAssignments() async {
        guard let source, let draft = makeDraft(includeDemo: true), !busy, !paused else { return }
        busy = true
        defer { busy = false }
        do {
            let fresh = try await scanner.scan(root: source, recursive: recursive)
            let restored = draft.restore()
            let knownFiles = Dictionary(uniqueKeysWithValues: restored.files.map { ($0.url.standardizedFileURL.path, $0) })
            files = fresh.files.map { knownFiles[$0.url.standardizedFileURL.path] ?? $0 }
            let validIDs = Set(files.map(\.id))
            recommendations = restored.recommendations.filter { validIDs.contains($0.id) }
            let assignedIDs = Set(recommendations.map(\.id))
            recommendations += files.filter { !assignedIDs.contains($0.id) }.map { Recommendation(file: $0) }
            if targetRoot?.standardizedFileURL == source.standardizedFileURL { folders = fresh.folders }
            protectedIDs = restored.protectedIDs.intersection(validIDs).union(Set(files.filter(\.isProtected).map(\.id)))
            completedIDs = restored.completedIDs.intersection(validIDs)
            markedTrashIDs = restored.markedTrashIDs.intersection(validIDs)
            manualSignatures = restored.manualSignatures.filter { validIDs.contains($0.key) }
            pruneSelection()
            refreshStackDeck()
            focusStackCurrent()
            duplicateGroups = []; duplicateChecked = false
            persistDraft()
        } catch { self.error = "Dateien konnten nicht aktualisiert werden: \(error.localizedDescription)" }
    }
    /// A curated plan is a local proposal, never permission to move files.
    private func importSortingPlan(_ url: URL) async {
        guard !busy, !paused else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? Int.max
            guard size <= 2 * 1024 * 1024 else { throw FachError.message("Sortierplan ist zu groß.") }
            let data = try Data(contentsOf: url)
            guard data.count <= 2 * 1024 * 1024 else { throw FachError.message("Sortierplan ist zu groß.") }
            let plan = try JSONDecoder().decode(ReviewedSortingPlan.self, from: data)
            guard source?.standardizedFileURL == plan.source.standardizedFileURL, !useSeparateDestination else {
                throw FachError.message("Sortierplan gehört zu einem anderen Ordner.")
            }
            let scan = try await scanner.scan(root: plan.source, recursive: recursive)
            let old = makeDraft()?.restore()
            let known = Dictionary(uniqueKeysWithValues: (old?.files ?? []).map { ($0.url.standardizedFileURL, $0) })
            let stableFiles = scan.files.map { known[$0.url.standardizedFileURL] ?? $0 }
            let resolved = try plan.resolve(scan: ScanResult(files: stableFiles, folders: scan.folders))
            let validIDs = Set(stableFiles.map(\.id))
            let retained = Dictionary(uniqueKeysWithValues: (old?.recommendations ?? []).filter { validIDs.contains($0.id) }.map { ($0.id, $0) })
            let signatures = old?.manualSignatures ?? [:]
            var proposed = Dictionary(uniqueKeysWithValues: resolved.recommendations.map { ($0.id, $0) })
            protectedIDs = (old?.protectedIDs ?? []).intersection(validIDs)
            markedTrashIDs = CommandLine.arguments.contains("--replace-delete-marks") ? [] : (old?.markedTrashIDs ?? []).intersection(validIDs)
            completedIDs = (old?.completedIDs ?? []).intersection(validIDs)
            for (id, item) in retained where signatures[id] == inputSignature || protectedIDs.contains(id) || markedTrashIDs.contains(id) || completedIDs.contains(id) {
                proposed[id] = item
            }
            files = stableFiles; folders = scan.folders
            recommendations = files.map { proposed[$0.id] ?? retained[$0.id] ?? Recommendation(file: $0) }
            acceptedFolders = Array(Set(acceptedFolders + resolved.newFolders))
            manualSignatures = signatures.filter { validIDs.contains($0.key) }
            analyzedSignature = inputSignature
            allowCloud = false
            notices = scan.warnings
            let changedCount = recommendations.filter { $0.requiresIndividualReview ?? false }.count
            if changedCount > 0 { notices.append("\(changedCount) geänderte Dateien bitte erneut bestätigen.") }
            endStackMode(); pruneSelection()
            status = "Sortierplan bereit: \(batchCandidates.count) Dateien mit Ziel"
            persistDraft()
        } catch { self.error = "Sortierplan konnte nicht geladen werden: \(error.localizedDescription)" }
    }

    /// Fast, local suggestions first; no model or cloud request is needed here.
    func improveAssignments() async {
        guard !busy, !paused, source != nil else { return }
        error = nil
        await refreshPreservingAssignments()
        guard error == nil, let root = targetRoot else { return }
        busy = true; analyzing = true; progress = 0
        defer { busy = false; analyzing = false }
        let profiles = await folderProfiles(for: availableTargets)
        let candidates = recommendations.filter {
            !completedIDs.contains($0.id) && !protectedIDs.contains($0.id) && !markedTrashIDs.contains($0.id) &&
            manualSignatures[$0.id] != inputSignature && !isConfirmed($0.id) && ($0.targetFolder == nil || ($0.requiresIndividualReview ?? false))
        }
        var screenshots: [UUID] = []
        for (index, item) in candidates.enumerated() {
            if Task.isCancelled { break }
            status = "\(item.file.name) wird zugeordnet"
            do {
                let evidence = try await ContentExtractor.extract(item.file)
                if let match = ExistingFolderPlanner.match(file: item.file, evidence: evidence, profiles: profiles),
                   let position = recommendations.firstIndex(where: { $0.id == item.id }) {
                    recommendations[position] = match
                } else if isScreenshot(item.file.name), item.file.url.deletingLastPathComponent().standardizedFileURL != root.appendingPathComponent("Screenshots", isDirectory: true).standardizedFileURL {
                    screenshots.append(item.id)
                    if let position = recommendations.firstIndex(where: { $0.id == item.id }) { recommendations[position].evidence = evidence }
                }
            } catch { notices.append("\(item.file.name): \(error.localizedDescription)") }
            progress = Double(index + 1) / Double(max(candidates.count, 1))
            persistDraft()
        }
        let screenshotFolder = availableTargets.first { ["screenshots", "bildschirmfotos", "bildschirmaufnahmen"].contains($0.lastPathComponent.lowercased()) }
        if let screenshotFolder {
            for id in screenshots {
                if let index = recommendations.firstIndex(where: { $0.id == id }) {
                    recommendations[index].targetFolder = screenshotFolder
                    recommendations[index].confidence = 0.95; recommendations[index].margin = 0.95
                    recommendations[index].reason = "Allgemeiner Screenshot ohne sicheren Projektbezug."
                    recommendations[index].evidence.sufficient = true
                    recommendations[index].needsQuestion = false; recommendations[index].requiresIndividualReview = false
                }
            }
        } else if screenshots.count >= 3 {
            folderProposals.removeAll { $0.name == "Screenshots" && $0.fileIDs != nil }
            folderProposals.append(FolderProposal(name: "Screenshots", reason: "\(screenshots.count) allgemeine Screenshots haben keinen passenden vorhandenen Ordner.", fileIDs: screenshots))
        }
        analyzedSignature = inputSignature
        status = "\(batchCandidates.count) Dateien mit Ziel · \(unassignedCount) noch offen"
        progress = 1; persistDraft()
    }
    private func folderProfiles(for targets: [URL]) async -> [FolderProfile] {
        let profiles = await FolderKnowledge.inspect(folders: targets)
        return profiles.map { profile in
            // Only intentional choices or a supplied reviewed plan teach a folder's purpose.
            let summaries = recommendations.filter {
                $0.targetFolder?.standardizedFileURL == profile.url && !($0.requiresIndividualReview ?? false) &&
                ($0.evidence.origin == "Geprüfter Sortierplan" || (isConfirmed($0.id) && ["Lokale Beschreibung", "Lokale Bildanalyse", "Bildanalyse mit OpenRouter"].contains($0.evidence.origin)))
            }.map { String($0.evidence.summary.prefix(300)) }.filter { !$0.isEmpty }
            let purpose = Array(Set(summaries)).sorted().prefix(4).joined(separator: " · ")
            return FolderProfile(url: profile.url, fileNames: profile.fileNames, purpose: purpose)
        }
    }
    private func isScreenshot(_ name: String) -> Bool {
        let text = name.lowercased()
        return ["bildschirmfoto", "screenshot", "xnapper-"].contains { text.hasPrefix($0) } || text.hasPrefix("simulator screenshot")
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
        await refreshPreservingAssignments()
        let runInputSignature = inputSignature
        let cachedEvidence = Dictionary(uniqueKeysWithValues: recommendations.filter { !($0.requiresIndividualReview ?? false) }.map { ($0.id, $0.evidence) })
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
            let profiles = await folderProfiles(for: targets)
            let missing = Set(recommendations.filter { $0.targetFolder == nil || ($0.requiresIndividualReview ?? false) }.map(\.id))
            let candidates = files.filter { missing.contains($0.id) && !completedIDs.contains($0.id) && !protectedIDs.contains($0.id) && !markedTrashIDs.contains($0.id) && manualSignatures[$0.id] != runInputSignature }
            for (index, file) in candidates.enumerated() {
                try Task.checkCancellation()
                status = "\(file.name) wird geprüft"
                do {
                    let result = try await service.analyze(file: file, folders: targets, context: context, allowCloud: allowCloud, allowOriginals: allowOriginals, folderProfiles: profiles, cachedEvidence: cachedEvidence[file.id].flatMap { $0.summary.isEmpty && $0.extractedText.isEmpty ? nil : $0 }, suggestNames: configuration.suggestNames ?? false)
                    if let position = recommendations.firstIndex(where: { $0.id == file.id }) { recommendations[position] = result }
                } catch {
                    if error is CancellationError { throw error }
                    if let position = recommendations.firstIndex(where: { $0.id == file.id }) { recommendations[position].reason = error.localizedDescription }
                    if error.localizedDescription.localizedCaseInsensitiveContains("budget") || error.localizedDescription.localizedCaseInsensitiveContains("kostenlimit") { notices.append(error.localizedDescription); break }
                    if error.localizedDescription.contains("HTTP 401") || error.localizedDescription.contains("HTTP 402") || error.localizedDescription.contains("HTTP 403") { throw error }
                }
                let usage = await service.usage(); spentUSD = carriedSpend + usage.spentUSD; reservedUSD = carriedReserve + usage.reservedUSD
                progress = Double(index + 1) / Double(max(candidates.count, 1))
                persistDraft()
            }
            try Task.checkCancellation()
            let unmatched = recommendations.filter { $0.targetFolder == nil && !protectedIDs.contains($0.id) && !completedIDs.contains($0.id) && !markedTrashIDs.contains($0.id) && manualSignatures[$0.id] != runInputSignature }
            if !unmatched.isEmpty {
                status = "Passende Ordner werden gesucht"
                do { folderProposals = try await service.proposeFolders(files: unmatched, existingFolders: targets, context: context, allowCloud: allowCloud) }
                catch { notices.append(error.localizedDescription) }
            }
            let usage = await service.usage(); spentUSD = carriedSpend + usage.spentUSD; reservedUSD = carriedReserve + usage.reservedUSD
            try Task.checkCancellation()
            analyzedSignature = runInputSignature
            status = "\(eligible.count) bereit, \(pendingQuestions.count) offen"; progress = 1
            persistDraft()
        } catch is CancellationError { status = "Analyse angehalten" }
        catch { self.error = error.localizedDescription; status = "Analyse angehalten" }
        if let aiService {
            let usage = await aiService.usage()
            spentUSD = carriedSpend + usage.spentUSD; reservedUSD = carriedReserve + usage.reservedUSD
        }
        persistDraft()
    }
    func checkStructure() async {
        guard let service = aiService, structureCheckAvailable, !busy else { return }
        busy = true; error = nil; status = "Vorhandene Struktur wird geprüft"; defer { busy = false }
        do {
            structureProposals = try await service.proposeStructure(files: recommendations, existingFolders: folders, context: context, allowCloud: allowCloud)
            let usage = await service.usage(); spentUSD = carriedSpend + usage.spentUSD; reservedUSD = carriedReserve + usage.reservedUSD
            if structureProposals.isEmpty { status = "Vorhandene Struktur bleibt bestehen" }
            else { showStructureReview = true; status = "Strukturvorschlag bereit" }
            persistDraft()
        } catch { self.error = error.localizedDescription }
    }
    func acceptStructure() {
        guard let root = targetRoot else { return }
        acceptedFolders = structureProposals.map { root.appendingPathComponent($0.name, isDirectory: true) }
        restructuring = true; showStructureReview = false
        persistDraft()
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
        if let ids = proposal.fileIDs {
            for index in recommendations.indices where ids.contains(recommendations[index].id) && !protectedIDs.contains(recommendations[index].id) && !markedTrashIDs.contains(recommendations[index].id) && !completedIDs.contains(recommendations[index].id) && !isConfirmed(recommendations[index].id) {
                recommendations[index].targetFolder = url
                recommendations[index].confidence = 0.95; recommendations[index].margin = 0.95
                recommendations[index].evidence.sufficient = true
                recommendations[index].reason = "Passender gemeinsamer Ordner für diese Screenshots."
                recommendations[index].needsQuestion = false; recommendations[index].requiresIndividualReview = false
            }
            analyzedSignature = inputSignature
            status = "Zuordnungen bereit. Öffne die Sortierübersicht."
        } else { status = "Ordner ergänzt. Zuordnungen erneut prüfen." }
        persistDraft()
    }
    func setTarget(id: UUID, target: URL?, importance: Importance? = nil) {
        guard let index = recommendations.firstIndex(where: { $0.id == id }) else { return }
        recommendations[index].targetFolder = target; recommendations[index].isApproved = target != nil; recommendations[index].needsQuestion = target == nil
        recommendations[index].requiresIndividualReview = false
        markedTrashIDs.remove(id)
        manualSignatures[id] = inputSignature
        if let importance { recommendations[index].importance = importance }
        refreshManualStatus()
        persistDraft()
    }
    func isConfirmed(_ id: UUID) -> Bool {
        guard let recommendation = recommendations.first(where: { $0.id == id }) else { return false }
        return recommendation.isApproved && manualSignatures[id] == inputSignature
    }
    func confirmTarget(id: UUID) {
        guard !busy, !paused, let recommendation = recommendations.first(where: { $0.id == id }), recommendation.targetFolder != nil else { return }
        setTarget(id: id, target: recommendation.targetFolder, importance: recommendation.importance)
    }
    private func refreshManualStatus() {
        guard !analyzing, !sorting else { return }
        status = "\(eligible.count) bereit, \(pendingQuestions.count) offen"
    }
    func keep(id: UUID) {
        guard !busy, !paused else { return }
        protectedIDs.insert(id)
        markedTrashIDs.remove(id)
        selectedIDs.remove(id)
        refreshManualStatus()
        persistDraft()
        refreshStackDeck()
        focusStackCurrent()
    }
    func sortEligible(confirmedStructure: Bool = false, onlyIDs: Set<UUID>? = nil) {
        guard let source, let targetRoot, !busy, !paused else { return }
        if restructuring && !confirmedStructure { showStructureReview = true; return }
        var operations: [PlannedOperation] = []
        let sorted = eligible.filter { onlyIDs?.contains($0.id) ?? true }
        var destinations: Set<String> = []
        for recommendation in sorted {
            guard let folder = recommendation.targetFolder else { continue }
            guard FileManager.default.fileExists(atPath: folder.path) || acceptedFolders.contains(folder) else {
                notices.append("\(recommendation.file.name): Zielordner ist nicht mehr vorhanden. Bitte neu zuordnen.")
                continue
            }
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
        if event.state == .completed, let snapshot = event.operation.snapshot {
            completedIDs.insert(snapshot.id)
            selectedIDs.remove(snapshot.id)
            if event.operation.kind == .trash { markedTrashIDs.remove(snapshot.id) }
        }
        if event.state == .completed, let snapshot = event.operation.snapshot { duplicateGroups = duplicateGroups.map { $0.filter { $0.id != snapshot.id } }.filter { $0.count > 1 } }
        if event.state == .failed || event.state == .conflict { notices.append(event.message) }
        if event.state == .completed {
            status = "\(event.operation.source.lastPathComponent) sortiert"
            pruneSelection()
            refreshStackDeck()
            focusStackCurrent()
        }
        persistDraft()
    }
    func renameSelected() async {
        guard !busy, !paused, let recommendation = selected, let name = recommendation.suggestedName, let source else { return }
        let destination = recommendation.file.url.deletingLastPathComponent().appendingPathComponent(name)
        let operation = PlannedOperation(kind: .rename, source: recommendation.file.url, destination: destination, snapshot: recommendation.file, requiresConfirmation: true, reason: "Dateiname bestätigt")
        await execute(plan: .init(sourceRoot: source, destinationRoot: source, operations: [operation]), sensitive: true)
        await refreshPreservingAssignments()
    }
    func trash(_ selectedFiles: [FileSnapshot]) async {
        guard !busy, !paused, let source, let targetRoot else { return }
        let requestedIDs = Set(selectedFiles.map(\.id))
        guard !requestedIDs.isEmpty, selectedFiles.allSatisfy({ file in
            !completedIDs.contains(file.id) && !protectedIDs.contains(file.id) && !file.isProtected && !file.isDirectory &&
                recommendations.contains { $0.id == file.id && $0.file == file }
        }) else { error = "Die Auswahl hat sich geändert. Bitte Dateien erneut auswählen."; return }
        let operations = selectedFiles.map { PlannedOperation(kind: .trash, source: $0.url, snapshot: $0, requiresConfirmation: true, reason: "Papierkorb bestätigt") }
        await execute(plan: .init(sourceRoot: source, destinationRoot: targetRoot, operations: operations), sensitive: true)
        // Keep every untouched assignment and its evidence. A full scan would invalidate them.
        let removedIDs = requestedIDs.intersection(completedIDs)
        files.removeAll { removedIDs.contains($0.id) }
        recommendations.removeAll { removedIDs.contains($0.id) }
        markedTrashIDs.subtract(removedIDs)
        manualSignatures = manualSignatures.filter { !removedIDs.contains($0.key) }
        pruneSelection()
        refreshStackDeck()
        focusStackCurrent()
        persistDraft()
    }
    func undo(_ runID: UUID) async {
        guard let operationService, !busy, !paused else { return }
        busy = true; error = nil
        do { let events = try await operationService.undo(runID: runID); await refreshHistory(); status = events.contains { $0.state == .conflict } ? "Einige Änderungen bitte im Verlauf prüfen" : "Lauf rückgängig gemacht" }
        catch { self.error = error.localizedDescription }
        busy = false; lastEvent = nil; await refreshPreservingAssignments()
    }
    func undoAction(runID: UUID, operationID: UUID) async {
        guard let operationService, !busy, !paused else { return }
        busy = true
        do { _ = try await operationService.undo(runID: runID, operationID: operationID); await refreshHistory() }
        catch { self.error = error.localizedDescription }
        busy = false; lastEvent = nil; await refreshPreservingAssignments()
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
