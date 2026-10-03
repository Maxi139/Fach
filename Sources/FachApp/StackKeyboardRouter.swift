import AppKit
import SwiftUI

/// Quick Look can focus its own document view. Route the deck's four keys in
/// this window only; editable fields and an open folder sheet keep their keys.
struct StackKeyboardRouter: NSViewRepresentable {
    let enabled: Bool
    let handle: (NSEvent) -> Bool

    func makeNSView(context: Context) -> CaptureView {
        CaptureView()
    }
    func updateNSView(_ view: CaptureView, context: Context) {
        view.enabled = enabled
        view.handle = handle
    }
    static func dismantleNSView(_ view: CaptureView, coordinator: ()) {
        view.stop()
    }

    final class CaptureView: NSView {
        var enabled = false
        var handle: ((NSEvent) -> Bool)?
        private var monitor: Any?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.enabled, let window = self.window, NSApp.keyWindow === window,
                      event.window === window else { return event }
                if let editor = window.firstResponder as? NSTextView, editor.isEditable { return event }
                return self.handle?(event) == true ? nil : event
            }
        }
        required init?(coder: NSCoder) { nil }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil; handle = nil
        }
        isolated deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
