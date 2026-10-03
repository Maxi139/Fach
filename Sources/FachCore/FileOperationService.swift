import Foundation
import Darwin

public actor FileOperationService {
    private let journal: OperationJournal
    private let recoveryRoot: URL
    private let trashHandler: @Sendable (URL) throws -> URL?
    private var paused = false
    private var busy = false
    public init(databaseURL: URL) throws {
        journal = try OperationJournal(url: databaseURL)
        recoveryRoot = databaseURL.deletingLastPathComponent().appendingPathComponent("Recovery", isDirectory: true)
        trashHandler = { source in
            var result: NSURL?
            try FileManager.default.trashItem(at: source, resultingItemURL: &result)
            return result as URL?
        }
    }
    // Injectable boundary exercises crashes and inaccessible Trash using only test files.
    init(databaseURL: URL, trashHandler: @escaping @Sendable (URL) throws -> URL?) throws {
        journal = try OperationJournal(url: databaseURL)
        recoveryRoot = databaseURL.deletingLastPathComponent().appendingPathComponent("Recovery", isDirectory: true)
        self.trashHandler = trashHandler
    }
    public func pause() { paused = true }
    public func resume() { paused = false }
    public func history() throws -> [RunEvent] { try journal.events() }
    public func undoableOperationIDs(runID: UUID) throws -> [UUID] {
        try journal.records().filter { $0.runID == runID && $0.state == .completed }.map { $0.operation.id }
    }

    public func execute(plan: OrganizationPlan, confirmedSensitive: Bool = false,
                        onEvent: @Sendable (RunEvent) async -> Void = { _ in }) async throws -> [RunEvent] {
        guard !busy else { throw FachError.message("Ein Lauf ist noch aktiv.") }
        busy = true
        defer { busy = false }
        let operations = try ordered(plan.operations)
        let previous = try journal.records().filter { $0.runID == plan.id }
        // Validate all boundaries and confirmations before changing the first file.
        for operation in operations {
            if previous.contains(where: { $0.operation.id == operation.id && $0.state == .completed }) { continue }
            if (operation.requiresConfirmation || operation.kind == .rename || operation.kind == .trash) && !confirmedSensitive {
                throw FachError.message("Umbenennen oder Papierkorb bitte zuerst bestätigen.")
            }
            if operation.kind == .createDirectory {
                guard let target = operation.destination else { throw FachError.message("Zielordner fehlt.") }
                guard !FileSafety.protectedDirectory(target), !target.lastPathComponent.hasPrefix(".") else { throw FachError.message("Bitte einen normalen Ordnernamen wählen.") }
                try validateFuturePath(target, root: plan.destinationRoot)
            } else {
                try FileSafety.validatePath(operation.source, within: plan.sourceRoot)
                if let target = operation.destination { try validateFuturePath(target, root: plan.destinationRoot) }
            }
        }
        var events: [RunEvent] = []
        for operation in operations {
            if paused || Task.isCancelled { break }
            if let existing = previous.first(where: { $0.operation.id == operation.id }) {
                guard existing.operation.source == operation.source, (operation.kind == .trash || existing.operation.destination == operation.destination),
                      existing.operation.kind == operation.kind else { throw FachError.message("Gespeicherter Lauf stimmt nicht mit dem Vorschlag überein.") }
                if existing.state == .completed { continue }
                if existing.state == .prepared || existing.undoPrepared { throw FachError.message("Unterbrochenen Lauf zuerst prüfen.") }
                if existing.state == .undone { throw FachError.message("Für diese Dateien bitte einen neuen Lauf starten.") }
            }
            var record = JournalRecord(runID: plan.id, operation: operation, sourceRoot: plan.sourceRoot,
                                       destinationRoot: plan.destinationRoot, state: .pending)
            var intentPrepared = false
            do {
                if operation.kind != .createDirectory {
                    record.before = try Fingerprint(operation.source)
                    try validateSnapshot(operation.snapshot, at: operation.source)
                }
                if let destination = operation.destination, FileSafety.exists(destination) {
                    if operation.kind == .createDirectory, FileSafety.isDirectory(try FileSafety.stat(destination)) {
                        // Existing destination folders belong to the user, not to this run.
                        continue
                    }
                    throw FachError.message("„\(destination.lastPathComponent)“ existiert bereits. Belegte Datei prüfen und ursprünglichen Platz freigeben. Danach erneut versuchen.")
                }
                record.state = .prepared
                let prepared = RunEvent(runID: plan.id, operation: operation, state: .prepared, message: "Wird vorbereitet")
                try journal.save(record, event: prepared)
                intentPrepared = true
                events.append(prepared); await onEvent(prepared)
                if paused || Task.isCancelled {
                    record.state = .pending
                    try journal.save(record)
                    break
                }
                try perform(&record)
                record.state = .completed
                let event = RunEvent(runID: plan.id, operation: record.operation, state: .completed, message: operation.kind == .createDirectory ? "Ordner erstellt" : "Erledigt")
                try journal.save(record, event: event)
                intentPrepared = false
                events.append(event); await onEvent(event)
            } catch {
                // If mutation might have occurred, preserve the prepared intent. Recovery
                // compares both locations rather than trusting an exception as a rollback.
                if intentPrepared { record.state = .prepared }
                let state: OperationState = intentPrepared ? .conflict : .failed
                let event = RunEvent(runID: plan.id, operation: record.operation, state: state, message: error.localizedDescription)
                if !intentPrepared { record.state = state }
                try journal.save(record, event: event)
                events.append(event); await onEvent(event)
            }
        }
        return events
    }

    private func validateFuturePath(_ url: URL, root: URL) throws {
        let standardized = url.standardizedFileURL, base = root.standardizedFileURL
        guard standardized.path.hasPrefix(base.path + "/") else { throw FachError.message("Ziel liegt außerhalb des gewählten Zielordners.") }
        var existing = standardized
        while !FileSafety.exists(existing), existing.path != base.path { existing.deleteLastPathComponent() }
        try FileSafety.validatePath(existing, within: base)
    }
    private func validateSnapshot(_ snapshot: FileSnapshot?, at url: URL) throws {
        guard let snapshot, snapshot.url.standardizedFileURL == url.standardizedFileURL, !snapshot.isProtected else {
            throw FachError.message("Datei bitte erneut analysieren.")
        }
        let current = try FileSafety.snapshot(url)
        guard current.size == snapshot.size, current.modifiedAt == snapshot.modifiedAt,
              snapshot.changedAt == nil || current.changedAt == snapshot.changedAt,
              snapshot.resourceID == nil || current.resourceID == snapshot.resourceID else {
            throw FachError.message("„\(url.lastPathComponent)“ wurde inzwischen geändert. Bitte erneut analysieren.")
        }
    }
    private func ordered(_ operations: [PlannedOperation]) throws -> [PlannedOperation] {
        guard Set(operations.map(\.id)).count == operations.count else { throw FachError.message("Vorschlag enthält doppelte Aktionen.") }
        let moves = operations.filter { $0.kind != .createDirectory }
        guard Set(moves.map { $0.source.standardizedFileURL.path }).count == moves.count else { throw FachError.message("Eine Datei hat mehrere Ziele.") }
        let destinations = moves.compactMap(\.destination).map { $0.standardizedFileURL.path }
        guard Set(destinations).count == destinations.count else { throw FachError.message("Mehrere Dateien haben dasselbe Ziel.") }
        var result = operations.filter { $0.kind == .createDirectory }.sorted { ($0.destination?.pathComponents.count ?? 0) < ($1.destination?.pathComponents.count ?? 0) }
        var remaining = moves
        while !remaining.isEmpty {
            guard let index = remaining.firstIndex(where: { candidate in
                guard let destination = candidate.destination else { return true }
                return !remaining.contains { $0.source.standardizedFileURL == destination.standardizedFileURL }
            }) else { throw FachError.message("Zyklische Umbenennungen bitte einzeln durchführen.") }
            result.append(remaining.remove(at: index))
        }
        return result
    }
    private func perform(_ record: inout JournalRecord) throws {
        let operation = record.operation
        switch operation.kind {
        case .createDirectory:
            guard let destination = operation.destination else { throw FachError.message("Zielordner fehlt.") }
            try FileSafety.validatePath(destination.deletingLastPathComponent(), within: record.destinationRoot)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            record.createdIdentity = try FileSafety.snapshot(destination).resourceID
        case .move, .rename:
            guard let destination = operation.destination, let before = record.before else { throw FachError.message("Ziel fehlt.") }
            try FileSafety.validatePath(operation.source, within: record.sourceRoot)
            try FileSafety.validatePath(destination, within: record.destinationRoot, allowMissingLeaf: true)
            guard try Fingerprint(operation.source) == before else { throw FachError.message("Quelldatei wurde geändert.") }
            try moveExclusive(operation.source, to: destination, record: &record)
            record.after = try Fingerprint(destination)
            guard before.sameContent(as: record.after!) else { throw FachError.message("Dateiinhalt stimmt nicht überein. Bitte Verlauf prüfen.") }
        case .trash:
            try FileSafety.validatePath(operation.source, within: record.sourceRoot)
            guard let before = record.before, try Fingerprint(operation.source) == before else { throw FachError.message("Quelldatei wurde geändert.") }
            try prepareTrashBackup(&record)
            guard try Fingerprint(operation.source) == before else { throw FachError.message("Quelldatei wurde geändert.") }
            let destination = try trashHandler(operation.source)
            guard !FileSafety.exists(operation.source) else { throw FachError.message("Datei wurde nicht in den Papierkorb verschoben.") }
            record.operation.destination = destination
            if let destination {
                record.after = try? Fingerprint(destination)
                record.trashBookmark = try? destination.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            }
        }
    }
    private func prepareTrashBackup(_ record: inout JournalRecord) throws {
        guard let before = record.before else { throw FachError.message("Dateiprüfung fehlt.") }
        try FileSafety.validatePath(recoveryRoot, within: recoveryRoot.deletingLastPathComponent(), allowMissingLeaf: true)
        try FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
        try FileSafety.validatePath(recoveryRoot, within: recoveryRoot)
        let directory = recoveryRoot.appendingPathComponent(record.runID.uuidString, isDirectory: true)
            .appendingPathComponent(record.operation.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileSafety.validatePath(directory, within: recoveryRoot)
        let backup = directory.appendingPathComponent("original")
        record.backupURL = backup
        try journal.save(record)
        if !FileSafety.exists(backup) { try FileManager.default.copyItem(at: record.operation.source, to: backup) }
        let fingerprint = try Fingerprint(backup)
        guard before.sameContent(as: fingerprint), try Fingerprint(record.operation.source) == before else {
            throw FachError.message("Wiederherstellungskopie konnte nicht geprüft werden. Datei bleibt erhalten.")
        }
        try synchronizeFile(backup)
        try synchronizeDirectory(directory)
        try synchronizeDirectory(directory.deletingLastPathComponent())
        try synchronizeDirectory(recoveryRoot)
        record.backupFingerprint = fingerprint
        // FULL-sync SQLite intent must include the verified durable backup before Trash.
        try journal.save(record)
    }
    private func synchronizeFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw FachError.message("Wiederherstellungskopie konnte nicht gesichert werden.") }
        defer { close(descriptor) }
        guard fcntl(descriptor, F_FULLFSYNC) == 0 || fsync(descriptor) == 0 else {
            throw FachError.message("Wiederherstellungskopie konnte nicht gesichert werden.")
        }
    }
    private func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw FachError.message("Wiederherstellungskopie konnte nicht gesichert werden.") }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw FachError.message("Wiederherstellungskopie konnte nicht gesichert werden.") }
    }
    private func verifiedBackup(_ record: JournalRecord) throws -> (URL, Fingerprint) {
        let expected = recoveryRoot.appendingPathComponent(record.runID.uuidString, isDirectory: true)
            .appendingPathComponent(record.operation.id.uuidString, isDirectory: true).appendingPathComponent("original")
        guard let backup = record.backupURL, backup.standardizedFileURL == expected.standardizedFileURL,
              let fingerprint = record.backupFingerprint, let before = record.before else {
            throw FachError.message("Wiederherstellungskopie fehlt. Datei bitte im Papierkorb prüfen.")
        }
        try FileSafety.validatePath(backup, within: recoveryRoot)
        guard try Fingerprint(backup) == fingerprint, before.sameContent(as: fingerprint) else {
            throw FachError.message("Wiederherstellungskopie wurde geändert. Sie bleibt unverändert.")
        }
        return (backup, fingerprint)
    }
    private func moveExclusive(_ source: URL, to destination: URL, record: inout JournalRecord, expected: Fingerprint? = nil) throws {
        if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 {
            try synchronizeFile(destination)
            try synchronizeDirectory(destination.deletingLastPathComponent())
            if source.deletingLastPathComponent() != destination.deletingLastPathComponent() { try synchronizeDirectory(source.deletingLastPathComponent()) }
            return
        }
        let failure = errno
        guard failure == EXDEV else { throw FachError.message(failure == EEXIST ? "Zieldatei existiert bereits." : "Datei konnte nicht verschoben werden. Zugriffsrechte und Zielordner prüfen.") }
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".fach-\(record.operation.id.uuidString).partial")
        record.stage = stage
        try journal.save(record)
        try FileManager.default.copyItem(at: source, to: stage)
        guard let before = expected ?? record.before, before.sameContent(as: try Fingerprint(stage)), try Fingerprint(source) == before else {
            throw FachError.message("Kopie konnte nicht geprüft werden. Quelle bleibt erhalten.")
        }
        try synchronizeFile(stage)
        try synchronizeDirectory(stage.deletingLastPathComponent())
        guard renamex_np(stage.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw FachError.message("Ziel ist nicht mehr frei. Quelle bleibt erhalten.") }
        try synchronizeDirectory(destination.deletingLastPathComponent())
        let destinationFingerprint = try Fingerprint(destination)
        if record.undoPrepared { record.undoFingerprint = destinationFingerprint }
        else { record.after = destinationFingerprint }
        try journal.save(record)
        guard try Fingerprint(source) == before else { throw FachError.message("Quelldatei wurde geändert. Beide Dateien bleiben erhalten.") }
        try FileManager.default.removeItem(at: source)
        try synchronizeDirectory(source.deletingLastPathComponent())
    }

    public func recover() async throws -> [RunEvent] {
        guard !busy else { throw FachError.message("Ein Lauf ist noch aktiv.") }
        busy = true; defer { busy = false }
        var events: [RunEvent] = []
        for var record in try journal.records() where record.state == .prepared || record.undoPrepared {
            let event: RunEvent
            do {
                if record.undoPrepared {
                    if record.operation.kind == .createDirectory {
                        guard let destination = record.operation.destination, !FileSafety.exists(destination) else { throw FachError.message("Rückgängig unterbrochen. Ordner bitte prüfen.") }
                        try FileSafety.validatePath(destination.deletingLastPathComponent(), within: record.destinationRoot)
                    } else if record.operation.kind == .trash && record.undoUsedBackup == true && !FileSafety.exists(record.operation.source) {
                        _ = try undoTrash(&record)
                    } else {
                        try FileSafety.validatePath(record.operation.source, within: record.sourceRoot)
                        let trashLeftUntouched = record.operation.kind == .trash && record.undoUsedBackup == true
                        guard (trashLeftUntouched || record.operation.destination.map({ !FileSafety.exists($0) }) == true), let before = record.before,
                              before.sameContent(as: try Fingerprint(record.operation.source)),
                              try Fingerprint(record.operation.source) == (record.undoFingerprint ?? record.after) else { throw FachError.message("Rückgängig unterbrochen. Dateien bitte prüfen.") }
                    }
                    record.state = .undone; record.undoPrepared = false
                } else if record.operation.kind == .trash {
                    if FileSafety.exists(record.operation.source) {
                        try FileSafety.validatePath(record.operation.source, within: record.sourceRoot)
                        guard let before = record.before, try Fingerprint(record.operation.source) == before else { throw FachError.message("Quelldatei wurde geändert. Sie bleibt unverändert.") }
                        record.state = .pending
                    } else {
                        _ = try verifiedBackup(record)
                        record.state = .completed
                    }
                } else if record.operation.kind != .createDirectory,
                          let destination = record.operation.destination, !FileSafety.exists(record.operation.source),
                          let before = record.before {
                    try FileSafety.validatePath(destination, within: record.operation.kind == .trash ? destination.deletingLastPathComponent() : record.destinationRoot)
                    let actual = try Fingerprint(destination)
                    guard before.sameContent(as: actual), actual == (record.after ?? before) else { throw FachError.message("Zieldatei stimmt nicht mit der Quelle überein.") }
                    record.after = actual; record.state = .completed
                } else if record.operation.kind != .createDirectory, let before = record.before,
                          record.operation.destination.map({ !FileSafety.exists($0) }) ?? false,
                          record.stage.map({ !FileSafety.exists($0) }) ?? true {
                    try FileSafety.validatePath(record.operation.source, within: record.sourceRoot)
                    guard try Fingerprint(record.operation.source) == before else { throw FachError.message("Quelldatei wurde geändert.") }
                    record.state = .pending
                } else { throw FachError.message("Unterbrochene Aktion bitte prüfen. Dateien bleiben unverändert.") }
                event = RunEvent(runID: record.runID, operation: record.operation, state: record.state, message: "Unterbrochenen Lauf geprüft")
            } catch {
                // An undo conflict must remain retryable. The event describes the
                // conflict; authoritative eligibility comes from the journal record.
                if record.undoPrepared { record.state = .completed }
                else { record.state = .conflict }
                event = RunEvent(runID: record.runID, operation: record.operation, state: .conflict, message: error.localizedDescription)
            }
            try journal.save(record, event: event); events.append(event)
        }
        return events
    }

    public func undo(runID: UUID, operationID: UUID? = nil) async throws -> [RunEvent] {
        guard !busy else { throw FachError.message("Ein Lauf ist noch aktiv.") }
        busy = true; defer { busy = false }
        var events: [RunEvent] = []
        for var record in try journal.records().filter({ $0.runID == runID && $0.state == .completed && (operationID == nil || $0.operation.id == operationID) }).reversed() {
            do {
                var restoredBackup = false
                if record.operation.kind == .trash {
                    restoredBackup = try undoTrash(&record)
                } else if record.operation.kind == .createDirectory {
                    guard let destination = record.operation.destination else { throw FachError.message("Gespeichertes Ziel fehlt.") }
                    try FileSafety.validatePath(destination, within: record.destinationRoot)
                    guard (try FileSafety.snapshot(destination)).resourceID == record.createdIdentity,
                          try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty else {
                        throw FachError.message("Ordner enthält Dateien oder wurde ersetzt. Er bleibt erhalten.")
                    }
                    record.undoPrepared = true; try journal.save(record)
                    guard rmdir(destination.path) == 0 else { throw FachError.message("Ordner konnte nicht entfernt werden.") }
                } else {
                    guard let destination = record.operation.destination else { throw FachError.message("Gespeichertes Ziel fehlt.") }
                    try FileSafety.validatePath(destination, within: record.destinationRoot)
                    try FileSafety.validatePath(record.operation.source, within: record.sourceRoot, allowMissingLeaf: true)
                    guard !FileSafety.exists(record.operation.source), let after = record.after,
                          try Fingerprint(destination) == after else { throw FachError.message("Datei wurde geändert oder ursprünglicher Platz ist belegt. Bitte prüfen.") }
                    record.undoPrepared = true; try journal.save(record)
                    // Cross-volume undo uses the same verified copy flow with its source
                    // fingerprint, while preserving the original record for recovery.
                    try moveExclusive(destination, to: record.operation.source, record: &record, expected: after)
                }
                record.state = .undone; record.undoPrepared = false
                let event = RunEvent(runID: runID, operation: record.operation, state: .undone,
                                     message: restoredBackup ? "Aus Wiederherstellungskopie zurückgelegt. Ein Eintrag im Papierkorb kann weiterhin vorhanden sein." : "Rückgängig gemacht")
                try journal.save(record, event: event); events.append(event)
                if record.operation.kind == .trash, let (backup, _) = try? verifiedBackup(record) { try? FileManager.default.removeItem(at: backup) }
            } catch {
                // Keep completed records retryable on a conflict. Prepared undo is retained
                // only when the source/destination state indicates an interrupted mutation.
                if record.state == .undone { record.state = .completed; record.undoPrepared = true }
                if record.operation.kind != .trash && FileSafety.exists(record.operation.destination ?? record.operation.source) { record.undoPrepared = false }
                if record.operation.kind == .trash && !FileSafety.exists(record.operation.source) { record.undoPrepared = false }
                let event = RunEvent(runID: runID, operation: record.operation, state: .conflict, message: error.localizedDescription)
                try journal.save(record, event: event); events.append(event)
            }
        }
        return events
    }

    // Returns true when restoration used the journal copy. Never removes an
    // inaccessible or changed Trash entry to conceal that fallback.
    private func undoTrash(_ record: inout JournalRecord) throws -> Bool {
        try FileSafety.validatePath(record.operation.source, within: record.sourceRoot, allowMissingLeaf: true)
        guard !FileSafety.exists(record.operation.source) else { throw FachError.message("Ursprünglicher Platz ist belegt. Belegte Datei prüfen und ursprünglichen Platz freigeben. Danach erneut versuchen.") }
        var destination = record.operation.destination
        if let bookmark = record.trashBookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale), !stale { destination = resolved }
        }
        if let destination, let after = record.after {
            let accessed = destination.startAccessingSecurityScopedResource()
            defer { if accessed { destination.stopAccessingSecurityScopedResource() } }
            if (try? FileSafety.validatePath(destination, within: destination.deletingLastPathComponent())) != nil,
               (try? Fingerprint(destination)) == after {
                record.undoPrepared = true; record.undoUsedBackup = false
                try journal.save(record)
                do {
                    try moveExclusive(destination, to: record.operation.source, record: &record, expected: after)
                    return false
                } catch {
                    // A partial cross-volume restore needs recovery, not a second copy.
                    if FileSafety.exists(record.operation.source) { throw error }
                }
            }
        }
        let (backup, fingerprint) = try verifiedBackup(record)
        let parent = record.operation.source.deletingLastPathComponent()
        let prefix = ".fach-backup-\(record.operation.id.uuidString)"
        var stage = parent.appendingPathComponent(prefix + ".partial")
        if record.undoUsedBackup == true, let recorded = record.stage,
           recorded.deletingLastPathComponent().standardizedFileURL.path == parent.standardizedFileURL.path,
           recorded.lastPathComponent.hasPrefix(prefix), recorded.lastPathComponent.hasSuffix(".partial") { stage = recorded }
        try FileSafety.validatePath(stage, within: record.sourceRoot, allowMissingLeaf: true)
        if FileSafety.exists(stage), (try? Fingerprint(stage)).map({ fingerprint.sameContent(as: $0) }) != true {
            // Preserve a partial or changed copy. A fresh exclusive stage keeps
            // a crash during copying from permanently blocking restoration.
            stage = parent.appendingPathComponent(prefix + "-" + UUID().uuidString + ".partial")
        }
        record.undoPrepared = true; record.undoUsedBackup = true; record.stage = stage
        try journal.save(record)
        if !FileSafety.exists(stage) { try FileManager.default.copyItem(at: backup, to: stage) }
        let staged = try Fingerprint(stage)
        guard fingerprint.sameContent(as: staged), try Fingerprint(backup) == fingerprint else { throw FachError.message("Wiederherstellungskopie konnte nicht geprüft werden.") }
        try synchronizeFile(stage)
        try synchronizeDirectory(stage.deletingLastPathComponent())
        record.undoFingerprint = staged
        try journal.save(record)
        try FileSafety.validatePath(record.operation.source, within: record.sourceRoot, allowMissingLeaf: true)
        guard renamex_np(stage.path, record.operation.source.path, UInt32(RENAME_EXCL)) == 0 else {
            throw FachError.message("Ursprünglicher Platz ist nicht mehr frei oder nicht zugänglich.")
        }
        try synchronizeDirectory(record.operation.source.deletingLastPathComponent())
        return true
    }
}
