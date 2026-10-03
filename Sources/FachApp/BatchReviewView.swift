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

    private var groups: [URL] {
        Set(recommendations.compactMap(\.targetFolder)).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
    private var remainingCount: Int {
        model.pendingQuestions.filter { item in !recommendations.contains { $0.id == item.id } }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(recommendations.count) Dateien sortieren").font(.title2.weight(.semibold))
            Text("Die angezeigten Zielvorschläge werden gemeinsam übernommen – auch wenn Fach noch unsicher ist. Prüfe die Übersicht vor dem Sortieren.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(groups, id: \.path) { folder in
                    Section {
                        ForEach(recommendations.filter { $0.targetFolder == folder }) { item in
                            HStack(spacing: 10) {
                                ThumbnailView(url: item.file.url, size: 32).frame(width: 32, height: 32)
                                Text(item.file.name).lineLimit(2)
                                Spacer()
                                if !item.autoEligible && !model.isConfirmed(item.id) {
                                    Label("Vorschlag", systemImage: "questionmark.circle").font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 2)
                        }
                    } header: {
                        Label(model.folderLabel(folder), systemImage: "folder")
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
                Button("Übernehmen und sortieren") {
                    model.acceptBatchAndSort(ids: Set(recommendations.map(\.id)))
                    dismiss()
                }.buttonStyle(.borderedProminent).disabled(model.busy || model.paused || recommendations.isEmpty)
            }
        }.padding(24).frame(width: 620, height: 620)
    }
}
