import SwiftUI
import FachCore

struct BatchReviewSelection: Identifiable {
    let id = UUID()
    let recommendations: [Recommendation]
}

struct BatchReviewView: View {
    @Bindable var model: AppModel
    let recommendations: [Recommendation]
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<UUID>

    init(model: AppModel, recommendations: [Recommendation]) {
        self.model = model
        self.recommendations = recommendations
        _selectedIDs = State(initialValue: Set(recommendations.map(\.id)))
    }

    private var groups: [URL] {
        Set(recommendations.compactMap(\.targetFolder)).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
    private var remainingCount: Int {
        model.pendingQuestions.filter { !selectedIDs.contains($0.id) }.count
    }

    private func recommendations(in folder: URL) -> [Recommendation] {
        recommendations.filter { $0.targetFolder == folder }
    }

    private func selectionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(id) },
            set: { selected in
                if selected { selectedIDs.insert(id) }
                else { selectedIDs.remove(id) }
            }
        )
    }

    private func groupSelectionBinding(for items: [Recommendation]) -> Binding<Bool> {
        let ids = Set(items.map(\.id))
        return Binding(
            get: { !ids.isEmpty && ids.isSubset(of: selectedIDs) },
            set: { selected in
                if selected { selectedIDs.formUnion(ids) }
                else { selectedIDs.subtract(ids) }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(fileCountLabel(selectedIDs.count)) sortieren").font(.title2.weight(.semibold))
            Text("Dateien werden in die angezeigten Ordner verschoben. Du kannst einzelne Vorschläge abwählen.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Unsichere Vorschläge werden nur mit deiner ausdrücklichen Sammelbestätigung sortiert.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Alle auswählen") { selectedIDs = Set(recommendations.map(\.id)) }
                Button("Keine auswählen") { selectedIDs.removeAll() }
                Spacer()
                Text("\(selectedIDs.count) ausgewählt")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            List {
                ForEach(groups, id: \.path) { folder in
                    let items = recommendations(in: folder)
                    Section {
                        ForEach(items) { item in
                            Toggle(isOn: selectionBinding(for: item.id)) {
                                HStack(spacing: 10) {
                                    ThumbnailView(url: item.file.url, size: 32).frame(width: 32, height: 32)
                                        .frame(width: 32, height: 32)
                                    Text(item.file.name).lineLimit(2)
                                    Spacer()
                                    if !item.autoEligible && !model.isConfirmed(item.id) {
                                        Label("Vorschlag", systemImage: "questionmark.circle")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                            .accessibilityLabel("\(item.file.name) zum Sortieren auswählen")
                            .padding(.vertical, 2)
                        }
                    } header: {
                        HStack {
                            Label(model.folderLabel(folder), systemImage: "folder")
                            Spacer()
                            Toggle("Alle in \(model.folderLabel(folder)) auswählen", isOn: groupSelectionBinding(for: items))
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                                .accessibilityLabel("Alle Dateien für \(model.folderLabel(folder)) auswählen")
                        }
                    }
                }
            }.listStyle(.inset)
            if remainingCount > 0 {
                Text("\(remainingCount) offene Dateien bleiben an ihrem Platz.").font(.callout).foregroundStyle(.secondary)
            }
            Text("Du kannst den Lauf im Verlauf rückgängig machen.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Abbrechen", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("\(fileCountLabel(selectedIDs.count)) sortieren") {
                    model.acceptBatchAndSort(ids: selectedIDs)
                    dismiss()
                }.buttonStyle(.borderedProminent).disabled(model.busy || model.paused || selectedIDs.isEmpty)
            }
        }.padding(24).frame(width: 620, height: 620)
    }
}
