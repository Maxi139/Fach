import Foundation

/// A bounded, metadata-only view of a folder that can be used to recognise an
/// already existing destination. `fileNames` contains direct regular-file
/// children only; it never contains file contents or descendants.
public struct FolderProfile: Hashable, Sendable {
    public let url: URL
    public let fileNames: [String]
    public let purpose: String

    public init(url: URL, fileNames: [String], purpose: String = "") {
        self.url = url.standardizedFileURL
        self.fileNames = fileNames
        self.purpose = String(purpose.prefix(1_200))
    }
}

/// Builds safe, small folder profiles without reading user file contents.
public enum FolderKnowledge {
    public static let maximumFolders = 256
    public static let maximumFilesPerFolder = 256
    public static let maximumEntriesPerFolder = 1_024

    public static func inspect(folders: [URL]) async -> [FolderProfile] {
        let uniqueFolders = Array(Set(folders.map { $0.standardizedFileURL }))
            .sorted {
                let order = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
            }
            .prefix(maximumFolders)

        return uniqueFolders.compactMap { folder in
            guard (try? FileSafety.validatePath(folder, within: folder)) != nil else { return nil }
            guard let snapshot = try? FileSafety.snapshot(folder),
                  snapshot.isDirectory, !snapshot.isProtected else { return nil }

            guard let children = try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return nil }

            let names = children.sorted { compare($0.lastPathComponent, $1.lastPathComponent) }
                .prefix(maximumEntriesPerFolder).compactMap { child -> String? in
                guard !child.lastPathComponent.hasPrefix("."),
                      let childSnapshot = try? FileSafety.snapshot(child),
                      !childSnapshot.isDirectory, !childSnapshot.isProtected else { return nil }
                // `snapshot` marks symbolic links protected. Only plain regular
                // files are useful as references, so special filesystem entries
                // are excluded as well.
                guard let info = try? FileSafety.stat(child),
                      (info.st_mode & S_IFMT) == S_IFREG else { return nil }
                return child.lastPathComponent
            }
            .sorted(by: compare)
            .prefix(maximumFilesPerFolder)

            return FolderProfile(url: folder, fileNames: Array(names))
        }
    }

    private static func compare(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}

/// Conservative, deterministic matching for destinations the user already has.
/// It deliberately returns no result whenever equally good folder evidence exists.
public enum ExistingFolderPlanner {
    private enum MatchKind: Int {
        case genericMedia = 70
        case projectName = 90
        case drxCollection = 95
        case sidecarReference = 100
    }

    private struct Candidate {
        let profile: FolderProfile
        let kind: MatchKind
    }

