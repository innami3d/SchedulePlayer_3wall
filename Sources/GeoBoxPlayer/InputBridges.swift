import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct KeyEventBridge: NSViewRepresentable {
    let store: PlayerStore
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(view: view, store: store)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.remove() }
    @MainActor final class Coordinator {
        var monitor: Any?
        func install(view: NSView, store: PlayerStore) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view, weak store] event in
                guard let view, let store, event.window === view.window,
                      !(event.window?.firstResponder is NSTextView), !store.locked else { return event }
                let command = event.modifierFlags.contains(.command)
                if !command && [51, 117].contains(Int(event.keyCode)) { store.deleteSelection(); return nil }
                guard command else { return event }
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "c": store.copySelection()
                case "x": store.copySelection(cut: true)
                case "v": store.paste()
                case "d": store.duplicate()
                default: return event
                }
                return nil
            }
        }
        func remove() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }
}

/// Observes secondary clicks without consuming the event SwiftUI uses to open its native NSMenu.
struct ContextSelectionObserver: NSViewRepresentable {
    let select: () -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView(); context.coordinator.view = view; context.coordinator.select = select
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak coordinator = context.coordinator] event in
            guard let coordinator, let view = coordinator.view, event.window === view.window,
                  event.type == .rightMouseDown || event.modifierFlags.contains(.control),
                  view.bounds.contains(view.convert(event.locationInWindow, from: nil)) else { return event }
            coordinator.select?(); return event
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.select = select }
    func makeCoordinator() -> Coordinator { Coordinator() }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }; coordinator.monitor = nil
    }
    @MainActor final class Coordinator { weak var view: NSView?; var select: (() -> Void)?; var monitor: Any? }
}

struct TrackDropDelegate: DropDelegate {
    let store: PlayerStore
    let before: UUID?
    @Binding var targeted: UUID?
    func validateDrop(info: DropInfo) -> Bool { !store.locked }
    func dropEntered(info: DropInfo) { if !store.locked { targeted = before } }
    func dropExited(info: DropInfo) { if targeted == before { targeted = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: info.hasItemsConforming(to: [.fileURL]) ? .copy : .move)
    }
    func performDrop(info: DropInfo) -> Bool {
        targeted = nil; guard !store.locked else { return false }
        receiveDrop(info.itemProviders(for: [.fileURL, .utf8PlainText]), store: store, before: before); return true
    }
}

@MainActor
func receiveDrop(_ providers: [NSItemProvider], store: PlayerStore, before target: UUID?) {
    guard !store.locked else { return }
    let playlistID = store.selectedPlaylistID
    Task { @MainActor in
        var urls: [URL] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                        if let url = value as? URL { continuation.resume(returning: url) }
                        else if let data = value as? Data { continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil)) }
                        else { continuation.resume(returning: nil) }
                    }
                }
                if let url { urls.append(url) }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier) {
                let id: UUID? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.utf8PlainText.identifier, options: nil) { value, _ in
                        let text = (value as? String) ?? (value as? Data).flatMap { String(data: $0, encoding: .utf8) }
                        continuation.resume(returning: text.flatMap(UUID.init(uuidString:)))
                    }
                }
                guard !store.locked, store.selectedPlaylistID == playlistID else { return }
                if let id { store.moveTrack(id, before: target) }
            }
        }
        guard !store.locked, store.selectedPlaylistID == playlistID else { return }
        if !urls.isEmpty {
            let at = target.flatMap { id in store.selectedPlaylist?.tracks.firstIndex { $0.id == id } }
            store.addFiles(urls, at: at)
        }
    }
}
