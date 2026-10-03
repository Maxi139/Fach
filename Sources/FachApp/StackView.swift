import SwiftUI
import AppKit
import FachCore

private struct StackFolderSession: Identifiable {
    let id: UUID
    let name: String
}

struct StackView: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var keyboardFocused: Bool
    @State private var folderSession: StackFolderSession?
    @State private var direction = 1

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Stapelmodus").font(.title2.weight(.semibold))
                    Text("\(fileCountLabel(model.stackRemainingCount)) übrig").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Zur Übersicht", systemImage: "square.grid.2x2") { model.endStackMode() }
            }
            if let item = model.stackCurrent {
                VStack(spacing: 8) {
                    Text(item.file.name).font(.title3.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                    Text(ByteCountFormatter.string(fromByteCount: item.file.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 18).fill(Color(nsColor: .controlBackgroundColor)).scaleEffect(0.94).offset(y: 14)
                    RoundedRectangle(cornerRadius: 18).fill(Color(nsColor: .controlBackgroundColor)).scaleEffect(0.97).offset(y: 7)
                    LargeFilePreview(url: item.file.url)
                        .allowsHitTesting(false)
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .shadow(color: .black.opacity(0.14), radius: 12, y: 5)
                        .id(item.id)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .offset(x: CGFloat(direction * 70), y: 12).combined(with: .opacity),
                            removal: .offset(x: CGFloat(direction * -120), y: -12).combined(with: .opacity)))
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.bottom, 14)
                HStack(spacing: 12) {
                    Button { navigate(-1) } label: { Label("Zurück", systemImage: "arrow.left") }
                    Button { navigate(1) } label: { Label("Weiter", systemImage: "arrow.right") }
                    Spacer()
                    Button("Löschen vormerken ⌫", systemImage: "trash") { markCurrent() }
                    Button("Ordner wählen · F", systemImage: "folder") { openFolders() }
                        .buttonStyle(.borderedProminent)
                }.disabled(model.busy || model.paused)
                if let target = item.targetFolder {
                    Text("Zielvorschlag: \(model.folderLabel(target))").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView("Stapel durchgesehen", systemImage: "checkmark.rectangle.stack",
                    description: Text("Deine Zuordnungen sind bereit. In der Übersicht kannst du sortieren und vorgemerkte Dateien in den Papierkorb legen."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Button("Zur Übersicht") { model.endStackMode() }.buttonStyle(.borderedProminent).controlSize(.large)
            }
            if let action = model.stackLastAction {
                Text(action).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Text("← → Datei wechseln   ·   ⌫ Löschen vormerken   ·   F Ordner suchen   ·   Esc Übersicht")
                .font(.caption).foregroundStyle(.secondary)
            Text("Dateien bleiben bis zum Sortieren oder Papierkorb an ihrem Platz.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            StackKeyboardRouter(enabled: model.stackMode && folderSession == nil && !model.busy && !model.paused) { event in
                guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
                switch event.keyCode {
                case 123: navigate(-1)
                case 124: navigate(1)
                case 51, 117:
                    if !event.isARepeat { markCurrent() }
                case 53: model.endStackMode()
                default:
                    guard event.charactersIgnoringModifiers?.lowercased() == "f" else { return false }
                    openFolders()
                }
                return true
            }.frame(width: 0, height: 0)
        }
        .focusable().focusEffectDisabled().focused($keyboardFocused)
        .onAppear { keyboardFocused = true }
        .onKeyPress(.leftArrow, phases: .down) { press in
            guard folderSession == nil, press.modifiers.isEmpty else { return .ignored }
            navigate(-1); return .handled
        }
        .onKeyPress(.rightArrow, phases: .down) { press in
            guard folderSession == nil, press.modifiers.isEmpty else { return .ignored }
            navigate(1); return .handled
        }
        .onKeyPress("f", phases: .down) { press in
            guard folderSession == nil, press.modifiers.isEmpty else { return .ignored }
            openFolders(); return .handled
        }
        .onDeleteCommand { if folderSession == nil { markCurrent() } }
        .onKeyPress(.escape) { guard folderSession == nil else { return .ignored }; model.endStackMode(); return .handled }
        .sheet(item: $folderSession) { session in
            StackFolderSearch(model: model, fileName: session.name) { target in
                guard model.stackCurrent?.id == session.id else { return }
                direction = 1
                withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.9)) {
                    _ = model.assignStackCurrent(target: target)
                }
                folderSession = nil
            }
        }
        .onChange(of: folderSession?.id) { _, value in if value == nil { keyboardFocused = true } }
    }

    private func navigate(_ step: Int) {
        guard !model.busy, !model.paused else { return }
        direction = step
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { model.stackNavigate(direction: step) }
        keyboardFocused = true
    }
    private func openFolders() {
        guard !model.busy, !model.paused, let item = model.stackCurrent else { return }
        folderSession = StackFolderSession(id: item.id, name: item.file.name)
    }
    private func markCurrent() {
        guard !model.busy, !model.paused else { return }
        direction = 1
        withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.9)) { _ = model.markStackCurrentForTrash() }
        keyboardFocused = true
    }
}

