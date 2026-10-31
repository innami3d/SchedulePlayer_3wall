import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PlayerCore

@MainActor
final class PlayerStore: ObservableObject {
    @Published var project = PlayerProject()
    @Published var fileURL: URL?
    @Published var isDirty = false
    @Published var locked = false
    @Published var selectedPlaylistID: UUID?
    @Published var selectedTrackID: UUID?
    @Published var showingProject = true
    @Published var message = "プロジェクト設定で出力先を選択してください。"
    @Published var error: String?
    @Published private(set) var undoStack: [PlayerProject] = []
    private var redoStack: [PlayerProject] = []
    private var clipboard: ClipboardItem?
    var selection: Selection = .playlist
    let library = MediaLibrary()
    let devices = OutputDevices()
    lazy var engine = PlaybackEngine(store: self)
    var directory: URL? { fileURL?.deletingLastPathComponent() }
    var selectedPlaylist: Playlist? { project.playlist(selectedPlaylistID) }
    var selectedTrack: MediaTrack? { selectedPlaylist?.tracks.first { $0.id == selectedTrackID } }
    enum Selection { case playlist, track }
    enum ClipboardItem { case playlist(Playlist), track(MediaTrack, MediaLane) }
    var hasItemSelection: Bool { selection == .track ? selectedTrack != nil : selectedPlaylist != nil }
    private let recentProjectKey = "GeoBoxPlayer.lastProjectPath"
    private let remembersProject: Bool

    init(restoreLastProject: Bool = true) {
        remembersProject = restoreLastProject
        if restoreLastProject, let path = UserDefaults.standard.string(forKey: recentProjectKey) {
            let url = URL(fileURLWithPath: path)
            do { project = try PlayerProject.decode(Data(contentsOf: url)); fileURL = url }
            catch { message = "前回のプロジェクトを開けませんでした：\(error.localizedDescription)" }
        }
    }

    var selectedDisplay: OutputDevices.Display? {
        OutputDevices.matchingDisplay(id: project.displayID, uuid: project.displayUUID, in: devices.displays)
    }
    func selectDisplay(_ id: UInt32?) {
        let display = devices.displays.first { $0.id == id }
        change {
            $0.displayID = id; $0.displayUUID = display?.uuid; $0.displayName = display?.name
        }
    }
    func selectAudioDevice(_ uid: String?) {
        let device = devices.audio.first { $0.id == uid }
        change { $0.audioDeviceUID = uid; $0.audioDeviceName = device?.name }
    }
    func rememberDeviceIdentities() {
        // Upgrade older projects when their previously selected device is available.
        if project.displayUUID == nil, let display = selectedDisplay, let uuid = display.uuid {
            project.displayUUID = uuid; project.displayName = display.name; isDirty = true
        }
        if project.audioDeviceName == nil,
           let device = devices.audio.first(where: { $0.id == project.audioDeviceUID }) {
            project.audioDeviceName = device.name; isDirty = true
        }
    }

