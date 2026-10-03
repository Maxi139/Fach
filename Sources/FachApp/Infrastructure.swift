import AppKit
import Foundation
import Security
import Observation

enum KeychainStore {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "OpenRouter Jev API Key", kSecAttrAccount as String: NSUserName()] }
    static func read() -> String? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ value: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let inserted = SecItemAdd(q as CFDictionary, nil)
            guard inserted == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(inserted)) }
        } else if status != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

@MainActor
final class FolderAccess {
    private var active: [URL] = []
    func retain(_ url: URL) {
        if url.startAccessingSecurityScopedResource() { active.append(url) }
        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            var saved = UserDefaults.standard.dictionary(forKey: "folderBookmarks") as? [String: Data] ?? [:]
            saved[url.path] = data; UserDefaults.standard.set(saved, forKey: "folderBookmarks")
        }
    }
    func restore() {
        let saved = UserDefaults.standard.dictionary(forKey: "folderBookmarks") as? [String: Data] ?? [:]
        for (_, data) in saved {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) {
                retain(url)
            }
        }
    }
}

@MainActor @Observable
final class OllamaManager {
    var status = "Noch nicht geprüft"
    var models: [String] = []
    var busy = false
    var downloadProgress: Double?
    var error: String?
    private var launchedProcess: Process?
    private var processLog: FileHandle?
    private let base = URL(string: "http://localhost:11434")!

    private func health() async -> Bool {
        var request = URLRequest(url: base.appendingPathComponent("api/tags")); request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let entries = object["models"] as? [[String: Any]] else { return false }
        models = entries.compactMap { $0["name"] as? String }; return true
    }
    func refresh() async {
        busy = true; defer { busy = false }
        status = await health() ? "Ollama bereit" : "Ollama ist nicht gestartet"
    }
    func ensureRunning() async throws {
        if await health() { status = "Ollama bereit"; return }
        busy = true; error = nil; status = "Ollama wird gestartet"; defer { busy = false }
        let manager = FileManager.default
        let candidates = ["/Applications/Ollama.app", NSHomeDirectory() + "/Applications/Ollama.app"]
        if let path = candidates.first(where: { manager.fileExists(atPath: $0) }) {
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false
            _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration)
        } else {
            let paths = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama", "/Applications/Ollama.app/Contents/Resources/ollama"]
            guard let path = paths.first(where: { manager.isExecutableFile(atPath: $0) }) else {
                status = "Ollama fehlt"
                throw NSError(domain: "Fach", code: 1, userInfo: [NSLocalizedDescriptionKey: "Installiere Ollama. Klicke danach auf ‚Ollama starten‘."])
            }
            if launchedProcess?.isRunning != true {
                let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = ["serve"]
                var environment = ProcessInfo.processInfo.environment; environment["OLLAMA_HOST"] = "127.0.0.1:11434"; environment["OLLAMA_NO_CLOUD"] = "1"
                process.environment = environment
                let logURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Fach/ollama.log")
                try manager.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                manager.createFile(atPath: logURL.path, contents: nil)
                let log = try FileHandle(forWritingTo: logURL); process.standardOutput = log; process.standardError = log
                try process.run(); launchedProcess = process; processLog = log
            }
        }
        for _ in 0..<30 {
            try Task.checkCancellation()
            if await health() { status = "Ollama bereit"; return }
            try await Task.sleep(for: .seconds(1))
        }
        status = "Ollama antwortet nicht"
        throw NSError(domain: "Fach", code: 2, userInfo: [NSLocalizedDescriptionKey: "Ollama konnte nicht gestartet werden. Öffne Ollama und versuche es erneut."])
    }
    func pull(model: String) async {
        guard !busy else { return }
        do {
            try await ensureRunning()
            busy = true; error = nil; downloadProgress = 0; defer { busy = false; downloadProgress = nil }
            var request = URLRequest(url: base.appendingPathComponent("api/pull")); request.httpMethod = "POST"; request.timeoutInterval = 3600
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw NSError(domain: "Fach", code: 3, userInfo: [NSLocalizedDescriptionKey: "Modell konnte nicht heruntergeladen werden."]) }
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard let data = line.data(using: .utf8), let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let message = event["error"] as? String { throw NSError(domain: "Fach", code: 4, userInfo: [NSLocalizedDescriptionKey: message]) }
                status = event["status"] as? String == "success" ? "Modell bereit" : "\(model) wird heruntergeladen"
                if let total = event["total"] as? Double, let completed = event["completed"] as? Double, total > 0 { downloadProgress = completed / total }
            }
            _ = await health(); status = "Modell bereit"
        } catch { self.error = error.localizedDescription; status = "Download unterbrochen" }
    }
    func openInstaller() { NSWorkspace.shared.open(URL(string: "https://ollama.com/download/mac")!) }
}
