import Foundation
import Darwin
import FachCore

/// Reads from a verified no-follow descriptor with checked ancestors and parent identity.
enum SecureFile {
    static func openChecked(_ snapshot: FileSnapshot) throws -> Int32 {
        try Task.checkCancellation()
        guard snapshot.url.isFileURL, !snapshot.isDirectory, !snapshot.isProtected, let identity = snapshot.resourceID else { throw FachError.message("Datei bitte erneut einlesen.") }
        var path = snapshot.url.standardizedFileURL.path
        // Fixed macOS aliases only; all user-controlled links remain forbidden.
        for (alias, actual) in [("/var", "/private/var"), ("/tmp", "/private/tmp"), ("/etc", "/private/etc")] {
            if path == alias || path.hasPrefix(alias + "/") { path = actual + path.dropFirst(alias.count); break }
        }
        let components = path.split(separator: "/").map(String.init)
        guard let leaf = components.last, !components.contains("..") else { throw FachError.message("Dateipfad konnte nicht geprüft werden.") }
        // Sandbox bookmarks grant the selected folder, not read access to every
        // ancestor. Validate ancestors without enumerating them, then anchor the
        // actual read to the authorized parent descriptor.
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in components.dropLast() {
            current.appendPathComponent(component)
            var ancestor = Darwin.stat()
            guard lstat(current.path, &ancestor) == 0, ancestor.st_mode & S_IFMT == S_IFDIR else {
                throw FachError.message("Dateipfad wurde geändert oder enthält Verknüpfungen. Ordner erneut einlesen.")
            }
        }
        var parentInfo = Darwin.stat()
        guard lstat(current.path, &parentInfo) == 0 else { throw FachError.message("Datei ist nicht erreichbar.") }
        let directory = Darwin.open(current.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw FachError.message("Datei ist nicht erreichbar. Ordner erneut einlesen.") }
        var openedParent = Darwin.stat()
        guard fstat(directory, &openedParent) == 0, parentInfo.st_dev == openedParent.st_dev, parentInfo.st_ino == openedParent.st_ino else {
            close(directory)
            throw FachError.message("Dateipfad wurde geändert. Ordner erneut einlesen.")
        }
        let descriptor = openat(directory, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        close(directory)
        guard descriptor >= 0 else { throw FachError.message("Datei wurde geändert oder ist nicht erreichbar. Ordner erneut einlesen.") }
        do {
            var info = Darwin.stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  "\(info.st_dev):\(info.st_ino)" == identity,
                  info.st_size == snapshot.size, modified(info) == snapshot.modifiedAt, snapshot.changedAt == nil || changed(info) == snapshot.changedAt else {
                throw FachError.message("Datei wurde seit dem Einlesen geändert. Ordner erneut einlesen.")
            }
            return descriptor
        } catch { close(descriptor); throw error }
    }
    static func changed(_ info: Darwin.stat) -> Date { Date(timeIntervalSince1970: Double(info.st_ctimespec.tv_sec) + Double(info.st_ctimespec.tv_nsec) / 1_000_000_000) }
    static func modified(_ info: Darwin.stat) -> Date { Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000) }
    static func validate(_ snapshot: FileSnapshot) throws { let descriptor = try openChecked(snapshot); close(descriptor) }
    static func read(_ snapshot: FileSnapshot, limit: Int) throws -> Data {
        let descriptor = try openChecked(snapshot); defer { close(descriptor) }
        var result = Data(); var buffer = [UInt8](repeating: 0, count: min(max(limit, 1), 65536))
        while result.count < limit {
            try Task.checkCancellation()
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, limit - result.count))
            guard count >= 0 else { throw FachError.message("Datei konnte nicht gelesen werden.") }
            if count == 0 { break }; result.append(contentsOf: buffer.prefix(count))
        }
        var info = Darwin.stat()
        guard fstat(descriptor, &info) == 0, "\(info.st_dev):\(info.st_ino)" == snapshot.resourceID,
              info.st_size == snapshot.size, modified(info) == snapshot.modifiedAt, snapshot.changedAt == nil || changed(info) == snapshot.changedAt else { throw FachError.message("Datei wurde während der Analyse geändert. Ordner erneut einlesen.") }
        // Ensure the current path still identifies the same descriptor's file.
        try validate(snapshot)
        return result
    }
}
