import SwiftUI
import FachCore

struct TransferView: View {
    let event: RunEvent?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var travel: CGFloat = 0
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(event?.operation.source.lastPathComponent ?? "Dateien werden sortiert").font(.callout.weight(.medium)).lineLimit(1)
                Text(event?.state == .completed ? "Verschoben" : "Wird geprüft").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Path { path in path.move(to: CGPoint(x: 18, y: 23)); path.addLine(to: CGPoint(x: geometry.size.width - 23, y: 23)) }.stroke(Color.secondary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    Image(systemName: "folder.fill").font(.system(size: 36)).foregroundStyle(.tint).position(x: geometry.size.width - 24, y: 24)
                    if let event {
                        ThumbnailView(url: event.operation.destination ?? event.operation.source, size: 30)
                            .scaleEffect(1 - travel * 0.35).opacity(1 - travel * 0.8)
                            .position(x: 16 + travel * (geometry.size.width - 43), y: 22 - sin(travel * .pi) * 8)
                    }
                }
            }.frame(width: 160, height: 46)
            VStack(alignment: .trailing, spacing: 4) {
                Text(event?.operation.destination?.deletingLastPathComponent().lastPathComponent ?? "Zielordner").font(.callout).lineLimit(1)
                if event?.state == .completed { Label("Erledigt", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .trailing)
        }.padding(12).background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .task(id: event?.id) {
            travel = 0
            if event?.state == .completed { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.65)) { travel = 1 } }
        }
        .accessibilityElement(children: .combine)
    }
}

struct StructureReviewView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(model.restructuring ? "Neuordnung bestätigen" : "Vorschlag für deine Ordner").font(.title2.weight(.semibold))
            Text(model.restructuring ? "Diese Dateien bekommen neue Plätze. Nicht geklärte Dateien bleiben unverändert." : "Prüfe die vorgeschlagenen Ziele. Die bisherigen Ordner bleiben erhalten, bis ihre Dateien neu zugeordnet wurden.").foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(model.structureProposals) { proposal in
                        VStack(alignment: .leading, spacing: 5) {
                            Label(proposal.name, systemImage: "folder.badge.plus").font(.headline)
                            Text(proposal.reason).font(.callout).foregroundStyle(.secondary)
                            Text("Bisher: " + proposal.replaces.map(\.lastPathComponent).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if model.restructuring {
                        Divider()
                        ForEach(model.eligible) { item in VStack(alignment: .leading, spacing: 3) { Text(item.file.name).fontWeight(.medium); Text(item.file.url.path + " → " + (item.targetFolder?.appendingPathComponent(item.file.name).path ?? "")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) } }
                    }
                }
            }.frame(maxHeight: 380)
            HStack {
                Button("Abbrechen", role: .cancel) { dismiss() }
                Spacer()
                Button(model.restructuring ? "Neuordnung ausführen" : "Neue Zuordnungen vorbereiten") {
                    dismiss()
                    if model.restructuring { model.sortEligible(confirmedStructure: true) } else { model.acceptStructure() }
                }.buttonStyle(.borderedProminent).disabled(model.busy || (model.restructuring && model.eligible.isEmpty))
            }
        }.padding(30).frame(width: 680)
    }
}
