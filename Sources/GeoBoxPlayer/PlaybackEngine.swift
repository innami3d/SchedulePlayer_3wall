import AppKit
import AVFoundation
import PlayerCore

@MainActor
final class LaneMedia {
    let player = AVPlayer()
    var playlistID: UUID?
    var trackID: UUID?
    var index = 0
    var image: NSImage?
    var duration: Double = 0
    var started: TimeInterval?
    var ready = false
    var ended = false
    var fadingOut = false
    var envelope = Envelope()
    var endObserver: NSObjectProtocol?
    init() { player.actionAtItemEnd = .pause; player.automaticallyWaitsToMinimizeStalling = true }
    func stop() {
        player.pause(); player.replaceCurrentItem(with: nil)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }; endObserver = nil
        image = nil; playlistID = nil; trackID = nil; started = nil; ready = false; ended = false; fadingOut = false
        duration = 0; envelope = Envelope()
    }
}

@MainActor
final class PlaybackEngine: ObservableObject {
    weak var store: PlayerStore?
    private(set) var videoState = LanePlayback()
    private(set) var audioState = LanePlayback()
    private(set) var videoGate = OutputGate()
    private(set) var audioGate = OutputGate()
    let videoMedia = LaneMedia()
    let audioMedia = LaneMedia()
    private let output = VideoOutput()
    private var readyRequests: [MediaLane: UUID] = [:]
    private var timer: Timer?
    private var lastScheduleDate = Date()
    private var lastDeviceCheck: TimeInterval = 0
    private var activity: NSObjectProtocol?
    private var appliedAudioUID: String?
    private var appliedDisplay: UInt32?
    private var appliedRate: Double?
    var videoOpacity: Double = 0
    var status: String {
        "映像：\(videoState.phase.title) ／ 音声：\(audioState.phase.title)"
    }
    var suppressionReasons: [String] {
        guard let store else { return [] }
        return AudioSuppression.reasons(audioPlaylistActive: audioState.active,
                                        videoMuted: store.project.playlist(videoState.playlistID)?.muted ?? false,
                                        audioOutputActive: audioGate.active)
    }
    init(store: PlayerStore) { self.store = store }
    func startClock() {
        guard timer == nil else { return }
        lastScheduleDate = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    func resetSchedule() { lastScheduleDate = Date() }
    func play(_ id: UUID) {
        guard let store, !store.locked, let playlist = store.project.playlist(id) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        do {
            if playlist.lane == .video {
                if !videoGate.active { try openVideo(); videoGate.start(duration: store.project.video.fades.fadeIn, now: now) }
                if !audioGate.active { try openAudio(); audioGate.start(duration: store.project.audio.fades.fadeIn, now: now) }
            } else if !audioGate.active { try openAudio(); audioGate.start(duration: store.project.audio.fades.fadeIn, now: now) }
            request(playlist, now: now)
        } catch { store.error = error.localizedDescription }
    }
    func startProject(manual: Bool = true) {
        guard let store, !manual || !store.locked else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for lane in MediaLane.allCases { startOutput(lane, now: now) }
    }
    func endProject(manual: Bool = true) {
        guard let store, !manual || !store.locked else { return }
        let now = ProcessInfo.processInfo.systemUptime
        videoGate.end(duration: store.project.video.fades.fadeOut, now: now)
        audioGate.end(duration: store.project.audio.fades.fadeOut, now: now)
        readyRequests.removeAll()
    }
    func stopImmediately() {
        videoState.stop(); audioState.stop(); videoGate.stop(); audioGate.stop()
        videoMedia.stop(); audioMedia.stop(); readyRequests.removeAll(); output.close()
        store?.devices.restoreModes(); appliedDisplay = nil; appliedRate = nil
        videoOpacity = 0; endActivity(); objectWillChange.send()
    }
    private func openVideo() throws {
        guard let store, let id = store.project.displayID else { throw OutputDevices.DeviceError.missingDisplay }
        if appliedDisplay != id || appliedRate != store.project.refreshRate {
            output.close(); store.devices.restoreModes()
            try store.devices.activate4K(displayID: id, refreshRate: store.project.refreshRate)
            appliedDisplay = id; appliedRate = store.project.refreshRate
        }
        try output.open(displayID: id)
    }
    private func openAudio() throws {
        guard let store else { return }
        store.devices.refresh()
        if let uid = store.project.audioDeviceUID, !store.devices.audio.contains(where: { $0.id == uid }) {
            throw OutputDevices.DeviceError.missingAudio
        }
        applyAudioDevice()
    }
    private func applyAudioDevice() {
        let uid = store?.project.audioDeviceUID
        videoMedia.player.audioOutputDeviceUniqueID = uid
        audioMedia.player.audioOutputDeviceUniqueID = uid
        appliedAudioUID = uid
    }
    private func startOutput(_ lane: MediaLane, now: TimeInterval) {
        guard let store else { return }
        do {
            if lane == .video { try openVideo(); videoGate.start(duration: store.project.video.fades.fadeIn, now: now) }
            else { try openAudio(); audioGate.start(duration: store.project.audio.fades.fadeIn, now: now) }
            let schedule = store.project.schedule(for: lane)
            if let p = store.project.playlist(schedule.initialPlaylistID), p.lane == lane { request(p, now: now) }
            else { store.message = "\(lane.title)の開始プレイリストを設定してください。" }
        } catch { store.error = error.localizedDescription }
    }
    private func request(_ p: Playlist, now: TimeInterval) {
        guard let store, !p.tracks.isEmpty else { store?.message = "空のプレイリストは再生できません。"; return }
        let urls = p.tracks.map { $0.resolvedURL(relativeTo: store.directory) }
        for url in urls {
            if case .failed(let error) = store.library.states[url] { store.error = error; readyRequests[p.lane] = nil; return }
        }
        guard urls.allSatisfy({ store.library.prepared($0) != nil }) else {
            readyRequests[p.lane] = p.id; store.message = "素材の事前読み込み完了を待っています。"; store.prepareMedia(); return
        }
        readyRequests[p.lane] = nil
        if p.lane == .video { videoState.request(p, project: store.project, now: now) }
        else { audioState.request(p, project: store.project, now: now) }
    }
    private func tick() {
        guard let store else { return }
        let now = ProcessInfo.processInfo.systemUptime, date = Date(), project = store.project
        if date.timeIntervalSince(lastScheduleDate) >= 0.2 || date < lastScheduleDate {
            if date.timeIntervalSince(lastScheduleDate) > 86_400 {
                for lane in MediaLane.allCases {
                    if project.schedule(for: lane).contains(.at(date)) { startOutput(lane, now: now) }
                    else { endOutput(lane, now: now) }
                }
            } else {
                for event in DailyScheduler.events(project: project, after: lastScheduleDate, through: date) {
                    switch event.action {
                    case .startOutput: startOutput(event.lane, now: now)
                    case .endOutput: endOutput(event.lane, now: now)
                    case .playlist(let id):
                        let gate = event.lane == .video ? videoGate : audioGate
                        if gate.active && gate.phase != .fadingOut, let p = project.playlist(id) { request(p, now: now) }
                    }
                }
            }
            lastScheduleDate = date
        }
        for (lane, id) in readyRequests {
            if let p = project.playlist(id) {
                let urls = p.tracks.map { $0.resolvedURL(relativeTo: store.directory) }
                if urls.allSatisfy({ store.library.prepared($0) != nil }) { request(p, now: now) }
                else if urls.contains(where: { if case .failed = store.library.states[$0] { return true }; return false }) {
                    readyRequests[lane] = nil; store.error = "素材を読み込めないため\(p.name)を開始できません。"
                }
            } else { readyRequests[lane] = nil }
        }
        videoGate.tick(now: now); audioGate.tick(now: now)
        if !videoGate.active {
            videoState.stop(); if videoMedia.playlistID != nil { videoMedia.stop() }
            if output.displayID != nil { output.close(); store.devices.restoreModes(); appliedDisplay = nil; appliedRate = nil }
        }
        if !audioGate.active { audioState.stop(); if audioMedia.playlistID != nil { audioMedia.stop() } }
        videoState.tick(project: project, now: now); audioState.tick(project: project, now: now)
        synchronize(lane: .video, state: videoState, media: videoMedia, now: now)
        synchronize(lane: .audio, state: audioState, media: audioMedia, now: now)
        let videoGain = videoState.envelope.value(at: now) * videoMedia.envelope.value(at: now)
        let audioGain = audioState.envelope.value(at: now) * audioMedia.envelope.value(at: now)
        videoOpacity = videoGate.active ? videoGate.envelope.value(at: now) * videoGain : 0
        let videoVolume = currentTrack(.video)?.volume ?? 0, audioVolume = currentTrack(.audio)?.volume ?? 0
        let permitted = suppressionReasons.isEmpty
        videoMedia.player.volume = Float(permitted ? max(0, min(1, audioGate.envelope.value(at: now) * videoGain * videoVolume)) : 0)
        audioMedia.player.volume = Float(audioGate.active ? max(0, min(1, audioGate.envelope.value(at: now) * audioGain * audioVolume)) : 0)
        output.surface?.update(player: videoMedia.player, image: videoMedia.image, opacity: videoOpacity,
                               color: NSColor(hex: project.fadeColorHex), visible: videoState.active)
        if now - lastDeviceCheck > 2 {
            lastDeviceCheck = now; store.devices.refresh()
            if videoGate.active, let id = appliedDisplay, !store.devices.displays.contains(where: { $0.id == id }) {
                videoGate.stop(); videoState.stop(); videoMedia.stop(); output.close(); store.error = "映像出力先が切断されました。"
            }
            if audioGate.active, let uid = appliedAudioUID, !store.devices.audio.contains(where: { $0.id == uid }) {
                audioGate.stop(); audioState.stop(); audioMedia.stop(); videoMedia.player.isMuted = true
                store.error = "音声出力先が切断されました。"
            } else { videoMedia.player.isMuted = false }
        }
        if videoGate.active || audioGate.active { beginActivity() } else { endActivity() }
        objectWillChange.send()
    }
    private func endOutput(_ lane: MediaLane, now: TimeInterval) {
        guard let store else { return }; readyRequests[lane] = nil
        if lane == .video { videoGate.end(duration: store.project.video.fades.fadeOut, now: now) }
        else { audioGate.end(duration: store.project.audio.fades.fadeOut, now: now) }
    }
    func currentTrack(_ lane: MediaLane) -> MediaTrack? {
        guard let store else { return nil }
        let state = lane == .video ? videoState : audioState, media = lane == .video ? videoMedia : audioMedia
        return store.project.playlist(state.playlistID)?.tracks.first { $0.id == media.trackID }
    }
    private func synchronize(lane: MediaLane, state: LanePlayback, media: LaneMedia, now: TimeInterval) {
        guard let store, let playlist = store.project.playlist(state.playlistID), !playlist.tracks.isEmpty else {
            if media.playlistID != nil { media.stop() }; return
        }
        if media.playlistID != playlist.id {
            media.stop(); media.playlistID = playlist.id; media.index = 0
            loadTrack(playlist, media: media, now: now)
        } else if !playlist.tracks.contains(where: { $0.id == media.trackID }) {
            media.index = min(media.index, playlist.tracks.count - 1); loadTrack(playlist, media: media, now: now)
        }
        if media.player.currentItem?.status == .failed {
            store.error = media.player.currentItem?.error?.localizedDescription ?? "再生エラー"
            if lane == .video { videoState.stop() } else { audioState.stop() }; media.stop(); return
        }
        if !media.ready, media.image != nil || media.player.currentItem?.status == .readyToPlay {
            media.ready = true; media.started = now
            let fades = lane == .video ? store.project.defaults.videoTrackFades : store.project.defaults.audioTrackFades
            media.envelope = Envelope(from: 0, to: 1, started: now, duration: min(fades.fadeIn, media.duration / 2))
            if media.image == nil { media.player.play() }
        }
        guard media.ready else { return }
        let elapsed = media.image != nil ? now - (media.started ?? now) : media.player.currentTime().seconds
        let fades = lane == .video ? store.project.defaults.videoTrackFades : store.project.defaults.audioTrackFades
        let out = min(fades.fadeOut, media.duration / 2)
        if !media.fadingOut && elapsed.isFinite && elapsed >= media.duration - out {
            media.fadingOut = true
            media.envelope = Envelope(from: media.envelope.value(at: now), to: 0, started: now, duration: out)
        }
        if media.ended || (media.fadingOut && media.envelope.completed(at: now)) {
            media.index = (media.index + 1) % playlist.tracks.count
            loadTrack(playlist, media: media, now: now)
        }
    }
    private func loadTrack(_ playlist: Playlist, media: LaneMedia, now: TimeInterval) {
        guard let store, playlist.tracks.indices.contains(media.index) else { return }
        let track = playlist.tracks[media.index], url = track.resolvedURL(relativeTo: store.directory)
        let index = media.index; media.stop(); media.playlistID = playlist.id; media.index = index; media.trackID = track.id
        guard let prepared = store.library.prepared(url) else {
            store.error = "準備できていない素材です：\(track.filename)"
            if playlist.lane == .video { videoState.stop() } else { audioState.stop() }; media.stop(); return
        }
        media.duration = track.kind == .image ? track.imageDuration : prepared.duration
        if track.kind == .image { media.image = store.library.image(url) }
        else if let asset = prepared.asset {
            let item = AVPlayerItem(asset: asset)
            media.player.replaceCurrentItem(with: item); media.player.volume = 0
            media.endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak media] _ in
                Task { @MainActor in if media?.player.currentItem === item { media?.ended = true } }
            }
        }
    }
    private func beginActivity() {
        if activity == nil { activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled], reason: "GeoBox scheduled playback") }
    }
    private func endActivity() { if let activity { ProcessInfo.processInfo.endActivity(activity) }; activity = nil }
}
