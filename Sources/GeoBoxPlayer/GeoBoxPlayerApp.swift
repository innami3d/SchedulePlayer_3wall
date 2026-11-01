import SwiftUI
import AppKit

@main
struct GeoBoxPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = PlayerStore()
    var body: some Scene {
        Window("GeoBox Player", id: "workspace") {
            WorkspaceView(store: store, engine: store.engine, library: store.library)
                .frame(minWidth: 1000, minHeight: 700)
                .onAppear { delegate.store = store }
                .background(ControlWindowReader { window in delegate.attachControlWindow(window, store: store) }.allowsHitTesting(false))
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新規プロジェクト") { store.newProject() }.keyboardShortcut("n").disabled(store.locked)
                Button("プロジェクトを開く…") { store.openProject() }.keyboardShortcut("o").disabled(store.locked)
            }
            CommandGroup(replacing: .saveItem) {
                Button("保存") { store.save() }.keyboardShortcut("s").disabled(store.locked)
                Button("名前を付けて保存…") { store.save(as: true) }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(store.locked)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("取り消す") { store.undo() }.keyboardShortcut("z").disabled(store.locked || store.undoStack.isEmpty)
                Button("やり直す") { store.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(store.locked)
            }
            CommandMenu("再生") {
                Button("出力開始") { store.engine.startProject() }.disabled(store.locked)
                Button("出力終了") { store.engine.endProject() }.disabled(store.locked)
                Divider()
                Button(store.locked ? "画面ロックを解除" : "画面をロック") { store.locked.toggle() }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: PlayerStore? {
        didSet { if let pendingURL, let store { self.pendingURL = nil; store.openProject(at: pendingURL) } }
    }
    private var pendingURL: URL?
    private var terminationInProgress = false
    private let controlWindow = ControlWindowCoordinator { NSApp.terminate(nil) }
    func attachControlWindow(_ window: NSWindow, store: PlayerStore) {
        self.store = store
        controlWindow.attach(window, engine: store.engine)
    }
    func applicationDidHide(_ notification: Notification) {
        if store?.engine.hasVideoOutput == true { _ = store?.engine.ensureControlWindowVisible() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if store?.engine.hasVideoOutput == true { _ = store?.engine.ensureControlWindowVisible() }
        return true
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        guard let path = filenames.first else { sender.reply(toOpenOrPrint: .failure); return }
        let url = URL(fileURLWithPath: path)
        if let store { store.openProject(at: url) } else { pendingURL = url }
        sender.reply(toOpenOrPrint: .success)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        if terminationInProgress { return .terminateLater }
        if !store.confirmDiscard() { return .terminateCancel }
        if store.engine.outputIsActive {
            terminationInProgress = true
            Task { @MainActor in await store.engine.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
        store.engine.controlWindowDidClose(); return .terminateNow
    }
}
