import SwiftUI
import AppKit
import QuickLook
import QuickLookThumbnailing
import FachCore

struct WorkspaceView: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var inspectorVisible = false
    @FocusState private var fileAreaFocused: Bool
    @State private var showFolderPicker = false
    @State private var showOptions = false
    @State private var previewURL: URL?
    @State private var batchReview: BatchReviewSelection?
    @State private var confirmTrash = false
    @State private var confirmRename = false
    @State private var showAddFolder = false
    @State private var newFolderName = ""
    @State private var trashFiles: [FileSnapshot] = []

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 205, max: 260)
        } detail: {
            VStack(spacing: 0) {
                if let error = model.error {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(error).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Hinweis schließen")
                    }.padding(14).background(.orange.opacity(0.09))
                }
                switch model.section {
                case .organize, .questions:
                    if model.stackMode { StackView(model: model) } else { organizer }
                case .duplicates: duplicates
                case .history: history
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .inspector(isPresented: $inspectorVisible) { inspector.inspectorColumnWidth(min: 260, ideal: 300, max: 380) }
            .toolbar { toolbar }
            .navigationTitle(model.section.rawValue)
        }
        .quickLookPreview($previewURL)
        .sheet(isPresented: $model.showOnboarding) { OnboardingView(model: model) }
        .sheet(isPresented: $model.showCloudConsent) { CloudConsentView(model: model) }
        .sheet(item: $batchReview) { review in
            BatchReviewView(model: model, recommendations: review.recommendations)
        }
        .sheet(isPresented: $model.showStructureReview) { StructureReviewView(model: model) }
        .onChange(of: model.showSettings) { _, value in if value { openSettings(); model.showSettings = false } }
        .alert("In den Papierkorb verschieben?", isPresented: $confirmTrash) {
            Button("Abbrechen", role: .cancel) {}
            Button("In Papierkorb", role: .destructive) { Task { await model.trash(trashFiles) } }
        } message: { Text(trashFiles.count == 1 ? "\(trashFiles.first?.name ?? "Datei") wird in den Papierkorb verschoben." : "\(trashFiles.count) ausgewählte Dateien werden in den Papierkorb verschoben.") }
        .alert("Datei umbenennen?", isPresented: $confirmRename) {
            Button("Abbrechen", role: .cancel) {}
            Button("Umbenennen") { Task { await model.renameSelected() } }
        } message: { Text("\(model.selected?.file.name ?? "") → \(model.selected?.suggestedName ?? "")") }
        .alert("Ordner ergänzen", isPresented: $showAddFolder) {
            TextField("Ordnername", text: $newFolderName)
            Button("Abbrechen", role: .cancel) {}
            Button("Ergänzen") {
                let proposal = FolderProposal(name: newFolderName, reason: "Von dir gewählter Ordner")
                model.acceptFolder(proposal)
                if let root = model.targetRoot, let id = model.selectedID {
                    let target = root.appendingPathComponent(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true)
                    if model.availableTargets.contains(target) { model.setTarget(id: id, target: target) }
                }
            }
        } message: { Text("Fach legt ihn beim Sortieren im Zielordner an.") }
        .onChange(of: model.showSortReview) { _, value in
            if value { batchReview = BatchReviewSelection(recommendations: model.batchCandidates); model.showSortReview = false }
        }
        .onChange(of: model.stackMode) { _, enabled in
            if enabled { inspectorVisible = false; fileAreaFocused = false }
        }
        .onChange(of: model.section) { _, section in
            if section == .duplicates || section == .history { model.endStackMode() }
            if section == .questions { model.organizationFilter = .withoutTarget }
            else if section == .organize { model.organizationFilter = .all }
        }
        .onChange(of: model.visible.map(\.id)) { _, _ in model.pruneSelection() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                BrandMark(size: 38)
                VStack(alignment: .leading, spacing: 1) { Text("Fach").font(.title3.weight(.semibold)); Text("Ein passender Platz").font(.caption).foregroundStyle(.secondary) }
            }.padding(20).padding(.top, 8)
            List(selection: $model.section) {
                Section("Arbeitsbereich") {
                    ForEach(WorkspaceSection.allCases) { section in
                        HStack { Label(section.rawValue, systemImage: section.symbol); Spacer(); if section == .questions && model.unassignedCount > 0 { Text("\(model.unassignedCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) } }.tag(section)
                    }
                }
                Section("Ordner") {
                    if let source = model.source { Label(model.sourceLabel, systemImage: "folder").lineLimit(1).help(source.path) }
                    Button("Ordner auswählen …", systemImage: "folder.badge.plus") { model.selectFolder() }.disabled(model.busy || model.paused)
                }
            }.listStyle(.sidebar)
            VStack(alignment: .leading, spacing: 12) {
                Button("Beispiel ausprobieren", systemImage: "play.rectangle") { Task { await model.createDemo() } }.disabled(model.busy || model.paused)
                Button("Einstellungen", systemImage: "gearshape") { openSettings() }
            }.buttonStyle(.plain).font(.callout).foregroundStyle(.secondary).padding(20)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.analyzing { Button("Anhalten", systemImage: "pause.fill") { model.stopAnalysis() } }
            else if model.sorting { Button("Pause", systemImage: "pause.fill") { Task { await model.pauseRun() } } }
            else if model.paused { Button("Fortsetzen", systemImage: "play.fill") { Task { await model.resumeRun() } } }
            else if !model.stackMode {
                Button(model.recommendations.isEmpty ? "Analysieren" : "Neu analysieren", systemImage: "sparkle.magnifyingglass") { model.requestAnalysis() }.labelStyle(.titleAndIcon).disabled(model.busy || model.source == nil || model.targetRoot == nil)

            }
        }
        ToolbarItem {
            Button(model.stackMode ? "Übersicht" : "Stapelmodus", systemImage: model.stackMode ? "square.grid.2x2" : "rectangle.stack") {
                if model.stackMode { model.endStackMode() } else { model.startStackMode() }
            }.help("Stapelmodus · ⌘⇧J").disabled(model.busy || model.paused || (!model.stackMode && model.visibleSelectable.isEmpty))
        }
        ToolbarItem {
            Button { inspectorVisible.toggle() } label: { Image(systemName: "sidebar.right") }.help("Dateivorschau einblenden").accessibilityLabel("Dateivorschau einblenden").disabled(model.stackMode)
        }
    }

    private var organizer: some View {
        Group {
            if model.source == nil { welcome }
            else {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Divider()
                    if model.section == .organize {
                        DisclosureGroup("Ordner und Analyseoptionen", isExpanded: $showOptions) { runOptions.padding(.top, 12) }
                            .padding(.horizontal, 24).padding(.vertical, 10)
                        Divider()
                    }
                    selectionBar
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            if model.isDemo {
                                Label("Beispieldateien. Eigene Dateien bleiben unberührt.", systemImage: "play.rectangle").font(.callout).foregroundStyle(.secondary)
                            }
                            if model.visible.isEmpty {
                                ContentUnavailableView("Keine passenden Dateien", systemImage: model.section == .questions ? "checkmark.circle" : "doc", description: Text("Passe die Filter an oder leere die Suche."))
                            }
                            ForEach(groupNames, id: \.self) { group in
                                VStack(alignment: .leading, spacing: 12) {
                                    groupHeader(group)
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 14)], spacing: 14) {
                                        ForEach(groupFiles(group)) { item in
                                            FileTile(item: item, selected: model.selectedIDs.contains(item.id), completed: model.completedIDs.contains(item.id), protected: model.protectedIDs.contains(item.id), markedForTrash: model.markedTrashIDs.contains(item.id), selectionEnabled: !model.busy && !model.paused, action: {
                                                model.selectFile(id: item.id, extendingRange: NSEvent.modifierFlags.contains(.shift))
                                                fileAreaFocused = true
                                            }, preview: { model.selectedID = item.id; previewURL = currentURL(item) })
                                                .contextMenu {
                                                    Button("Vorschau") { previewURL = currentURL(item) }
                                                    Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([currentURL(item)]) }
                                                    Button("Hier behalten") { model.keep(id: item.id) }.disabled(model.busy || model.paused)
                                                    Divider()
                                                    Button("In Papierkorb …", role: .destructive) { trashFiles = [item.file]; confirmTrash = true }.disabled(model.busy || model.paused || model.completedIDs.contains(item.id) || model.protectedIDs.contains(item.id) || item.file.isProtected)
                                                }
                                        }
                                    }
                                }
                            }
                            if !model.folderProposals.isEmpty { proposals }
                            if model.structureCheckAvailable { Button("Ordnerstruktur prüfen …") { Task { await model.checkStructure() } }.disabled(model.busy || model.paused) }
                            if !model.notices.isEmpty { notices }
                        }.padding(24)
                    }
                    .focusable().focusEffectDisabled().focused($fileAreaFocused)
                    .onDeleteCommand { model.markSelectionForTrash() }
                    .onKeyPress(.space) {
                        guard let selected = model.selected else { return .ignored }
                        previewURL = currentURL(selected); return .handled
                    }
                    .onKeyPress("a", phases: .down) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        model.selectAllVisible(); return .handled
                    }
                    .onKeyPress(.escape) { model.clearSelection(); return .handled }
                }
            }
        }
    }
    private var welcome: some View {
        VStack(spacing: 22) {
            BrandMark(size: 100)
            Text("Ordnung, die zu dir passt.").font(.largeTitle.weight(.semibold))
            Text("Wähle einen Ordner. Fach findet passende Plätze für deine Dateien.").font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            HStack(spacing: 12) {
                Button("Ordner auswählen …", systemImage: "folder.badge.plus") { model.selectFolder() }.buttonStyle(.borderedProminent).controlSize(.large)
                Button("Beispiel ausprobieren") { Task { await model.createDemo() } }.controlSize(.large)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(32)
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.sourceLabel).font(.title.weight(.semibold))
                    if model.busy {
                        Text(model.status).font(.callout).foregroundStyle(.secondary)
                    } else if !model.recommendations.isEmpty {
                        Text("\(model.batchCandidates.count) mit Ziel · \(model.unassignedCount) ohne Ziel")
                            .font(.callout).foregroundStyle(.secondary)
                    } else { Text(model.status).font(.callout).foregroundStyle(.secondary) }
                }
                Spacer()
                if !model.busy && !model.paused {
                    if !model.batchCandidates.isEmpty {
                        Button("\(fileCountLabel(model.batchCandidates.count)) sortieren …", systemImage: "tray.and.arrow.down") {
                            batchReview = BatchReviewSelection(recommendations: model.batchCandidates)
                        }.buttonStyle(.borderedProminent).controlSize(.large)
                    } else if !model.eligible.isEmpty {
                        Button("\(fileCountLabel(model.eligible.count)) sortieren", systemImage: "tray.and.arrow.down") { model.sortEligible() }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                    } else if model.unassignedCount > 0 && model.organizationFilter != .withoutTarget {
                        Button("Dateien ohne Ziel ansehen", systemImage: "questionmark.folder") { model.organizationFilter = .withoutTarget }
                    }
                }
            }
            if model.analyzing { ProgressView(value: model.progress).accessibilityLabel("Analysefortschritt") }
            if model.sorting || model.lastEvent != nil { movement }
            HStack(spacing: 16) {
                Picker("Dateien", selection: $model.organizationFilter) {
                    ForEach(OrganizationFilter.allCases, id: \.self) { filter in Text(filter.rawValue).tag(filter) }
                }.pickerStyle(.segmented)
                TextField("Dateien suchen", text: $model.search).textFieldStyle(.roundedBorder).frame(width: 190)
                    .accessibilityLabel("Dateien suchen")
            }
            HStack(spacing: 8) {
                ForEach(FileGroupFilter.allCases, id: \.self) { filter in
                    Button(filter.rawValue) { model.fileGroupFilter = filter }
                        .buttonStyle(.bordered).tint(model.fileGroupFilter == filter ? .accentColor : .secondary)
                        .accessibilityAddTraits(model.fileGroupFilter == filter ? .isSelected : [])
                }
                Spacer()
                Text("\(fileCountLabel(model.visible.count))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
        }.padding(24)
    }

    private var selectedSuggestions: [Recommendation] { model.batchCandidates.filter { model.selectedIDs.contains($0.id) } }
    private var selectionSortCount: Int { selectedSuggestions.isEmpty ? model.selectedEligible.count : selectedSuggestions.count }

    private var selectionBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button("Alle auswählen") { model.selectAllVisible(); fileAreaFocused = true }
                    .disabled(model.visibleSelectable.isEmpty || model.busy || model.paused)
                if !model.selectedIDs.isEmpty {
                    Text("\(model.selectedFiles.count) ausgewählt").fontWeight(.medium)
                    Button("Auswahl aufheben") { model.clearSelection() }.buttonStyle(.plain).foregroundStyle(.secondary)
                } else {
                    Text("Dateien anklicken, um mehrere auszuwählen.").foregroundStyle(.secondary)
                }
                Spacer()
                if !model.markedTrashFiles.isEmpty {
                    Button("\(model.markedTrashFiles.count) in Papierkorb …", systemImage: "trash", role: .destructive) {
                        trashFiles = model.markedTrashFiles; confirmTrash = true
                    }.disabled(model.busy || model.paused)
                }
            }
            if !model.selectedFiles.isEmpty {
                HStack(spacing: 12) {
                    Button("Ordner wählen …", systemImage: "folder") { showFolderPicker = true }
                        .popover(isPresented: $showFolderPicker) {
                            FolderSelectionPopover(model: model) { folder in
                                model.assignSelection(target: folder); showFolderPicker = false
                            }
                        }
                    Button("Hier lassen", systemImage: "pin") { model.keepSelection() }
                    Button(model.selectedFiles.allSatisfy { model.markedTrashIDs.contains($0.id) } ? "Löschen aufheben" : "Löschen vormerken", systemImage: "trash") {
                        model.markSelectionForTrash(); fileAreaFocused = true
                    }.help("Löschtaste: zum Löschen markieren oder Markierung aufheben")
                    Spacer()
                    Button(selectionSortCount == 0 ? "Auswahl sortieren" : "\(fileCountLabel(selectionSortCount)) sortieren …", systemImage: "tray.and.arrow.down") {
                        if selectedSuggestions.isEmpty { model.sortSelection() }
                        else { batchReview = BatchReviewSelection(recommendations: selectedSuggestions) }
                    }.buttonStyle(.borderedProminent).disabled(selectionSortCount == 0)
                }.disabled(model.busy || model.paused)
            }
        }.font(.callout).padding(.horizontal, 24).padding(.vertical, 12)
    }

    private func groupHeader(_ group: String) -> some View {
        let items = groupFiles(group)
        let selectableIDs = Set(items.filter { !model.completedIDs.contains($0.id) && !model.protectedIDs.contains($0.id) && !$0.file.isProtected }.map(\.id))
        return HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { !selectableIDs.isEmpty && selectableIDs.isSubset(of: model.selectedIDs) }, set: { _ in
                model.selectGroup(ids: selectableIDs); fileAreaFocused = true
            })) {
                Label(group == "Offen" ? "Noch keinen Zielordner" : model.folderLabel(URL(fileURLWithPath: group)),
                      systemImage: group == "Offen" ? "questionmark.folder" : "folder.fill")
                    .font(.headline)
            }.toggleStyle(.checkbox).disabled(selectableIDs.isEmpty || model.busy || model.paused)
            Text("\(items.count)").foregroundStyle(.secondary).font(.callout)
            Spacer()
        }
    }
    private var runOptions: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(String(format: "Cloud-Verbrauch: %.3f / %.2f USD", model.spentUSD, model.configuration.budgetUSD))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Picker("Ziel", selection: $model.useSeparateDestination) {
                    Text("In diesem Ordner").tag(false); Text("Anderer Zielordner").tag(true)
                }.frame(maxWidth: 350).onChange(of: model.useSeparateDestination) { _, _ in model.invalidateAnalysis(); Task { await model.loadTargetFolders() } }
                if model.useSeparateDestination { Button(model.destination?.lastPathComponent ?? "Ziel auswählen …") { model.selectFolder(destination: true) } }
                Spacer()
            }
            HStack {
                Toggle("Unterordner einbeziehen", isOn: $model.recursive).onChange(of: model.recursive) { _, _ in Task { await model.scan() } }
                Spacer()
                Text("Vorhandene Ordner bevorzugen").font(.caption).foregroundStyle(.secondary)
            }
            TextField("Was ist gerade wichtig? Zum Beispiel: Prüfungsvorbereitung bleibt aktiv.", text: $model.context).textFieldStyle(.roundedBorder).accessibilityLabel("Aktuelles Vorhaben").onChange(of: model.context) { _, _ in if !model.busy { model.status = "Vorhaben geändert. Erneut analysieren oder selbst zuordnen." } }
        }.disabled(model.busy || model.paused)
    }
    private var movement: some View {
        TransferView(event: model.lastEvent)
    }
    private var groupNames: [String] { Set(model.visible.map { $0.targetFolder?.path ?? "Offen" }).sorted { a, b in if a == "Offen" { return false }; if b == "Offen" { return true }; return a.localizedStandardCompare(b) == .orderedAscending } }
    private func groupFiles(_ name: String) -> [Recommendation] { model.visible.filter { ($0.targetFolder?.path ?? "Offen") == name } }
    private var proposals: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Passende Ergänzungen").font(.headline)
            ForEach(model.folderProposals) { proposal in
                HStack(alignment: .top) {
                    Image(systemName: "folder.badge.plus").foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) { Text(proposal.name).fontWeight(.medium); Text(proposal.reason).font(.callout).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Nutzen") { model.acceptFolder(proposal) }.disabled(model.busy || model.paused)
                }
            }
            if !model.acceptedFolders.isEmpty { Button("Zuordnungen erneut prüfen") { model.requestAnalysis() }.disabled(model.busy || model.paused) }
        }
    }
    private var notices: some View {
        DisclosureGroup("Hinweise (\(model.notices.count))") {
            ForEach(Array(model.notices.enumerated()), id: \.offset) { _, text in Text(text).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3) }
        }
    }
    private var inspector: some View {
        ScrollView {
            if model.selectedFiles.count > 1 {
                VStack(alignment: .leading, spacing: 16) {
                    Text("\(model.selectedFiles.count) Dateien ausgewählt").font(.title2.weight(.semibold))
                    Text("Wähle gemeinsam einen Ordner oder markiere die Auswahl zum Löschen.").foregroundStyle(.secondary)
                    Button("Ordner wählen …", systemImage: "folder") { showFolderPicker = true }
                    Button("Hier lassen", systemImage: "pin") { model.keepSelection() }
                }.padding(24)
            } else if let item = model.selected {
                VStack(alignment: .leading, spacing: 20) {
                    ThumbnailView(url: currentURL(item), size: 200).frame(maxWidth: .infinity).frame(height: 180)
                    VStack(alignment: .leading, spacing: 6) { Text(item.file.name).font(.title3.weight(.semibold)).textSelection(.enabled); Text(ByteCountFormatter.string(fromByteCount: item.file.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                    HStack { Button("Vorschau", systemImage: "eye") { previewURL = currentURL(item) }; Button { NSWorkspace.shared.activateFileViewerSelecting([currentURL(item)]) } label: { Image(systemName: "folder") }.accessibilityLabel("Im Finder zeigen") }
                    Divider()
                    if model.completedIDs.contains(item.id) { Label("Sortiert", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    else if model.protectedIDs.contains(item.id) { Label("Bleibt an diesem Platz", systemImage: "pin.fill") }
                    else {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("Passender Platz").font(.headline)
                            Text(item.reason).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            Picker("Zielordner", selection: Binding(get: { item.targetFolder?.path ?? "" }, set: { path in model.setTarget(id: item.id, target: path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)) })) {
                                Text("Noch offen").tag("")
                                ForEach(model.availableTargets, id: \.path) { folder in Text(model.folderLabel(folder)).tag(folder.path) }
                            }
                            Button("Ordner ergänzen …", systemImage: "folder.badge.plus") { newFolderName = ""; showAddFolder = true }
                            Picker("Wichtigkeit", selection: Binding(get: { item.importance }, set: { importance in model.setTarget(id: item.id, target: item.targetFolder, importance: importance) })) { ForEach(Importance.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                            if model.isConfirmed(item.id) {
                                Label("Zuordnung bestätigt", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            } else {
                                Button("Zuordnung bestätigen", systemImage: "checkmark") { model.confirmTarget(id: item.id) }
                                    .buttonStyle(.borderedProminent).disabled(item.targetFolder == nil)
                            }
                            Button("Hier behalten", systemImage: "pin") { model.keep(id: item.id) }
                        }.disabled(model.busy || model.paused)
                    }
                    if !item.evidence.summary.isEmpty { VStack(alignment: .leading, spacing: 7) { Text("Inhalt").font(.headline); Text(item.evidence.summary).font(.callout).foregroundStyle(.secondary).textSelection(.enabled); Text(item.evidence.origin).font(.caption).foregroundStyle(.tertiary) } }
                    if let name = item.suggestedName, name != item.file.name, !model.completedIDs.contains(item.id) {
                        VStack(alignment: .leading, spacing: 8) { Text("Dateiname").font(.headline); Text(name).font(.callout).textSelection(.enabled); Button("Umbenennen …") { confirmRename = true }.disabled(model.busy || item.file.isProtected) }
                    }
                    if !model.completedIDs.contains(item.id), !model.protectedIDs.contains(item.id), !item.file.isProtected { Divider(); Button("In Papierkorb …", systemImage: "trash", role: .destructive) { trashFiles = [item.file]; confirmTrash = true }.disabled(model.busy || model.paused) }
                }.padding(24)
            } else { ContentUnavailableView("Datei auswählen", systemImage: "doc.text.magnifyingglass", description: Text("Vorschau und Zuordnung erscheinen hier.")).padding(.top, 80) }
        }
    }
    private func currentURL(_ item: Recommendation) -> URL {
        if model.completedIDs.contains(item.id), let target = item.targetFolder { return target.appendingPathComponent(item.file.name) }
        return item.file.url
    }
    private var duplicates: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack { VStack(alignment: .leading, spacing: 6) { Text("Gleicher Inhalt, mehrere Dateien").font(.title2.weight(.semibold)); Text("Wähle selbst, welche Kopie du behältst.").foregroundStyle(.secondary) }; Spacer(); Button("Dubletten prüfen") { Task { await model.findDuplicates() } }.disabled(model.busy || model.files.isEmpty) }
                if model.duplicateGroups.isEmpty { ContentUnavailableView(model.duplicateChecked ? "Keine Dubletten gefunden" : "Dateien vergleichen", systemImage: "doc.on.doc", description: Text(model.duplicateChecked ? "Die geprüften Dateien haben unterschiedliche Inhalte." : "Der Vergleich prüft den vollständigen Dateiinhalt.")) }
                ForEach(Array(model.duplicateGroups.enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 12) {
                        Text("\(group.count) identische Dateien").font(.headline)
                        ForEach(group) { file in HStack { Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path)).resizable().frame(width: 28, height: 28); VStack(alignment: .leading) { Text(file.name); Text(file.url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(1) }; Spacer(); Button("Papierkorb …") { trashFiles = [file]; confirmTrash = true }.disabled(model.busy || model.paused) } }
                    }.padding(18).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                }
            }.padding(28)
        }
    }
    private var history: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Deine Aufräumläufe").font(.title2.weight(.semibold))
                if model.runIDs.isEmpty { ContentUnavailableView("Noch kein Lauf", systemImage: "clock.arrow.circlepath", description: Text("Nach dem Sortieren kannst du Änderungen hier rückgängig machen.")) }
                ForEach(model.runIDs, id: \.self) { id in
                    let events = model.history.filter { $0.runID == id }
                    let latest = Dictionary(grouping: events, by: { $0.operation.id }).compactMap { $0.value.max { $0.date < $1.date } }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { VStack(alignment: .leading, spacing: 3) { Text(events.first?.date ?? Date(), format: .dateTime.day().month().hour().minute()).font(.headline); Text("\(model.undoable[id]?.count ?? 0) Änderungen").foregroundStyle(.secondary).font(.callout) }; Spacer(); Button("Rückgängig") { Task { await model.undo(id) } }.disabled(model.busy || (model.undoable[id]?.isEmpty ?? true)) }
                        DisclosureGroup("Dateien anzeigen") {
                            ForEach(latest.sorted { $0.date < $1.date }) { event in
                                HStack(alignment: .top) { Image(systemName: event.state == .completed ? "checkmark.circle" : event.state == .undone ? "arrow.uturn.backward" : "exclamationmark.circle"); VStack(alignment: .leading, spacing: 3) { Text(event.operation.source.lastPathComponent); if let destination = event.operation.destination { Text(destination.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }; if !event.message.isEmpty { Text(event.message).font(.caption).foregroundStyle(.secondary) } }; Spacer(); if model.undoable[id]?.contains(event.operation.id) == true { Button { Task { await model.undoAction(runID: id, operationID: event.operation.id) } } label: { Image(systemName: "arrow.uturn.backward") }.disabled(model.busy || model.paused).help("Diese Änderung rückgängig machen").accessibilityLabel("Diese Änderung rückgängig machen") } }.padding(.vertical, 4)
                            }
                        }
                    }.padding(20).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                }
            }.padding(28)
        }
    }
}

