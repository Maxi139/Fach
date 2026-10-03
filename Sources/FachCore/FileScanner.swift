import Foundation
import Darwin

enum FileSafety {
    static let protectedExtensions: Set<String> = ["app", "bundle", "framework", "plugin", "photoslibrary", "photolibrary", "musiclibrary", "xcodeproj", "xcworkspace", "playground", "pages", "numbers", "key"]
    static func protectedDirectory(_ url: URL) -> Bool {
        protectedExtensions.contains(url.pathExtension.lowercased()) ||
        [".git", ".svn", "node_modules"].contains(url.lastPathComponent) ||
        FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) ||
        FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) ||
        FileManager.default.fileExists(atPath: url.appendingPathComponent("package.json").path)
    }
    static func stat(_ url: URL) throws -> stat {
        var info = Darwin.stat()
        guard lstat(url.path, &info) == 0 else { throw FachError.message("„\(url.lastPathComponent)“ ist nicht erreichbar.") }
        return info
    }
    static func isLink(_ info: stat) -> Bool { (info.st_mode & S_IFMT) == S_IFLNK }
    static func isDirectory(_ info: stat) -> Bool { (info.st_mode & S_IFMT) == S_IFDIR }
    static func exists(_ url: URL) -> Bool { (try? stat(url)) != nil }
    static func snapshot(_ url: URL) throws -> FileSnapshot {
        let info = try stat(url)
        return FileSnapshot(url: url, size: info.st_size,
                            modifiedAt: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000),
                            resourceID: "\(info.st_dev):\(info.st_ino)", changedAt: Date(timeIntervalSince1970: Double(info.st_ctimespec.tv_sec) + Double(info.st_ctimespec.tv_nsec) / 1_000_000_000), isDirectory: isDirectory(info),
                            isProtected: isLink(info) || (isDirectory(info) && protectedDirectory(url)))
    }
    static func placeholder(_ url: URL) -> Bool {
        if url.lastPathComponent.hasPrefix(".") && url.pathExtension == "icloud" { return true }
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]) else { return false }
        return values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus == .notDownloaded
    }
    static func validatePath(_ url: URL, within root: URL, allowMissingLeaf: Bool = false) throws {
        let path = url.standardizedFileURL
        let base = root.standardizedFileURL
        guard !url.pathComponents.contains(".."), !url.pathComponents.contains("."),
              !root.pathComponents.contains(".."), !root.pathComponents.contains(".") else {
            throw FachError.message("Dateipfad muss eindeutig sein. Bitte Ordner erneut wählen.")
        }
        guard path.isFileURL, base.isFileURL, path.path == base.path || path.path.hasPrefix(base.path + "/") else {
            throw FachError.message("Dateipfad liegt außerhalb des gewählten Ordners.")
        }
        // Inspect every ancestor, including ancestors of the selected root. A bookmark
        // does not make a symlink a safe destination for a later write.
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in path.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            guard let info = try? stat(current) else {
                if allowMissingLeaf && current.standardizedFileURL.path == path.path { return }
                throw FachError.message("„\(current.lastPathComponent)“ ist nicht erreichbar.")
            }
            if isLink(info) {
                // macOS supplies these immutable system aliases for temporary paths.
                // Do not generalize this exception to user-controlled symlinks.
                let systemAliases = ["/var": "private/var", "/tmp": "private/tmp", "/etc": "private/etc"]
                let link = try FileManager.default.destinationOfSymbolicLink(atPath: current.path)
                guard let expected = systemAliases[current.path], link == expected || link == "/" + expected else {
                    throw FachError.message("Verknüpfungen werden nicht verändert.")
                }
            }
            if current.path != base.path && current.path.hasPrefix(base.path + "/") && isDirectory(info) && protectedDirectory(current) {
                throw FachError.message("Projekt oder Bibliothek ist geschützt.")
            }
        }
        guard !protectedDirectory(base) else { throw FachError.message("Projekt oder Bibliothek ist geschützt.") }
    }
}

public actor FileScanner {
    public init() {}
    public func scan(root: URL, recursive: Bool) throws -> ScanResult {
        let root = root.standardizedFileURL
        try FileSafety.validatePath(root, within: root)
        guard FileSafety.isDirectory(try FileSafety.stat(root)) else { throw FachError.message("Bitte einen Ordner wählen.") }
        var files: [FileSnapshot] = [], folders: [URL] = [], warnings: [String] = []
        var pending = [root]
        while let folder = pending.popLast() {
            let children: [URL]
            do { children = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: []) }
            catch { warnings.append("„\(folder.lastPathComponent)“ konnte nicht gelesen werden."); continue }
            for child in children.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                if FileSafety.placeholder(child) { warnings.append("„\(child.lastPathComponent)“ ist noch nicht heruntergeladen."); continue }
                do {
                    let info = try FileSafety.stat(child)
                    if FileSafety.isLink(info) { warnings.append("„\(child.lastPathComponent)“ ist eine Verknüpfung und bleibt unverändert."); continue }
                    if child.lastPathComponent.hasPrefix(".") { continue }
                    if FileSafety.isDirectory(info) {
                        if FileSafety.protectedDirectory(child) { warnings.append("„\(child.lastPathComponent)“ ist geschützt."); continue }
                        folders.append(child)
                        if recursive { pending.append(child) }
                    } else if (info.st_mode & S_IFMT) == S_IFREG {
                        files.append(try FileSafety.snapshot(child))
                    }
                } catch { warnings.append("„\(child.lastPathComponent)“ konnte nicht gelesen werden.") }
            }
        }
        return ScanResult(files: files, folders: folders, warnings: warnings)
    }
}
