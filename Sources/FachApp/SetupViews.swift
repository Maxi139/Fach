import SwiftUI
import AppKit
import FachAI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var key = ""
    @State private var keySaved = false
    @State private var keyPresent = false
    @State private var connectionResult: String?
    @State private var checking = false
    @State private var downloadModel: String?
    @State private var confirmDownload = false

    var body: some View {
        TabView {
            ScrollView {
                Form {
                    Section("Analyse") {
                        Picker("KI verwenden", selection: $model.configuration.mode) {
                            Text("Hybrid: lokal und OpenRouter").tag(AIConfiguration.Mode.hybrid)
                            Text("Nur lokal").tag(AIConfiguration.Mode.local)
                        }
                        Text(model.configuration.mode == .local ? "Dateiinhalte bleiben auf diesem Mac. Dafür werden lokale Modelle benötigt." : "Ollama übernimmt Bilder, wenn es verfügbar ist. OpenRouter hilft bei Zuordnung und Ordnernamen.").font(.callout).foregroundStyle(.secondary)
                    }
                    Section("OpenRouter") {
                        SecureField(keyPresent ? "Neuen API-Key einfügen" : "API-Key einfügen", text: $key).textContentType(.password)
                        HStack {
                            Button("Key speichern") {
                                do { try KeychainStore.save(key.trimmingCharacters(in: .whitespacesAndNewlines)); key = ""; keyPresent = true; keySaved = true; model.saveConfiguration() }
                                catch { model.error = "Key konnte nicht gespeichert werden: \(error.localizedDescription)" }
                            }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            if keyPresent { Label(keySaved ? "Gespeichert" : "Key hinterlegt", systemImage: "lock.shield").foregroundStyle(.secondary).font(.callout) }
                            Spacer()
                            Link("Key erstellen", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                        }
                        LabeledContent("Budget je Lauf") {
                            TextField("USD", value: $model.configuration.budgetUSD, format: .number.precision(.fractionLength(2))).frame(width: 80).multilineTextAlignment(.trailing)
                            Text("USD").foregroundStyle(.secondary)
                        }
                        Text("Fach hält vor weiteren kostenpflichtigen Anfragen an, wenn das Budget nicht reicht.").font(.callout).foregroundStyle(.secondary)
                        DisclosureGroup("Modelle anpassen") {
                            TextField("Textmodell", text: $model.configuration.cloudTextModel)
                            TextField("Bildmodell", text: $model.configuration.cloudVisionModel)
                        }
                        Button(checking ? "Verbindung wird geprüft" : "Verbindung prüfen") { checkConnection() }.disabled(checking || model.busy)
                        if let connectionResult { Text(connectionResult).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                }.formStyle(.grouped)
            }.tabItem { Label("KI", systemImage: "sparkle.magnifyingglass") }
            ScrollView {
                Form {
                    Section("Ollama") {
                        HStack { Text(model.ollama.status); Spacer(); if model.ollama.busy { ProgressView().controlSize(.small) } }
                        HStack {
                            Button("Ollama starten") { Task { do { try await model.ollama.ensureRunning() } catch { model.ollama.error = error.localizedDescription } } }.disabled(model.ollama.busy)
                            Button("Ollama installieren") { model.ollama.openInstaller() }
                            Button("Erneut prüfen") { Task { await model.ollama.refresh() } }.disabled(model.ollama.busy)
                        }
                        if let error = model.ollama.error { Text(error).font(.callout).foregroundStyle(.orange) }
                        if let progress = model.ollama.downloadProgress { ProgressView(value: progress).accessibilityLabel("Modelldownload") }
                    }
                    Section("Lokale Modelle") {
                        modelPicker("Bilder", selection: $model.configuration.visionModel)
                        modelPicker("Text", selection: $model.configuration.textModel)
                        HStack {
                            Button("Bildmodell laden") { downloadModel = model.configuration.visionModel; confirmDownload = true }.disabled(model.ollama.busy)
                            Button("Textmodell laden") { downloadModel = model.configuration.textModel; confirmDownload = true }.disabled(model.ollama.busy)
                        }
                        Text("LLaVA 7B benötigt etwa 4,7 GB Speicher. Andere Modelle können größer sein.").font(.callout).foregroundStyle(.secondary)
                    }
                    Section("Einrichtung") {
                        Text("Installiere Ollama aus dem Download. Öffne es einmal. Danach kann Fach den Dienst starten und Modelle herunterladen.").font(.callout)
                        Link("Ollama herunterladen", destination: URL(string: "https://ollama.com/download/mac")!)
                        Text("Zum Download wird Internet benötigt. Die anschließende lokale Analyse funktioniert auch offline.").font(.callout).foregroundStyle(.secondary)
                    }
                }.formStyle(.grouped)
            }.tabItem { Label("Lokal", systemImage: "desktopcomputer") }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("OpenRouter einrichten").font(.title2.weight(.semibold))
                    GuideStep(number: "1", title: "Konto erstellen", text: "Registriere dich bei OpenRouter. Ein bestehendes Konto kannst du direkt verwenden.", link: "OpenRouter öffnen", url: "https://openrouter.ai")
                    GuideStep(number: "2", title: "Guthaben aufladen", text: "Cloudanalyse kostet Geld. Ein kleines Guthaben reicht zum Ausprobieren. Lege beim API-Key zusätzlich ein Ausgabenlimit fest.", link: "Guthaben verwalten", url: "https://openrouter.ai/settings/credits")
                    GuideStep(number: "3", title: "API-Key erstellen", text: "Erstelle einen neuen Key, kopiere ihn und füge ihn im Bereich ‚KI‘ ein. Teile ihn nicht mit anderen.", link: "API-Key erstellen", url: "https://openrouter.ai/settings/keys")
                    Divider()
                    Text("Vor jedem Cloudlauf wählst du, welche Inhalte übertragen werden dürfen. Namen und Beschreibungen können ebenfalls persönliche Informationen enthalten.").font(.callout).foregroundStyle(.secondary)
                    Button("Einrichtung erneut öffnen") { model.showOnboarding = true }
                }.padding(28)
            }.tabItem { Label("Anleitung", systemImage: "book") }
        }
        .padding(.top, 10)
        .onAppear { keyPresent = KeychainStore.read() != nil; Task { await model.ollama.refresh() } }
        .onChange(of: model.configuration.mode) { _, _ in model.saveConfiguration() }
        .onDisappear { model.saveConfiguration() }
        .onChange(of: model.configuration.budgetUSD) { _, _ in model.saveConfiguration() }
        .onChange(of: model.configuration.visionModel) { _, _ in model.saveConfiguration() }
        .onChange(of: model.configuration.textModel) { _, _ in model.saveConfiguration() }
        .onChange(of: model.configuration.cloudTextModel) { _, _ in model.saveConfiguration() }
        .onChange(of: model.configuration.cloudVisionModel) { _, _ in model.saveConfiguration() }
        .alert("Modell herunterladen?", isPresented: $confirmDownload) {
            Button("Abbrechen", role: .cancel) {}
            Button("Herunterladen") { if let name = downloadModel { Task { await model.ollama.pull(model: name) } } }
        } message: { Text("\(downloadModel ?? "Das Modell") wird auf diesem Mac gespeichert. Der Download kann mehrere GB groß sein.") }
    }
    private func modelPicker(_ title: String, selection: Binding<String>) -> some View {
        HStack {
            TextField(title, text: selection)
            if !model.ollama.models.isEmpty {
                Menu("Auswählen") { ForEach(model.ollama.models, id: \.self) { name in Button(name) { selection.wrappedValue = name } } }
            }
        }
    }
    private func checkConnection() {
        checking = true; connectionResult = nil
        Task {
            defer { checking = false }
            do {
                if model.configuration.mode == .local { try await model.ollama.ensureRunning() }
                let service = AIService(configuration: model.configuration, apiKey: KeychainStore.read())
                connectionResult = try await service.checkConnection()
            } catch { connectionResult = error.localizedDescription }
        }
    }
}

