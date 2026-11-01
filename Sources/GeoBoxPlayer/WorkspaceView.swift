import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PlayerCore

struct WorkspaceView: View {
    @ObservedObject var store: PlayerStore
    @ObservedObject var engine: PlaybackEngine
    @ObservedObject var library: MediaLibrary
    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                sidebar.frame(minWidth: 220, idealWidth: 240, maxWidth: 300)
                ScrollView {
                    if store.showingScheduler {
                        SchedulerSettingsView(store: store)
                    } else if store.showingProject || store.selectedPlaylist == nil {
                        ProjectSettingsView(store: store, devices: store.devices)
                    } else {
                        PlaylistEditor(store: store, engine: engine, library: library)
                    }
                }
                .id(store.showingScheduler ? "scheduler" : store.showingProject ? "project" : store.selectedPlaylistID?.uuidString ?? "project")
                .frame(minWidth: 650, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            outputPreview
            Divider()
            HStack {
                Label(engine.status, systemImage: "play.rectangle")
                Spacer()
                Text(library.summary)
                if store.locked { Label("時刻再生のみ", systemImage: "lock.fill") }
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 10)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("GEOBOX PLAYER").font(.headline)
                    Text(store.project.name + (store.isDirty ? " · 未保存" : "")).font(.caption).foregroundStyle(.secondary)
                }
            }
            ToolbarItemGroup {
                Button { store.openProject() } label: { Label("開く", systemImage: "folder") }.controlHover().disabled(store.locked)
                Button { store.save() } label: { Label("保存", systemImage: "square.and.arrow.down") }.controlHover().disabled(store.locked)
                Divider()
                Button {
                    store.locked.toggle()
                } label: { Label(store.locked ? "ロック解除" : "画面をロック", systemImage: store.locked ? "lock.fill" : "lock.open") }
                    .tint(store.locked ? .orange : nil)
                    .controlHover(tint: store.locked ? .orange : .accentColor)
            }
        }
        .background(KeyEventBridge(store: store))
        .alert("確認", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .onAppear { engine.startClock(); store.prepareMedia() }
        .onChange(of: store.project.calendarEntries) { _, _ in engine.resetSchedule(reconcile: true) }
    }
    private var outputPreview: some View {
        HStack(alignment: .center, spacing: 16) {
            PreviewSurface(engine: engine)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(width: 220, height: 123.75)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 7) {
                Text("送出プレビュー").font(.headline)
                Text(store.project.playlist(engine.videoState.playlistID)?.name ?? "黒画面で待機中")
                    .font(.callout).lineLimit(1)
                Text("4K固定 · \(store.project.refreshRate.formatted()) Hz")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                if engine.videoState.active && !engine.suppressionReasons.isEmpty {
                    Text(engine.suppressionReasons.joined(separator: " ／ "))
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button { store.selectProject() } label: {
                    Label("プロジェクト設定", systemImage: "slider.horizontal.3")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(store.showingProject ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).rowHover().padding(.bottom, 4)
                Button { store.selectScheduler() } label: {
                    Label("スケジューラ設定", systemImage: "calendar")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        .background(store.showingScheduler ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).rowHover()
                ForEach(MediaLane.allCases) { lane in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(lane.title)プレイリスト").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                        ForEach(store.project.playlists.filter { $0.lane == lane }) { playlist in
                            playlistRow(playlist)
                        }
                        Button { store.createPlaylist(lane) } label: { Label("プレイリスト作成", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading) }
                            .buttonStyle(.borderless).padding(8).controlHover().disabled(store.locked)
                    }
                }
                Text(store.locked ? "ロック中は時刻設定に従って\n再生します。" : "右クリックで編集\n映像・音声それぞれ同時再生は1つ")
                    .font(.caption).foregroundStyle(.secondary).padding(8)
            }.padding(12)
        }.background(.quaternary.opacity(0.35))
    }
    private func playlistRow(_ playlist: Playlist) -> some View {
        Button { store.selectPlaylist(playlist.id) } label: {
            HStack {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.secondary)
                    .help("カレンダーへドラッグして再生予定を追加")
                VStack(alignment: .leading, spacing: 3) {
                    Text(playlist.name).fontWeight(.medium).lineLimit(1)
                    if playback(playlist.lane).playlistID == playlist.id {
                        Text(playback(playlist.lane).phase.title).font(.caption).foregroundStyle(.tint)
                    } else if playback(playlist.lane).pendingID == playlist.id {
                        Text("次の再生待ち").font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(store.selectedPlaylistID == playlist.id && !store.showingProject ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .rowHover()
        .background(ContextSelectionObserver { store.selectPlaylist(playlist.id) }.allowsHitTesting(false))
        .contextMenu { ItemEditMenu(store: store) }
        .draggable(store.locked ? "" : "playlist:" + playlist.id.uuidString)
    }
    private func playback(_ lane: MediaLane) -> LanePlayback { lane == .video ? engine.videoState : engine.audioState }
}

struct PlaylistEditor: View {
    @ObservedObject var store: PlayerStore
    @ObservedObject var engine: PlaybackEngine
    @ObservedObject var library: MediaLibrary
    @State private var targeted: UUID?
    @State private var dropAtEnd = false
    @State private var hoveredTrackID: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let playlist = store.selectedPlaylist {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(playlist.lane.title)プレイリスト").font(.caption).foregroundStyle(.secondary)
                        Text(playlist.name).font(.title2).fontWeight(.semibold)
                    }
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 14) {
                    LabeledContent("プレイリスト名") { TextField("名前", text: store.playlistBinding(\.name, fallback: "")).frame(maxWidth: 380).fieldHover() }
                    Text("プレイリストの開始・終了フェードは、スケジューラの再生予定で設定します。")
                        .font(.caption).foregroundStyle(.secondary)
                    if playlist.lane == .video {
                        Toggle("プレイリスト全体をミュート", isOn: store.playlistBinding(\.muted, fallback: false)).toggleStyle(.switch).controlHover()
                    }
                    GroupBox("トラック間の再生設定") {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                NumberField(title: "映像トラック間 IN（秒）", value: store.playlistBinding(\.playbackSettings.videoTrackFades.fadeIn, fallback: 0), range: 0...max(0, store.project.defaults.fadeMax))
                                NumberField(title: "映像トラック間 OUT（秒）", value: store.playlistBinding(\.playbackSettings.videoTrackFades.fadeOut, fallback: 0), range: 0...max(0, store.project.defaults.fadeMax))
                            }
                            HStack {
                                NumberField(title: "音声トラック間 IN（秒）", value: store.playlistBinding(\.playbackSettings.audioTrackFades.fadeIn, fallback: 0), range: 0...max(0, store.project.defaults.fadeMax))
                                NumberField(title: "音声トラック間 OUT（秒）", value: store.playlistBinding(\.playbackSettings.audioTrackFades.fadeOut, fallback: 0), range: 0...max(0, store.project.defaults.fadeMax))
                            }
                            ColorPicker("映像フェード先", selection: Binding(get: { Color(nsColor: NSColor(hex: playlist.playbackSettings.fadeColorHex)) }, set: { color in
                                guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
                                store.playlistBinding(\.playbackSettings.fadeColorHex, fallback: "#000000").wrappedValue = String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
                            }), supportsOpacity: false).controlHover()
                            Text("このプレイリスト内のトラックに適用します。0秒でフェードなしになります。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.disabled(store.locked)
                HStack {
                    Text("トラック").font(.headline)
                    Spacer()
                    Text("登録順に再生・末尾からループ").font(.caption).foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    HStack {
                        Text("順序").frame(width: 38)
                        Text("ファイル").frame(maxWidth: .infinity, alignment: .leading)
                        Text("種類").frame(width: 45)
                        Text("表示時間 / 尺").frame(width: 110, alignment: .trailing)
                        Color.clear.frame(width: 28, height: 1)
                    }.font(.caption).foregroundStyle(.secondary).padding(10)
                    Divider()
                    ForEach(Array(playlist.tracks.enumerated()), id: \.element.id) { index, track in
                        trackRow(track, index: index)
                            .overlay(alignment: .top) { if targeted == track.id { Rectangle().fill(Color.accentColor).frame(height: 2) } }
                            .onDrop(of: [.fileURL, .utf8PlainText], delegate: TrackDropDelegate(store: store, before: track.id, targeted: $targeted))
                        Divider()
                    }
                    Text(store.locked ? "ロック中：ファイル追加・並べ替えは無効" : "ファイルをドロップして追加 · トラックをドラッグして並べ替え")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 25)
                        .background(dropAtEnd ? Color.accentColor.opacity(0.12) : .clear)
                        .rowHover(enabled: !store.locked)
                        .onDrop(of: [.fileURL, .utf8PlainText], isTargeted: $dropAtEnd) { providers in
                            guard !store.locked else { return false }; receiveDrop(providers, store: store, before: nil); return true
                        }
                        .onTapGesture { store.selectedTrackID = nil; store.selection = .track }
                        .background(ContextSelectionObserver { store.selectedTrackID = nil; store.selection = .track })
                        .contextMenu { ItemEditMenu(store: store) }
                }
                if let track = store.selectedTrack { TrackInspector(store: store, library: library, track: track) }
                Text(store.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.padding(24)
    }
    private func trackRow(_ track: MediaTrack, index: Int) -> some View {
        HStack(spacing: 0) {
            Button { store.selectTrack(track.id) } label: {
                HStack {
                    HStack(spacing: 4) { Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary); Text("\(index + 1)").monospacedDigit() }.frame(width: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.filename).lineLimit(1).truncationMode(.middle)
                        if engine.currentTrack(store.selectedPlaylist?.lane ?? .video)?.id == track.id { Text("再生中").font(.caption).foregroundStyle(.tint) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Text(track.kind.title).foregroundStyle(.secondary).frame(width: 45)
                    Text(duration(track)).monospacedDigit().foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
                }.padding(10).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button {
                guard let playlist = store.selectedPlaylist else { return }
                engine.playTrack(track.id, in: playlist.id)
            } label: {
                Image(systemName: "play.fill").frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless).controlHover()
            .help("このトラックに割り込んで再生")
            .accessibilityLabel("\(track.filename)を再生")
            .disabled(store.locked)
            .opacity(hoveredTrackID == track.id ? 1 : 0)
            .allowsHitTesting(hoveredTrackID == track.id)
            .accessibilityHidden(hoveredTrackID != track.id)
        }
            .onHover { hovering in
                if hovering { hoveredTrackID = track.id }
                else if hoveredTrackID == track.id { hoveredTrackID = nil }
            }
            .background(store.selectedTrackID == track.id ? Color.accentColor.opacity(0.12) : .clear)
            .rowHover(radius: 4)
            .background(ContextSelectionObserver { store.selectTrack(track.id) })
            .contextMenu { ItemEditMenu(store: store) }
            .onDrag { store.locked ? NSItemProvider() : NSItemProvider(object: track.id.uuidString as NSString) }
            .help(track.path)
    }
    private func duration(_ track: MediaTrack) -> String {
        if track.kind == .image { return "\(track.imageDuration.formatted())秒" }
        guard let ready = library.prepared(track.resolvedURL(relativeTo: store.directory)) else { return "準備中" }
        return String(format: "%02d:%02d", Int(ready.duration) / 60, Int(ready.duration) % 60)
    }
}

struct TrackInspector: View {
    @ObservedObject var store: PlayerStore
    @ObservedObject var library: MediaLibrary
    var track: MediaTrack
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            Text("トラック設定").font(.headline)
            LabeledContent("ファイルパス") {
                TextField("パス", text: store.trackBinding(\.path, fallback: "")).textFieldStyle(.roundedBorder).fieldHover()
            }
            HStack(spacing: 24) {
                VStack(alignment: .leading) {
                    Text(track.kind == .image ? "音声ボリューム · 対象外" : "音声ボリューム · \(Int(track.volume * 100))%")
                        .font(.caption).foregroundStyle(.secondary)
                    Slider(value: store.trackBinding(\.volume, fallback: 1), in: volumeRange).controlHover()
                        .disabled(track.kind == .image)
                }
                if track.kind == .image {
                    ImageDurationField(seconds: store.trackBinding(\.imageDuration, fallback: 20), maximum: store.project.defaults.imageMax)
                }
            }
            Text(library.states[track.resolvedURL(relativeTo: store.directory)]?.title ?? "読み込み待ち")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }.disabled(store.locked)
    }
    private var volumeRange: ClosedRange<Double> { min(store.project.defaults.volumeMin, store.project.defaults.volumeMax)...max(store.project.defaults.volumeMin, store.project.defaults.volumeMax) }
}

struct ItemEditMenu: View {
    @ObservedObject var store: PlayerStore
    var body: some View {
        Button("Delete（削除）", role: .destructive) { store.deleteSelection() }.disabled(store.locked || !store.hasItemSelection)
        Button("複製") { store.duplicate() }.disabled(store.locked || !store.hasItemSelection)
        Divider()
        Button("コピー") { store.copySelection() }.disabled(store.locked || !store.hasItemSelection)
        Button("ペースト") { store.paste() }.disabled(!store.canPaste)
        Button("Cut（切り取り）") { store.copySelection(cut: true) }.disabled(store.locked || !store.hasItemSelection)
    }
}