private struct StackFolderSearch: View {
    @Bindable var model: AppModel
    let fileName: String
    let choose: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @State private var selectedPath: String?
    @State private var autoChoice: Task<Void, Never>?
    @State private var chosen = false

    private var matches: [URL] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.availableTargets.filter { text.isEmpty || model.folderLabel($0).localizedCaseInsensitiveContains(text) }
    }

    private var highlightedFolder: URL? {
        matches.first { $0.path == selectedPath } ?? matches.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ordner wählen").font(.title2.weight(.semibold))
            Text(fileName).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            TextField("Ordner suchen", text: $query).textFieldStyle(.roundedBorder).focused($searchFocused)
                .onSubmit { selectHighlighted() }
                .onKeyPress(.downArrow) { moveHighlight(1); return .handled }
                .onKeyPress(.upArrow) { moveHighlight(-1); return .handled }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if matches.isEmpty { Text("Kein passender Ordner").foregroundStyle(.secondary).padding(20) }
                        ForEach(matches, id: \.path) { folder in
                            Button { commit(folder) } label: {
                                HStack {
                                    Image(systemName: "folder.fill").foregroundStyle(.tint)
                                    Text(model.folderLabel(folder)).lineLimit(2)
                                    Spacer()
                                    if folder == highlightedFolder { Image(systemName: "return").foregroundStyle(.secondary) }
                                }.padding(12).contentShape(Rectangle())
                                    .background(folder == highlightedFolder ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain).id(folder.path)
                                .accessibilityAddTraits(folder == highlightedFolder ? .isSelected : [])
                        }
                    }
                }.onChange(of: highlightedFolder?.path) { _, path in if let path { proxy.scrollTo(path) } }
            }
            Text("Enter wählt den markierten Ordner. Ein einzelner Suchtreffer wird automatisch gewählt.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Abbrechen", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Text("\(matches.count) Ordner").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }.padding(24).frame(width: 480, height: 460)
        .onAppear { searchFocused = true }
        .onChange(of: query) { _, _ in scheduleUniqueChoice() }
        .onChange(of: matches.map(\.path)) { _, _ in selectedPath = nil; scheduleUniqueChoice() }
        .onDisappear { autoChoice?.cancel() }
    }
    private func moveHighlight(_ step: Int) {
        let candidates = matches
        guard !candidates.isEmpty else { return }
        let index = candidates.firstIndex { $0 == highlightedFolder } ?? 0
        selectedPath = candidates[min(max(index + step, 0), candidates.count - 1)].path
    }
    private func selectHighlighted() {
        guard let folder = highlightedFolder else { return }
        commit(folder)
    }
    private func commit(_ folder: URL) {
        guard !chosen, matches.contains(folder), model.availableTargets.contains(folder) else { return }
        chosen = true; autoChoice?.cancel(); choose(folder)
    }
    private func scheduleUniqueChoice() {
        autoChoice?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, matches.count == 1, let target = matches.first else { return }
        autoChoice = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard !Task.isCancelled, query.trimmingCharacters(in: .whitespacesAndNewlines) == text,
                  matches == [target] else { return }
            commit(target)
        }
    }
}
