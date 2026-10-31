import SwiftUI
import AppKit

@main
struct GeoBoxPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = PlayerStore()
    var body: some Scene {
        WindowGroup("GeoBox Player") {
            WorkspaceView(store: store, engine: store.engine, library: store.library)
                .frame(minWidth: 1000, minHeight: 700)
                .onAppear { delegate.store = store }
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
    weak var store: PlayerStore?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        if !store.confirmDiscard() { return .terminateCancel }
        store.engine.stopImmediately(); return .terminateNow
    }
}