struct GuideStep: View {
    let number: String
    let title: String
    let text: String
    let link: String
    let url: String
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(number).font(.headline.monospacedDigit()).frame(width: 30, height: 30).background(.tint.opacity(0.1), in: Circle()).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 7) { Text(title).font(.headline); Text(text).font(.callout).foregroundStyle(.secondary); Link(link, destination: URL(string: url)!) }
        }
    }
}

struct OnboardingView: View {
    @Bindable var model: AppModel
    @State private var step = 0
    @State private var key = ""
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Fach einrichten").font(.headline); Spacer(); Button { model.finishOnboarding(); dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Einrichtung schließen") }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch step {
                    case 0:
                        BrandMark(size: 100).frame(maxWidth: .infinity).padding(.vertical, 18)
                        Text("Deine Dateien. Deine Ordnung.").font(.largeTitle.weight(.semibold))
                        Text("Fach nutzt vorhandene Ordner und fragt bei unklaren Dateien nach. Du kannst jeden Aufräumlauf rückgängig machen.").font(.title3).foregroundStyle(.secondary)
                        Label("Umbenennen und Papierkorb bestätigst du selbst.", systemImage: "hand.raised").font(.callout)
                        Button("Mit Beispieldateien ausprobieren", systemImage: "play.rectangle") { model.finishOnboarding(); Task { await model.createDemo() }; dismiss() }.controlSize(.large)
                    case 1:
                        Text("Welche KI passt zu dir?").font(.largeTitle.weight(.semibold))
                        Picker("Analyse", selection: $model.configuration.mode) {
                            Text("Hybrid: einfach mit OpenRouter").tag(AIConfiguration.Mode.hybrid)
                            Text("Nur lokal: Inhalte bleiben hier").tag(AIConfiguration.Mode.local)
                        }.pickerStyle(.radioGroup)
                        if model.configuration.mode == .hybrid {
                            GuideStep(number: "1", title: "Konto und Guthaben", text: "Erstelle ein OpenRouter-Konto und lade etwas Guthaben auf. Fach verwendet standardmäßig höchstens 0,10 USD als Anfragebudget pro Lauf.", link: "OpenRouter öffnen", url: "https://openrouter.ai/settings/credits")
                            GuideStep(number: "2", title: "API-Key erstellen", text: "Erstelle einen Key mit eigenem Ausgabenlimit. Kopiere ihn und füge ihn hier ein.", link: "Key erstellen", url: "https://openrouter.ai/settings/keys")
                            SecureField("API-Key", text: $key).textFieldStyle(.roundedBorder)
                            Button("Key speichern") { do { try KeychainStore.save(key.trimmingCharacters(in: .whitespacesAndNewlines)); key = ""; message = "Key gespeichert." } catch { message = "Key konnte nicht gespeichert werden: \(error.localizedDescription)" } }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
                        } else {
                            Text("Für lokale Analyse brauchst du Ollama und je ein Bild- und Textmodell. Fach hilft dir beim Starten und Herunterladen.").font(.title3).foregroundStyle(.secondary)
                        }
                    case 2:
                        Text(model.configuration.mode == .local ? "Ollama vorbereiten" : "Bilder lokal verstehen").font(.largeTitle.weight(.semibold))
                        Text(model.configuration.mode == .local ? "Installiere Ollama, starte es und lade die Modelle herunter." : "Ollama ist optional. Mit Ollama können Bilder auf deinem Mac analysiert werden.").font(.title3).foregroundStyle(.secondary)
                        Label(model.ollama.status, systemImage: "desktopcomputer")
                        HStack { Button("Ollama installieren") { model.ollama.openInstaller() }; Button("Ollama starten") { Task { do { try await model.ollama.ensureRunning() } catch { model.ollama.error = error.localizedDescription } } }.disabled(model.ollama.busy) }
                        if let error = model.ollama.error { Text(error).font(.callout).foregroundStyle(.orange) }
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Modelle").font(.headline)
                            ForEach([model.configuration.visionModel, model.configuration.textModel], id: \.self) { name in
                                HStack { Text(name); Spacer(); if model.ollama.models.contains(where: { $0 == name || $0 == name + ":latest" }) { Label("Bereit", systemImage: "checkmark.circle").foregroundStyle(.secondary) } else { Button("Laden …") { modelToDownload = name; confirmDownload = true }.disabled(model.ollama.busy) } }
                            }
                            Text("Downloads benötigen mehrere GB Speicher und können einige Minuten dauern.").font(.callout).foregroundStyle(.secondary)
                            if let progress = model.ollama.downloadProgress { ProgressView(value: progress) }
                        }
                    default:
                        Text("Bereit für deinen ersten Ordner.").font(.largeTitle.weight(.semibold))
                        Text("Beginne mit dem Desktop oder einem kleinen Ordner. Unterordner bleiben zunächst unberührt.").font(.title3).foregroundStyle(.secondary)
                        Label("Vorhandene Ordnung zuerst", systemImage: "folder")
                        Label("Zielort vor jedem Lauf wählen", systemImage: "arrow.turn.down.right")
                        Label("Dateien bei Bedarf hier behalten", systemImage: "pin")
                        Button("Ordner auswählen …") { model.finishOnboarding(); dismiss(); model.selectFolder() }.buttonStyle(.borderedProminent).controlSize(.large)
                    }
                }.padding(32).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if step > 0 { Button("Zurück") { step -= 1 } }
                Spacer()
                Text("\(step + 1) von 4").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(step == 3 ? "Fertig" : "Weiter") { model.saveConfiguration(); if step == 3 { model.finishOnboarding(); dismiss() } else { step += 1 } }.buttonStyle(.borderedProminent)
            }.padding(24)
        }.frame(width: 640, height: 660)
        .task { await model.ollama.refresh() }
        .interactiveDismissDisabled(model.ollama.busy)
        .alert("Modell herunterladen?", isPresented: $confirmDownload) {
            Button("Abbrechen", role: .cancel) {}
            Button("Herunterladen") { if let name = modelToDownload { Task { await model.ollama.pull(model: name) } } }
        } message: { Text("\(modelToDownload ?? "Modell") wird lokal gespeichert. Dafür werden Internet und mehrere GB Speicher benötigt.") }
    }
    @State private var modelToDownload: String?
    @State private var confirmDownload = false
}

