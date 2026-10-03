import SwiftUI
import FachCore

struct FolderSelectionPopover: View {
    @Bindable var model: AppModel
    let choose: (URL) -> Void
    @State private var search = ""

    private var folders: [URL] {
        model.availableTargets.filter { search.isEmpty || model.folderLabel($0).localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ordner für \(fileCountLabel(model.selectedFiles.count))").font(.headline)
            TextField("Ordner suchen", text: $search).textFieldStyle(.roundedBorder)
            if folders.isEmpty {
                ContentUnavailableView("Kein passender Ordner", systemImage: "folder", description: Text("Wähle einen vorhandenen Ordner oder ergänze einen Ordner in der Dateivorschau."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(folders, id: \.path) { folder in
                            Button { choose(folder) } label: {
                                HStack {
                                    Image(systemName: "folder.fill").foregroundStyle(.tint)
                                    Text(model.folderLabel(folder)).lineLimit(2)
                                    Spacer()
                                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                }.padding(10).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("Auswahl zu \(model.folderLabel(folder)) zuordnen")
                        }
                    }
                }
            }
            Text("Die Dateien werden beim Sortieren verschoben.").font(.caption).foregroundStyle(.secondary)
        }.padding(18).frame(width: 330, height: 380)
    }
}
