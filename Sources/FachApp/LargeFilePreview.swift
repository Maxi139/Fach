import AppKit
import QuickLookUI
import SwiftUI

/// A read-only, embedded Quick Look preview for the focused file in the sorting deck.
struct LargeFilePreview: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor

        guard let preview = QLPreviewView(frame: .zero, style: .normal) else {
            addFallbackIcon(to: container)
            return container
        }
        preview.shouldCloseWithWindow = false
        preview.autostarts = false
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.previewItem = url as NSURL

        container.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            preview.topAnchor.constraint(equalTo: container.topAnchor),
            preview.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        context.coordinator.preview = preview
        context.coordinator.cachedURL = url
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard context.coordinator.cachedURL != url else { return }
        context.coordinator.cachedURL = url
        context.coordinator.preview?.previewItem = url as NSURL
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.preview?.close()
        coordinator.preview = nil
        coordinator.cachedURL = nil
    }

    final class Coordinator {
        var preview: QLPreviewView?
        var cachedURL: URL?
    }

    private func addFallbackIcon(to container: NSView) {
        let imageView = NSImageView(image: NSImage(systemSymbolName: "doc", accessibilityDescription: nil) ?? NSImage())
        imageView.symbolConfiguration = .init(pointSize: 72, weight: .regular)
        imageView.contentTintColor = .secondaryLabelColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
    }
}
