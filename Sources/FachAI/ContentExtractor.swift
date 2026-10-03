import Foundation
import FachCore
import PDFKit
import Vision
import ImageIO
import UniformTypeIdentifiers

public enum ContentExtractor {
    public static func extract(_ file: FileSnapshot) async throws -> AnalysisEvidence {
        try await Task.detached(priority: .utility) {
            guard !file.isDirectory, !file.isProtected else { return AnalysisEvidence(summary: file.name) }
            let ext = file.url.pathExtension.lowercased()
            try SecureFile.validate(file)
            if ext == "pdf" {
                guard file.size <= 32 * 1024 * 1024 else { return AnalysisEvidence(summary: "Großes PDF. Inhaltsanalyse übersprungen.") }
                let data = try SecureFile.read(file, limit: 32 * 1024 * 1024)
                guard let document = PDFDocument(data: data) else { return AnalysisEvidence(summary: "PDF konnte nicht gelesen werden.") }
                var text = ""
                for index in 0..<min(document.pageCount, 8) {
                    text += document.page(at: index)?.string ?? ""
                    if text.count > 12000 { break }
                }
                text = String(text.prefix(12000))
                return AnalysisEvidence(summary: String(text.prefix(500)), extractedText: text, sufficient: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, origin: "PDF-Text")
            }
            if UTType(filenameExtension: ext)?.conforms(to: .image) == true {
                guard file.size <= 32 * 1024 * 1024 else { return AnalysisEvidence(summary: "Großes Bild. Inhaltsanalyse übersprungen.") }
                let data = try SecureFile.read(file, limit: 32 * 1024 * 1024)
                guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1024, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return AnalysisEvidence(summary: "Bild konnte nicht gelesen werden.") }
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return AnalysisEvidence(summary: file.name) }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { return AnalysisEvidence(summary: file.name) }
                let recognition = VNRecognizeTextRequest(); recognition.recognitionLevel = .accurate
                try? VNImageRequestHandler(cgImage: image).perform([recognition])
                let text = String((recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n").prefix(8000))
                return AnalysisEvidence(summary: text.isEmpty ? "Bild ohne lesbaren Text" : String(text.prefix(500)), extractedText: text, sufficient: !text.isEmpty, origin: "Bild und Texterkennung", imageData: output as Data)
            }
            let textExtensions: Set<String> = ["txt", "md", "csv", "json", "xml", "html", "log", "rtf", "yaml", "yml", "swift", "py", "js", "ts", "css"]
            if textExtensions.contains(ext) {
                let data = try SecureFile.read(file, limit: 16000)
                let text = String(decoding: data, as: UTF8.self)
                return AnalysisEvidence(summary: String(text.prefix(500)), extractedText: text, sufficient: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, origin: "Textauszug")
            }
            return AnalysisEvidence(summary: "\(file.name) (\(ext.isEmpty ? "unbekannter Dateityp" : ext))")
        }.value
    }
}