struct FileTile: View {
    let item: Recommendation
    let selected: Bool
    let completed: Bool
    let protected: Bool
    let markedForTrash: Bool
    let selectionEnabled: Bool
    let action: () -> Void
    let preview: () -> Void
    private var tint: Color { markedForTrash ? .red : .accentColor }
    private var status: String {
        completed ? "Sortiert" : protected ? "Bleibt hier" : markedForTrash ? "Zum Löschen" : item.targetFolder == nil ? "Ordner wählen" : item.isApproved || item.autoEligible ? "Bereit zum Sortieren" : "Ziel vorgeschlagen"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("\(item.file.name) auswählen", isOn: Binding(get: { selected }, set: { _ in action() }))
                    .labelsHidden().toggleStyle(.checkbox).disabled(!selectionEnabled || completed || protected || item.file.isProtected)
                Spacer()
                Button(action: preview) { Image(systemName: "eye") }
                    .buttonStyle(.plain).frame(width: 28, height: 28).accessibilityLabel("\(item.file.name) ansehen")
            }
            Button(action: action) {
                VStack(alignment: .leading, spacing: 10) {
                    ThumbnailView(url: completed ? item.targetFolder?.appendingPathComponent(item.file.name) ?? item.file.url : item.file.url, size: 96)
                        .frame(maxWidth: .infinity).frame(height: 88)
                    Text(item.file.name).font(.callout.weight(.medium)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    Label(status, systemImage: completed ? "checkmark.circle.fill" : protected ? "pin.fill" : markedForTrash ? "trash.fill" : item.targetFolder == nil ? "questionmark.folder" : "folder")
                        .font(.caption).foregroundStyle(markedForTrash ? .red : .secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(item.file.name), \(status)")
        }.padding(12).background(selected ? tint.opacity(0.09) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(markedForTrash || selected ? tint.opacity(0.7) : Color.primary.opacity(0.07), lineWidth: markedForTrash || selected ? 2 : 1))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ThumbnailView: View {
    let url: URL
    let size: CGFloat
    @State private var image: NSImage?
    var body: some View {
        Image(nsImage: image ?? NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit().frame(maxWidth: size, maxHeight: size).accessibilityHidden(true)
            .task(id: url) {
                let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size * 2, height: size * 2), scale: 2, representationTypes: .all)
                if let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { image = thumbnail.nsImage }
            }
    }
}

struct BrandMark: View {
    var size: CGFloat = 64
    var body: some View {
        Group {
            if let url = Bundle.module.url(forResource: "FachIcon", withExtension: "png"), let image = NSImage(contentsOf: url) { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "tray.2.fill").resizable().scaledToFit().foregroundStyle(.tint).padding(size * 0.18).background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: size * 0.22)) }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.22)).accessibilityHidden(true)
    }
}

func fileCountLabel(_ count: Int) -> String { "\(count) \(count == 1 ? "Datei" : "Dateien")" }
