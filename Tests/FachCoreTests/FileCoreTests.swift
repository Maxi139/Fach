import Foundation
import Testing
import Darwin
@testable import FachCore

private struct Fixture {
    let base: URL
    let root: URL
    let database: URL
    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("FachTests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("Source", isDirectory: true)
        database = base.appendingPathComponent("journal.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func file(_ path: String, content: String = "important content") throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        return url
    }
    func cleanup() { try? FileManager.default.removeItem(at: base) }
    func move(_ source: URL, to destination: URL, kind: OperationKind = .move) throws -> OrganizationPlan {
        OrganizationPlan(sourceRoot: root, destinationRoot: root,
                         operations: [PlannedOperation(kind: kind, source: source, destination: destination, snapshot: try FileSafety.snapshot(source))])
    }
}

private enum TrashUndoCrashPhase: CaseIterable { case beforeCopy, partialCopy, completeCopy, afterRename }

@Suite("FachCoreTests") struct FileCoreTests {
    @Test func shallowScanKeepsSubfolderContentsOut() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let direct = try f.file("invoice.txt"); _ = try f.file("Work/report.txt")
        let scan = try await FileScanner().scan(root: f.root, recursive: false)
        #expect(scan.files.map(\.name) == [direct.lastPathComponent]); #expect(scan.files.first?.resourceID == (try FileSafety.snapshot(direct)).resourceID); #expect(scan.folders.count == 1)
        let recursive = try await FileScanner().scan(root: f.root, recursive: true)
        #expect(recursive.files.count == 2)
    }
    @Test func scannerSkipsSymlinksProjectsAndCloudPlaceholders() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let target = try f.file("visible.txt")
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("alias"), withDestinationURL: target)
        _ = try f.file("Project/.git/config"); _ = try f.file("Project/main.swift")
        _ = try f.file("Photos.photoslibrary/data.db"); _ = try f.file(".pending.pdf.icloud")
        let scan = try await FileScanner().scan(root: f.root, recursive: true)
        #expect(scan.files.map(\.name) == [target.lastPathComponent]); #expect(scan.warnings.count == 4)
    }
    @Test func moveAndPersistentUndo() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let source = try f.file("a.txt"), destination = f.root.appendingPathComponent("b.txt")
        let plan = try f.move(source, to: destination)
        let service = try FileOperationService(databaseURL: f.database)
        let events = try await service.execute(plan: plan)
        #expect(events.last?.state == .completed); #expect(!FileSafety.exists(source)); #expect(FileSafety.exists(destination))
        let reopened = try FileOperationService(databaseURL: f.database)
        #expect(try await reopened.history().count == 2)
        #expect(try await reopened.undo(runID: plan.id).last?.state == .undone)
        #expect(try String(contentsOf: source, encoding: .utf8) == "important content")
    }
    @Test func targetCollisionNeverOverwrites() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let source = try f.file("a.txt"), target = try f.file("b.txt", content: "keep me")
        let service = try FileOperationService(databaseURL: f.database)
        #expect(try await service.execute(plan: f.move(source, to: target)).last?.state == .failed)
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep me"); #expect(FileSafety.exists(source))
    }
    @Test func externalSourceChangeFailsBeforeMutation() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let source = try f.file("a.txt"), target = f.root.appendingPathComponent("b.txt")
        let plan = try f.move(source, to: target)
        try Data("new content".utf8).write(to: source)
        let service = try FileOperationService(databaseURL: f.database)
        #expect(try await service.execute(plan: plan).last?.state == .failed)
        #expect(FileSafety.exists(source)); #expect(!FileSafety.exists(target))
    }
    @Test func changedDestinationBlocksUndoEvenWhenSizeMatches() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let source = try f.file("a.txt", content: "aaaa"), target = f.root.appendingPathComponent("b.txt")
        let plan = try f.move(source, to: target), service = try FileOperationService(databaseURL: f.database)
        _ = try await service.execute(plan: plan)
        try Data("bbbb".utf8).write(to: target)
        #expect(try await service.undo(runID: plan.id).last?.state == .conflict)
        #expect(try String(contentsOf: target, encoding: .utf8) == "bbbb"); #expect(!FileSafety.exists(source))
    }
    @Test func undoNeverOverwritesRestoredSource() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let source = try f.file("a.txt"), target = f.root.appendingPathComponent("b.txt")
        let plan = try f.move(source, to: target), service = try FileOperationService(databaseURL: f.database)
        _ = try await service.execute(plan: plan); _ = try f.file("a.txt", content: "external")
        #expect(try await service.undo(runID: plan.id).last?.state == .conflict)
        #expect(try String(contentsOf: source, encoding: .utf8) == "external"); #expect(FileSafety.exists(target))
    }
    @Test func protectedPathsAndEscapingTargetsAreRejected() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let source = try f.file("a.txt"), project = try f.file("Project/.git/config")
        let service = try FileOperationService(databaseURL: f.database)
        await #expect(throws: (any Error).self) { try await service.execute(plan: f.move(source, to: f.base.appendingPathComponent("outside.txt"))) }
        await #expect(throws: (any Error).self) { try await service.execute(plan: f.move(project, to: f.root.appendingPathComponent("config"))) }
        #expect(FileSafety.exists(source)); #expect(FileSafety.exists(project))
    }
    @Test func renameRequiresConfirmation() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let source = try f.file("a.txt"), target = f.root.appendingPathComponent("b.txt")
        let plan = try f.move(source, to: target, kind: .rename), service = try FileOperationService(databaseURL: f.database)
        await #expect(throws: (any Error).self) { try await service.execute(plan: plan) }
        #expect(FileSafety.exists(source))
        #expect(try await service.execute(plan: plan, confirmedSensitive: true).last?.state == .completed)
    }
    @Test func folderCreationAndUndoPreserveExistingFolders() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let source = try f.file("a.txt"), folder = f.root.appendingPathComponent("Archive"), target = folder.appendingPathComponent("a.txt")
        let plan = OrganizationPlan(sourceRoot: f.root, destinationRoot: f.root, operations: [
            PlannedOperation(kind: .createDirectory, source: folder, destination: folder),
            PlannedOperation(kind: .move, source: source, destination: target, snapshot: try FileSafety.snapshot(source))])
        let service = try FileOperationService(databaseURL: f.database)
        #expect(try await service.execute(plan: plan).last?.state == .completed)
        let undone = try await service.undo(runID: plan.id)
        #expect(undone.count == 2); #expect(!FileSafety.exists(folder)); #expect(FileSafety.exists(source))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let plan2 = try f.move(source, to: target)
        _ = try await service.execute(plan: plan2); _ = try await service.undo(runID: plan2.id)
        #expect(FileSafety.exists(folder))
    }
    @Test func dependencyChainMovesInCorrectOrderAndUndoRestores() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let a = try f.file("a.txt", content: "A"), b = try f.file("b.txt", content: "B"), c = f.root.appendingPathComponent("c.txt")
        let plan = OrganizationPlan(sourceRoot: f.root, destinationRoot: f.root, operations: [
            PlannedOperation(kind: .move, source: a, destination: b, snapshot: try FileSafety.snapshot(a)),
            PlannedOperation(kind: .move, source: b, destination: c, snapshot: try FileSafety.snapshot(b))])
        let service = try FileOperationService(databaseURL: f.database)
        #expect(try await service.execute(plan: plan).filter { $0.state == .completed }.count == 2)
        #expect(try String(contentsOf: b, encoding: .utf8) == "A")
        #expect(try await service.undo(runID: plan.id).filter { $0.state == .undone }.count == 2)
        #expect(try String(contentsOf: a, encoding: .utf8) == "A"); #expect(try String(contentsOf: b, encoding: .utf8) == "B")
    }
    @Test func cyclicPlanFailsBeforeMovingAnything() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let a = try f.file("a.txt"), b = try f.file("b.txt")
        let plan = OrganizationPlan(sourceRoot: f.root, destinationRoot: f.root, operations: [
            PlannedOperation(kind: .move, source: a, destination: b, snapshot: try FileSafety.snapshot(a)),
            PlannedOperation(kind: .move, source: b, destination: a, snapshot: try FileSafety.snapshot(b))])
        let service = try FileOperationService(databaseURL: f.database)
        await #expect(throws: (any Error).self) { try await service.execute(plan: plan) }
        #expect(FileSafety.exists(a)); #expect(FileSafety.exists(b)); #expect(try await service.history().isEmpty)
    }
    @Test func pauseStopsBeforeNextMutationAndResumeSkipsCompleted() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let a = try f.file("a.txt"), b = try f.file("b.txt"), x = f.root.appendingPathComponent("x.txt"), y = f.root.appendingPathComponent("y.txt")
        let plan = OrganizationPlan(sourceRoot: f.root, destinationRoot: f.root, operations: [
            PlannedOperation(kind: .move, source: a, destination: x, snapshot: try FileSafety.snapshot(a)),
            PlannedOperation(kind: .move, source: b, destination: y, snapshot: try FileSafety.snapshot(b))])
        let service = try FileOperationService(databaseURL: f.database)
        _ = try await service.execute(plan: plan) { event in if event.state == .completed { await service.pause() } }
        #expect(FileSafety.exists(x)); #expect(FileSafety.exists(b)); #expect(!FileSafety.exists(y))
        await service.resume()
        #expect(try await service.execute(plan: plan).filter { $0.state == .completed }.count == 1)
        #expect(FileSafety.exists(y))
    }
    @Test func recoveryReconcilesMoveAfterCrashAndSupportsUndo() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let a = try f.file("a.txt"), b = f.root.appendingPathComponent("b.txt"), plan = try f.move(a, to: b)
        let record = JournalRecord(runID: plan.id, operation: plan.operations[0], sourceRoot: f.root, destinationRoot: f.root, state: .prepared, before: try Fingerprint(a))
        try OperationJournal(url: f.database).save(record)
        #expect(renamex_np(a.path, b.path, UInt32(RENAME_EXCL)) == 0)
        let service = try FileOperationService(databaseURL: f.database)
        #expect(try await service.recover().last?.state == .completed)
        #expect(try await service.undo(runID: plan.id).last?.state == .undone); #expect(FileSafety.exists(a))
    }
    @Test func recoveryPreservesAmbiguousCopies() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let a = try f.file("a.txt"), b = f.root.appendingPathComponent("b.txt"), plan = try f.move(a, to: b)
        let record = JournalRecord(runID: plan.id, operation: plan.operations[0], sourceRoot: f.root, destinationRoot: f.root, state: .prepared, before: try Fingerprint(a))
        try OperationJournal(url: f.database).save(record); try FileManager.default.copyItem(at: a, to: b)
        let service = try FileOperationService(databaseURL: f.database)
        #expect(try await service.recover().last?.state == .conflict)
        #expect(FileSafety.exists(a)); #expect(FileSafety.exists(b))
    }
    @Test func symlinkDestinationCannotEscapeRoot() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let a = try f.file("a.txt"), alias = f.root.appendingPathComponent("outside")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.base)
        let service = try FileOperationService(databaseURL: f.database)
        await #expect(throws: (any Error).self) { try await service.execute(plan: f.move(a, to: alias.appendingPathComponent("stolen.txt"))) }
        #expect(FileSafety.exists(a)); #expect(!FileSafety.exists(f.base.appendingPathComponent("stolen.txt")))
    }
    @Test func externalChangeAfterPreparedIsCaught() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let a = try f.file("a.txt"), b = f.root.appendingPathComponent("b.txt"), plan = try f.move(a, to: b)
        let service = try FileOperationService(databaseURL: f.database)
        let events = try await service.execute(plan: plan) { event in
            if event.state == .prepared { try? Data("changed after preparation".utf8).write(to: a) }
        }
        #expect(events.last?.state == .conflict); #expect(FileSafety.exists(a)); #expect(!FileSafety.exists(b))
        #expect(try String(contentsOf: a, encoding: .utf8) == "changed after preparation")
    }
    @Test func recoveryBeforeMutationCanResume() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let a = try f.file("a.txt"), b = f.root.appendingPathComponent("b.txt"), plan = try f.move(a, to: b)
        let record = JournalRecord(runID: plan.id, operation: plan.operations[0], sourceRoot: f.root, destinationRoot: f.root, state: .prepared, before: try Fingerprint(a))
        try OperationJournal(url: f.database).save(record)
        let service = try FileOperationService(databaseURL: f.database)
        #expect(try await service.recover().last?.state == .pending)
        #expect(try await service.execute(plan: plan).last?.state == .completed)
    }
    @Test func recoveryRefusesChangedDestinationAfterCrash() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let a = try f.file("a.txt", content: "AAAA"), b = f.root.appendingPathComponent("b.txt"), plan = try f.move(a, to: b)
        let record = JournalRecord(runID: plan.id, operation: plan.operations[0], sourceRoot: f.root, destinationRoot: f.root, state: .prepared, before: try Fingerprint(a))
        try OperationJournal(url: f.database).save(record)
        #expect(renamex_np(a.path, b.path, UInt32(RENAME_EXCL)) == 0)
        try Data("BBBB".utf8).write(to: b)
        let service = try FileOperationService(databaseURL: f.database)
        #expect(try await service.recover().last?.state == .conflict)
        #expect(try String(contentsOf: b, encoding: .utf8) == "BBBB")
    }
    @Test func recoveryAfterInterruptedUndoKeepsRestoredFile() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let a = try f.file("a.txt"), b = f.root.appendingPathComponent("b.txt"), plan = try f.move(a, to: b)
        let before = try Fingerprint(a)
        #expect(renamex_np(a.path, b.path, UInt32(RENAME_EXCL)) == 0)
        var record = JournalRecord(runID: plan.id, operation: plan.operations[0], sourceRoot: f.root, destinationRoot: f.root, state: .completed, before: before, after: try Fingerprint(b))
        record.undoPrepared = true
        try OperationJournal(url: f.database).save(record)
        #expect(renamex_np(b.path, a.path, UInt32(RENAME_EXCL)) == 0)
        let service = try FileOperationService(databaseURL: f.database)
        #expect(try await service.recover().last?.state == .undone)
        #expect(FileSafety.exists(a)); #expect(!FileSafety.exists(b))
    }
    @Test func individualUndoOnlyRestoresChosenAction() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let a = try f.file("a.txt"), b = try f.file("b.txt"), x = f.root.appendingPathComponent("x.txt"), y = f.root.appendingPathComponent("y.txt")
        let first = PlannedOperation(kind: .move, source: a, destination: x, snapshot: try FileSafety.snapshot(a))
        let second = PlannedOperation(kind: .move, source: b, destination: y, snapshot: try FileSafety.snapshot(b))
        let plan = OrganizationPlan(sourceRoot: f.root, destinationRoot: f.root, operations: [first, second])
        let service = try FileOperationService(databaseURL: f.database)
        _ = try await service.execute(plan: plan)
        #expect(try await service.undo(runID: plan.id, operationID: first.id).count == 1)
        #expect(FileSafety.exists(a)); #expect(!FileSafety.exists(x)); #expect(!FileSafety.exists(b)); #expect(FileSafety.exists(y))
    }
    @Test func crashAfterSyntheticTrashMoveRecoversFromDurableBackup() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let source = try f.file("a.txt", content: "recover me")
        let trash = f.base.appendingPathComponent("SyntheticTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let operation = PlannedOperation(kind: .trash, source: source, snapshot: try FileSafety.snapshot(source))
        let plan = OrganizationPlan(sourceRoot: f.root, destinationRoot: f.root, operations: [operation])
        let crashing = try FileOperationService(databaseURL: f.database, trashHandler: { file in
            try FileManager.default.moveItem(at: file, to: trash.appendingPathComponent(file.lastPathComponent))
            throw FachError.message("synthetic crash after move")
        })

        let crashEvents = try await crashing.execute(plan: plan, confirmedSensitive: true)
        #expect(crashEvents.last?.state == .conflict)
        #expect(crashEvents.last?.message == "synthetic crash after move")
        #expect(!FileSafety.exists(source))
        let restarted = try FileOperationService(databaseURL: f.database)
        #expect(try await restarted.recover().last?.state == .completed)
        #expect(try await restarted.undo(runID: plan.id).last?.state == .undone)
        #expect(try String(contentsOf: source, encoding: .utf8) == "recover me")
    }
    @Test func nilTrashResultAfterRestartUsesDurableBackup() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let source = try f.file("a.txt", content: "recover me")
        let trash = f.base.appendingPathComponent("SyntheticTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let operation = PlannedOperation(kind: .trash, source: source, snapshot: try FileSafety.snapshot(source))
        let plan = OrganizationPlan(sourceRoot: f.root, destinationRoot: f.root, operations: [operation])
        let service = try FileOperationService(databaseURL: f.database, trashHandler: { file in
            try FileManager.default.moveItem(at: file, to: trash.appendingPathComponent(file.lastPathComponent))
            return nil
        })

        #expect(try await service.execute(plan: plan, confirmedSensitive: true).last?.state == .completed)
        let restarted = try FileOperationService(databaseURL: f.database)
        #expect(try await restarted.undo(runID: plan.id).last?.state == .undone)
        #expect(try String(contentsOf: source, encoding: .utf8) == "recover me")
        #expect(FileSafety.exists(trash.appendingPathComponent("a.txt")))
    }
    @Test func changedTrashBackupPreventsRestore() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let source = try f.file("a.txt", content: "recover me")
        let trash = f.base.appendingPathComponent("SyntheticTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let operation = PlannedOperation(kind: .trash, source: source, snapshot: try FileSafety.snapshot(source))
        let plan = OrganizationPlan(sourceRoot: f.root, destinationRoot: f.root, operations: [operation])
        let service = try FileOperationService(databaseURL: f.database, trashHandler: { file in
            try FileManager.default.moveItem(at: file, to: trash.appendingPathComponent(file.lastPathComponent))
            return nil
        })
        _ = try await service.execute(plan: plan, confirmedSensitive: true)
        let backup = f.base.appendingPathComponent("Recovery", isDirectory: true)
            .appendingPathComponent(plan.id.uuidString, isDirectory: true)
            .appendingPathComponent(operation.id.uuidString, isDirectory: true)
            .appendingPathComponent("original")
        try Data("tampered backup".utf8).write(to: backup)

        let restarted = try FileOperationService(databaseURL: f.database)
        #expect(try await restarted.undo(runID: plan.id).last?.state == .conflict)
        #expect(!FileSafety.exists(source))
        #expect(try String(contentsOf: backup, encoding: .utf8) == "tampered backup")
    }
    @Test func undoConflictRemainsIndividuallyRetryable() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let source = try f.file("a.txt", content: "original")
        let destination = f.root.appendingPathComponent("b.txt")
        let plan = try f.move(source, to: destination)
        let service = try FileOperationService(databaseURL: f.database)
        _ = try await service.execute(plan: plan)
        _ = try f.file("a.txt", content: "external")

        #expect(try await service.undo(runID: plan.id).last?.state == .conflict)
        #expect(try await service.undoableOperationIDs(runID: plan.id) == [plan.operations[0].id])
        try FileManager.default.removeItem(at: source)
        #expect(try await service.undo(runID: plan.id, operationID: plan.operations[0].id).last?.state == .undone)
        #expect(try String(contentsOf: source, encoding: .utf8) == "original")
    }
    @Test func recoverInterruptedBackupTrashUndoPreservesEveryCrashState() async throws {
        for phase in TrashUndoCrashPhase.allCases {
            let f = try Fixture(); defer { f.cleanup() }
            let source = try f.file("a.txt", content: "original")
            let operation = PlannedOperation(kind: .trash, source: source, snapshot: try FileSafety.snapshot(source))
            let plan = OrganizationPlan(sourceRoot: f.root, destinationRoot: f.root, operations: [operation])
            let before = try Fingerprint(source)
            let backup = f.base.appendingPathComponent("Recovery", isDirectory: true)
                .appendingPathComponent(plan.id.uuidString, isDirectory: true)
                .appendingPathComponent(operation.id.uuidString, isDirectory: true)
                .appendingPathComponent("original")
            try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: backup)
            let stage = source.deletingLastPathComponent().appendingPathComponent(".fach-backup-\(operation.id.uuidString).partial")
            var record = JournalRecord(runID: plan.id, operation: operation, sourceRoot: f.root, destinationRoot: f.root,
                                       state: .completed, before: before)
            record.backupURL = backup; record.backupFingerprint = try Fingerprint(backup)
            record.undoPrepared = true; record.undoUsedBackup = true; record.stage = stage

            switch phase {
            case .beforeCopy:
                try FileManager.default.removeItem(at: source)
            case .partialCopy:
                try FileManager.default.removeItem(at: source)
                try Data("partial".utf8).write(to: stage)
            case .completeCopy:
                try FileManager.default.removeItem(at: source)
                try FileManager.default.copyItem(at: backup, to: stage)
                record.undoFingerprint = try Fingerprint(stage)
            case .afterRename:
                record.undoFingerprint = try Fingerprint(source)
            }
            try OperationJournal(url: f.database).save(record)

            let service = try FileOperationService(databaseURL: f.database)
            #expect(try await service.recover().last?.state == .undone)
            #expect(try String(contentsOf: source, encoding: .utf8) == "original")
            if phase == .partialCopy {
                #expect(try String(contentsOf: stage, encoding: .utf8) == "partial")
            } else {
                #expect(!FileSafety.exists(stage))
            }
        }
    }
}