struct CloudConsentView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Cloudanalyse freigeben", systemImage: "network").font(.title2.weight(.semibold))
            Text("OpenRouter und die ausgewählten Anbieter erhalten Dateinamen, Beschreibungen, Zielordner und dein Vorhaben. Diese Angaben können persönlich sein.").foregroundStyle(.secondary)
            DisclosureGroup("\(model.files.filter { !model.protectedIDs.contains($0.id) }.count) Dateien anzeigen") {
                ScrollView { VStack(alignment: .leading, spacing: 5) { ForEach(model.files.filter { !model.protectedIDs.contains($0.id) }) { file in Text(file.url.path).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } } }.frame(maxHeight: 150)
            }
            Toggle("Textauszüge und Bilder mitsenden", isOn: $model.allowOriginals)
            Text(model.allowOriginals ? "Die Analyse darf Inhalte ausgewählter Dateien übertragen. Bei Bildern verwendet Fach verkleinerte Kopien." : "Fach erstellt zuerst lokale Beschreibungen. Dafür muss Ollama bereit sein.").font(.callout).foregroundStyle(.secondary)
            LabeledContent("Anbieter", value: "OpenRouter, TypeSafe und Modellanbieter")
            LabeledContent("Anfragebudget", value: String(format: "%.2f USD", model.configuration.budgetUSD))
            Link("Datenverwendung bei OpenRouter", destination: URL(string: "https://openrouter.ai/docs/guides/privacy/data-collection")!)
            HStack {
                Button("Abbrechen", role: .cancel) { dismiss() }
                Spacer()
                Button("Nur lokal analysieren") { dismiss(); model.startLocalAnalysis() }
                Button("Freigeben und analysieren") { dismiss(); model.startCloudAnalysis() }.buttonStyle(.borderedProminent)
            }
        }.padding(30).frame(width: 620)
    }
}