    private static let sidecarExtensions: Set<String> = [
        "aae", "drx", "lrv", "srt", "thm", "xmp", "xml", "json", "dop", "pp3", "sidecar"
    ]
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "heic", "png", "gif", "tif", "tiff", "webp", "raw", "dng"]
    private static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "webm"]
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "flac", "ogg"]
    private static let genericFolders: [String: Set<String>] = [
        "video": videoExtensions,
        "videos": videoExtensions,
        "film": videoExtensions,
        "filme": videoExtensions,
        "audio": audioExtensions,
        "musik": audioExtensions,
        "music": audioExtensions,
        "foto": imageExtensions,
        "fotos": imageExtensions,
        "photo": imageExtensions,
        "photos": imageExtensions,
        "bild": imageExtensions,
        "bilder": imageExtensions,
        "images": imageExtensions
    ]

    public static func match(file: FileSnapshot, evidence: AnalysisEvidence, profiles: [FolderProfile]) -> Recommendation? {
        guard !file.isProtected, !file.isDirectory else { return nil }
        var seenTargets = Set<URL>()
        let safeProfiles = profiles.filter { profile in
            seenTargets.insert(profile.url).inserted && isSafeTarget(profile)
        }
        guard !safeProfiles.isEmpty else { return nil }

        let parent = file.url.deletingLastPathComponent().standardizedFileURL
        let candidates = safeProfiles.compactMap { profile -> Candidate? in
            guard profile.url != parent else { return nil }
            if matchesSidecar(file, profile) { return Candidate(profile: profile, kind: .sidecarReference) }
            if matchesDRXCollection(file, profile) { return Candidate(profile: profile, kind: .drxCollection) }
            if matchesDistinctiveName(file, evidence, profile) { return Candidate(profile: profile, kind: .projectName) }
            if matchesGenericMedia(file, profile) { return Candidate(profile: profile, kind: .genericMedia) }
            return nil
        }

        guard let best = candidates.map(\.kind.rawValue).max() else { return nil }
        let winners = candidates.filter { $0.kind.rawValue == best }
        guard winners.count == 1, let winner = winners.first else { return nil }

        let confidence: Double = winner.kind == .sidecarReference ? 0.99 : winner.kind == .drxCollection ? 0.94 : winner.kind == .projectName ? 0.95 : 0.91
        let reason: String
        switch winner.kind {
        case .sidecarReference: reason = "Dateiname passt zu einer vorhandenen Referenzdatei."
        case .drxCollection: reason = "Gehört zur vorhandenen DaVinci-Still-Serie."
        case .projectName: reason = "Projektname passt zu Dateiname oder erkannten Text."
        case .genericMedia: reason = "Dateityp passt zum vorhandenen Medienordner."
        }
        return Recommendation(file: file, targetFolder: winner.profile.url, importance: .open,
                              confidence: confidence, margin: confidence, reason: reason,
                              evidence: AnalysisEvidence(summary: evidence.summary, extractedText: evidence.extractedText,
                                                         sufficient: true, origin: evidence.origin, imageData: evidence.imageData),
                              needsQuestion: false)
    }

    private static func isSafeTarget(_ profile: FolderProfile) -> Bool {
        guard !profile.url.lastPathComponent.hasPrefix(".") else { return false }
        guard (try? FileSafety.validatePath(profile.url, within: profile.url)) != nil,
              let snapshot = try? FileSafety.snapshot(profile.url) else { return false }
        return snapshot.isDirectory && !snapshot.isProtected
    }

    private static func matchesSidecar(_ file: FileSnapshot, _ profile: FolderProfile) -> Bool {
        let ext = file.url.pathExtension.lowercased()
        guard sidecarExtensions.contains(ext) else { return false }
        let stem = normalized(file.url.deletingPathExtension().lastPathComponent)
        guard isNontrivialStem(stem) else { return false }
        return profile.fileNames.contains { reference in
            let referenceStem = normalized(URL(fileURLWithPath: reference).deletingPathExtension().lastPathComponent)
            guard referenceStem == stem else { return false }
            // DaVinci Resolve .drx files are only anchored by the corresponding
            // PNG; other sidecars may accompany any regular media/document file.
            return ext != "drx" || URL(fileURLWithPath: reference).pathExtension.lowercased() == "png"
        }
    }

    private static func matchesDRXCollection(_ file: FileSnapshot, _ profile: FolderProfile) -> Bool {
        guard file.url.pathExtension.lowercased() == "drx",
              let prefix = drxStillPrefix(file.url.deletingPathExtension().lastPathComponent) else { return false }
        let referenceCount = profile.fileNames.reduce(into: 0) { count, reference in
            guard URL(fileURLWithPath: reference).pathExtension.lowercased() == "png",
                  let referencePrefix = drxStillPrefix(URL(fileURLWithPath: reference).deletingPathExtension().lastPathComponent),
                  referencePrefix == prefix else { return }
            count += 1
        }
        return referenceCount >= 3
    }

    /// DaVinci still exports have a stable, narrow shape. Keeping the whole
    /// expression anchored prevents ordinary date-bearing project files from
    /// gaining collection-based routing.
    private static func drxStillPrefix(_ name: String) -> String? {
        let pattern = #"^Still ([0-9]{4}-[0-9]{2}-[0-9]{2}) [0-9]+_[0-9]+\.[0-9]+$"#
        guard let range = name.range(of: pattern, options: .regularExpression) else { return nil }
        let match = String(name[range])
        return String(match.prefix(16)) // "Still YYYY-MM-DD"
    }

    private static func matchesDistinctiveName(_ file: FileSnapshot, _ evidence: AnalysisEvidence, _ profile: FolderProfile) -> Bool {
        let folderTokens = tokens(profile.url.lastPathComponent)
        let folderKey = folderTokens.joined()
        guard folderTokens.count > 0, folderKey.count >= 6, genericFolders[folderKey] == nil else { return false }
        let candidateText = [file.url.deletingPathExtension().lastPathComponent, evidence.summary, evidence.extractedText]
        return candidateText.contains { containsWholePhrase(folderTokens, in: tokens($0)) }
    }

    private static func matchesGenericMedia(_ file: FileSnapshot, _ profile: FolderProfile) -> Bool {
        let ext = file.url.pathExtension.lowercased()
        let folder = normalized(profile.url.lastPathComponent)
        guard let acceptedExtensions = genericFolders[folder], acceptedExtensions.contains(ext) else { return false }
        // Screenshots need affirmative project evidence; their type alone is too weak.
        let name = normalized(file.url.deletingPathExtension().lastPathComponent)
        return !name.contains("screenshot") && !name.contains("bildschirmfoto") &&
            !name.contains("screen") && !name.contains("xnapper")
    }

    private static func isNontrivialStem(_ stem: String) -> Bool {
        stem.count >= 6 && (stem.allSatisfy(\.isNumber) || stem.rangeOfCharacter(from: .decimalDigits) != nil || stem.count >= 8)
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined().lowercased()
    }

    private static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map { $0.lowercased() }
    }

    private static func containsWholePhrase(_ phrase: [String], in words: [String]) -> Bool {
        guard !phrase.isEmpty, !words.isEmpty else { return false }
        let phraseKey = phrase.joined()
        for start in words.indices {
            var joined = ""
            for end in start..<words.count {
                joined += words[end]
                if joined == phraseKey { return true }
                if joined.count > phraseKey.count { break }
            }
        }
        return false
    }
}
