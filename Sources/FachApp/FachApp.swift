import SwiftUI
import FachCore

@main
struct FachApp: App {
    @State private var model = AppModel()
    var body: some Scene {
        WindowGroup("Fach") {
            WorkspaceView(model: model)
                .frame(minWidth: 900, minHeight: 620)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Ordner auswählen …") { model.selectFolder() }.keyboardShortcut("o").disabled(model.busy || model.paused)
                Button("Beispiel ausprobieren") { Task { await model.createDemo() } }.disabled(model.busy || model.paused)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Letzten Lauf rückgängig machen") { if let id = model.lastRunID ?? model.runIDs.first { Task { await model.undo(id) } } }
                    .keyboardShortcut("z").disabled(model.busy || model.paused || model.runIDs.isEmpty)
            }
            CommandMenu("Aufräumen") {
                Button("Analysieren") { model.requestAnalysis() }.keyboardShortcut("r").disabled(model.busy || model.paused || model.source == nil)
                Button("Sortierübersicht öffnen") { model.showSortReview = true }.disabled(model.busy || model.paused || model.batchCandidates.isEmpty)
                Button("Bestätigte Dateien sortieren") { model.sortEligible() }.disabled(model.busy || model.paused || model.eligible.isEmpty)
                Button(model.paused ? "Fortsetzen" : "Pause") { Task { if model.paused { await model.resumeRun() } else { await model.pauseRun() } } }.disabled(!model.sorting && !model.paused)
                Button("Analyse anhalten") { model.stopAnalysis() }.disabled(!model.analyzing)
                Button("Dubletten prüfen") { model.section = .duplicates; Task { await model.findDuplicates() } }.disabled(model.busy || model.paused || model.files.isEmpty)
                Button("Im Finder zeigen") { if let source = model.source { NSWorkspace.shared.activateFileViewerSelecting([source]) } }
            }
            CommandMenu("Auswahl") {
                Button("Alle sichtbaren Dateien auswählen") { model.selectAllVisible() }.disabled(model.busy || model.paused || model.visibleSelectable.isEmpty)
                Button("Auswahl aufheben") { model.clearSelection() }.disabled(model.selectedIDs.isEmpty)
                Divider()
                Button("Hier lassen") { model.keepSelection() }.disabled(model.busy || model.paused || model.selectedFiles.isEmpty)
                Button("Zum Löschen markieren / Markierung aufheben") { model.markSelectionForTrash() }.disabled(model.busy || model.paused || model.selectedFiles.isEmpty)
                Button("Auswahl sortieren") { model.sortSelection() }.disabled(model.busy || model.paused || model.selectedEligible.isEmpty)
            }
            CommandGroup(replacing: .help) {
                Button("Einrichtung öffnen") { model.showOnboarding = true }
                Link("OpenRouter-Hilfe", destination: URL(string: "https://openrouter.ai/docs/quickstart")!)
                Link("Ollama-Hilfe", destination: URL(string: "https://docs.ollama.com")!)
            }
        }
        Settings { SettingsView(model: model).frame(width: 620, height: 640) }
    }
}
