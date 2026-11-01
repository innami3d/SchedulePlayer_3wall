import AppKit
import SwiftUI

/// Reports the actual SwiftUI control window without searching among output or dialog windows.
struct ControlWindowReader: NSViewRepresentable {
    var attach: (NSWindow) -> Void
    func makeNSView(context: Context) -> WindowView { WindowView(attach: attach) }
    func updateNSView(_ view: WindowView, context: Context) {
        view.attach = attach
        if let window = view.window { attach(window) }
    }
    final class WindowView: NSView {
        var attach: (NSWindow) -> Void
        init(attach: @escaping (NSWindow) -> Void) { self.attach = attach; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { attach(window) }
        }
    }
}

@MainActor
final class ControlWindowCoordinator: NSObject, NSWindowDelegate {
    private weak var window: NSWindow?
    private weak var originalDelegate: NSWindowDelegate?
    private weak var engine: PlaybackEngine?
    private let requestTermination: () -> Void
    private var didClose = false
    init(requestTermination: @escaping () -> Void) { self.requestTermination = requestTermination }
    func attach(_ window: NSWindow, engine: PlaybackEngine) {
        if self.window === window {
            guard !didClose else { return }
            if window.delegate !== self { originalDelegate = window.delegate; window.delegate = self }
            return
        }
        didClose = false
        self.window = window; self.engine = engine
        originalDelegate = window.delegate
        window.delegate = self
        engine.attachControlWindow(window)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Keep the controls visible through save confirmation and any output fade-out.
        requestTermination()
        return false
    }
    func windowWillClose(_ notification: Notification) {
        // Also cover direct close() calls, which bypass windowShouldClose.
        didClose = true
        engine?.controlWindowDidClose()
        originalDelegate?.windowWillClose?(notification)
    }
    func windowDidMiniaturize(_ notification: Notification) {
        originalDelegate?.windowDidMiniaturize?(notification)
        if engine?.hasVideoOutput == true { _ = engine?.ensureControlWindowVisible() }
    }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        originalDelegate?.windowDidChangeOcclusionState?(notification)
        if engine?.hasVideoOutput == true, window?.isVisible == false { _ = engine?.ensureControlWindowVisible() }
    }
    // Preserve the rest of SwiftUI's native window handling.
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || originalDelegate?.responds(to: selector) == true
    }
    override func forwardingTarget(for selector: Selector!) -> Any? {
        if originalDelegate?.responds(to: selector) == true { return originalDelegate }
        return super.forwardingTarget(for: selector)
    }
}