    func change(_ edit: (inout PlayerProject) -> Void) {
        guard !locked else { return }
        let old = project; var next = old; edit(&next)
        guard next != old else { return }
        undoStack.append(old); if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll(); project = next; isDirty = true
    }
    func undo() {
        guard !locked, let prior = undoStack.popLast() else { return }
        redoStack.append(project); project = prior; isDirty = true; prepareMedia()
    }
    func redo() {
        guard !locked, let next = redoStack.popLast() else { return }
        undoStack.append(project); project = next; isDirty = true; prepareMedia()
    }
    func playlistBinding<T>(_ keyPath: WritableKeyPath<Playlist, T>, fallback: T) -> Binding<T> {
        Binding(get: { self.selectedPlaylist?[keyPath: keyPath] ?? fallback }, set: { value in
            guard let id = self.selectedPlaylistID else { return }
            self.change { project in
                guard let index = project.playlists.firstIndex(where: { $0.id == id }) else { return }
                project.playlists[index][keyPath: keyPath] = value
            }
        })
    }
    func trackBinding<T>(_ keyPath: WritableKeyPath<MediaTrack, T>, fallback: T) -> Binding<T> {
        Binding(get: { self.selectedTrack?[keyPath: keyPath] ?? fallback }, set: { value in
            guard let p = self.selectedPlaylistID, let t = self.selectedTrackID else { return }
            self.change { project in
                guard let i = project.playlists.firstIndex(where: { $0.id == p }),
                      let j = project.playlists[i].tracks.firstIndex(where: { $0.id == t }) else { return }
                project.playlists[i].tracks[j][keyPath: keyPath] = value
            }
            self.prepareMedia()
        })
    }
    func selectPlaylist(_ id: UUID) {
        selectedPlaylistID = id; selectedTrackID = nil; selection = .playlist; showingProject = false
    }
    func selectTrack(_ id: UUID) { selectedTrackID = id; selection = .track }
    func createPlaylist(_ lane: MediaLane) {
        guard !locked else { return }
        let p = Playlist(name: "新規\(lane.title)プレイリスト", lane: lane, order: project.nextOrder, defaults: project.defaults)
        change { project in
            project.playlists.append(p)
            if lane == .video && project.video.initialPlaylistID == nil { project.video.initialPlaylistID = p.id }
            if lane == .audio && project.audio.initialPlaylistID == nil { project.audio.initialPlaylistID = p.id }
        }
        selectPlaylist(p.id)
    }
    func setPlaylistTime(_ value: TimeOfDay) {
        guard let id = selectedPlaylistID else { return }
        change { project in
            let order = project.nextOrder
            if let i = project.playlists.firstIndex(where: { $0.id == id }) {
                project.playlists[i].start = value; project.playlists[i].scheduleOrder = order
            }
        }
    }
    func addFiles(_ urls: [URL], at insertion: Int? = nil) {
        guard !locked, let p = selectedPlaylist else { return }
        var rejected: [String] = []
        let tracks = urls.compactMap { url -> MediaTrack? in
            guard url.isFileURL, let kind = MediaKind.identify(url), kind.accepts(p.lane) else {
                rejected.append(url.lastPathComponent); return nil
            }
            return MediaTrack(path: url.standardizedFileURL.path, kind: kind, volume: project.defaults.volume,
                              imageDuration: project.defaults.imageDuration)
        }
        change { project in
            guard let i = project.playlists.firstIndex(where: { $0.id == p.id }) else { return }
            let at = min(project.playlists[i].tracks.count, max(0, insertion ?? project.playlists[i].tracks.count))
            project.playlists[i].tracks.insert(contentsOf: tracks, at: at)
        }
        if let first = tracks.first { selectTrack(first.id) }
        message = "\(tracks.count)件のファイルを追加しました。"
        if !rejected.isEmpty { error = "追加できないファイル：\n" + rejected.joined(separator: "\n") }
        prepareMedia()
    }
    func moveTrack(_ id: UUID, before target: UUID?) {
        guard !locked, let p = selectedPlaylistID else { return }
        change { project in
            guard let i = project.playlists.firstIndex(where: { $0.id == p }),
                  let from = project.playlists[i].tracks.firstIndex(where: { $0.id == id }), id != target else { return }
            let item = project.playlists[i].tracks.remove(at: from)
            let to = target.flatMap { target in project.playlists[i].tracks.firstIndex { $0.id == target } } ?? project.playlists[i].tracks.count
            project.playlists[i].tracks.insert(item, at: to)
        }
    }
    func deleteSelection() {
        guard !locked, hasItemSelection else { return }
        if selection == .track, let p = selectedPlaylistID, let t = selectedTrackID {
            change { project in
                if let i = project.playlists.firstIndex(where: { $0.id == p }) { project.playlists[i].tracks.removeAll { $0.id == t } }
            }; selectedTrackID = nil
        } else if let p = selectedPlaylistID {
            change { $0.playlists.removeAll { $0.id == p } }; selectedPlaylistID = nil; showingProject = true
        }
        prepareMedia()
    }
    private func absolute(_ track: MediaTrack) -> MediaTrack {
        var t = track; t.path = track.resolvedURL(relativeTo: directory).path; return t
    }
    func copySelection(cut: Bool = false) {
        guard !locked, hasItemSelection else { return }
        if selection == .track, let t = selectedTrack, let p = selectedPlaylist {
            clipboard = .track(absolute(t), p.lane)
        } else if var p = selectedPlaylist {
            p.tracks = p.tracks.map(absolute); clipboard = .playlist(p)
        } else { return }
        if cut { deleteSelection() }
    }
    var canPaste: Bool {
        guard !locked, let clipboard else { return false }
        switch clipboard {
        case .playlist(let p): return selection == .playlist && (selectedPlaylist == nil || selectedPlaylist?.lane == p.lane)
        case .track(_, let lane): return selection == .track && selectedPlaylist?.lane == lane
        }
    }
    func paste() {
        guard canPaste, let clipboard else { return }
        switch clipboard {
        case .playlist(let p):
            let copy = p.duplicated(order: project.nextOrder)
            change { project in
                let at = selectedPlaylistID.flatMap { id in project.playlists.firstIndex { $0.id == id } }.map { $0 + 1 } ?? project.playlists.count
                project.playlists.insert(copy, at: at)
            }; selectPlaylist(copy.id)
        case .track(let t, _):
            guard let id = selectedPlaylistID else { return }; let copy = t.duplicated()
            change { project in
                guard let i = project.playlists.firstIndex(where: { $0.id == id }) else { return }
                let at = selectedTrackID.flatMap { id in project.playlists[i].tracks.firstIndex { $0.id == id } }.map { $0 + 1 } ?? project.playlists[i].tracks.count
                project.playlists[i].tracks.insert(copy, at: at)
            }; selectTrack(copy.id)
        }
        prepareMedia()
    }
    func duplicate() {
        guard !locked, hasItemSelection else { return }
        let previousClipboard = clipboard
        copySelection(); paste(); clipboard = previousClipboard
    }
    func prepareMedia() { library.prepare(project: project, directory: directory) }
    func newProject() {
        guard !locked, confirmDiscard() else { return }
        engine.stopImmediately(); project = PlayerProject(); fileURL = nil; isDirty = false
        undoStack.removeAll(); redoStack.removeAll(); selectedPlaylistID = nil; selectedTrackID = nil
        showingProject = true; prepareMedia(); engine.resetSchedule()
        if remembersProject { UserDefaults.standard.removeObject(forKey: recentProjectKey) }
    }
    func openProject() {
        guard !locked, confirmDiscard() else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadProject(at: url)
    }
    func openProject(at url: URL) {
        guard !locked, confirmDiscard() else { return }
        loadProject(at: url)
    }
    private func loadProject(at url: URL) {
        do {
            let next = try PlayerProject.decode(Data(contentsOf: url))
            engine.stopImmediately(); project = next; fileURL = url; isDirty = false
            undoStack.removeAll(); redoStack.removeAll(); selectedPlaylistID = nil; selectedTrackID = nil
            showingProject = true; prepareMedia(); engine.resetSchedule()
            if remembersProject { UserDefaults.standard.set(url.path, forKey: recentProjectKey) }
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult func save(as saveAs: Bool = false) -> Bool {
        guard !locked else { return false }
        var destination = fileURL
        if destination == nil || saveAs {
            let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = project.name + ".geobox.json"
            guard panel.runModal() == .OK, let url = panel.url else { return false }; destination = url
        }
        guard let destination else { return false }
        do {
            rememberDeviceIdentities()
            try project.validate()
            var saved = project
            let base = destination.deletingLastPathComponent().standardizedFileURL.path + "/"
            for i in saved.playlists.indices {
                for j in saved.playlists[i].tracks.indices {
                    let url = project.playlists[i].tracks[j].resolvedURL(relativeTo: directory)
                    saved.playlists[i].tracks[j].path = url.path.hasPrefix(base) ? String(url.path.dropFirst(base.count)) : url.path
                }
            }
            try saved.encoded().write(to: destination, options: .atomic)
            project = saved; fileURL = destination; isDirty = false; message = "保存しました：\(destination.lastPathComponent)"
            if remembersProject { UserDefaults.standard.set(destination.path, forKey: recentProjectKey) }
            // Existing undo snapshots may contain paths relative to a different project directory.
            undoStack.removeAll(); redoStack.removeAll()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func confirmDiscard() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert(); alert.messageText = "変更を保存しますか？"
        alert.informativeText = "保存していない変更があります。"; alert.addButton(withTitle: locked ? "ロック解除して保存" : "保存")
        alert.addButton(withTitle: "キャンセル"); alert.addButton(withTitle: "保存しない")
        switch alert.runModal() {
        case .alertFirstButtonReturn: locked = false; return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }
}
