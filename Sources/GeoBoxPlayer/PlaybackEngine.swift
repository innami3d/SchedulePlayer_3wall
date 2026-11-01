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
    var resumeOffset: Double = 0
    var resumeDate: Date?
    var seeking = false
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
        duration = 0; resumeOffset = 0; resumeDate = nil; seeking = false; envelope = Envelope()
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
    private var recoveryLanes: Set<MediaLane> = []
    private var lastRecoveryAttempt: TimeInterval = -.infinity
    private var readyRequests: [MediaLane: UUID] = [:]
    private var trackRequests: [MediaLane: (playlistID: UUID, trackID: UUID)] = [:]
    private var timer: Timer?
    private var lastScheduleDate = Date()
    private var lastDeviceCheck: TimeInterval = 0
    private var activity: NSObjectProtocol?
    private var appliedAudioUID: String?
    private var appliedDisplay: UInt32?
    private var appliedRate: Double?
    private var shuttingDown = false
    private weak var controlWindow: NSWindow?
    private var controlWindowClosed = false
    var hasVideoOutput: Bool { output.displayID != nil }
    func attachControlWindow(_ window: NSWindow) {
        controlWindow = window; controlWindowClosed = false
    }
    @discardableResult func ensureControlWindowVisible() -> Bool {
        guard !controlWindowClosed, let controlWindow else { return false }
        if NSApp?.isHidden == true { NSApp.unhide(nil) }
        if controlWindow.isMiniaturized { controlWindow.deminiaturize(nil) }
        if !controlWindow.isVisible { controlWindow.makeKeyAndOrderFront(nil) }
        return controlWindow.isVisible && !controlWindow.isMiniaturized
    }
    func controlWindowDidClose() {
        controlWindowClosed = true; shuttingDown = true
        timer?.invalidate(); timer = nil
        stopImmediately(releaseOutput: true)
        controlWindow = nil
    }
    private(set) var videoDisconnected = false
    private(set) var audioDisconnected = false
    var videoOpacity: Double = 0
    var videoVisible: Bool { videoGate.active && videoState.active && videoMedia.ready }
    var videoFadeColorHex: String {
        store?.project.playlist(videoState.playlistID)?.playbackSettings.fadeColorHex ?? "#000000"
    }
    var status: String {
        let previewOnly = videoGate.active && store?.project.displayID == nil && store?.project.displayUUID == nil
        let phase = videoState.active ? (videoMedia.ready ? videoState.phase.title : "読み込み中") : "黒画面で待機"
        let videoStatus = previewOnly ? "プレビューのみ（\(phase)）" : (videoDisconnected ? "機器の再接続待ち" : phase)
        return "映像：\(videoStatus) ／ 音声：\(audioStatus)"
    }
    private var embeddedVideoHasAudio: Bool {
        guard let store, videoGate.active, videoState.active, let track = currentTrack(.video), track.kind == .video else { return false }
        return store.library.prepared(track.resolvedURL(relativeTo: store.directory))?.hasAudio == true
    }
    private var audioStatus: String {
        if audioDisconnected && outputIsActive { return "機器の再接続待ち" }
        if audioState.active && audioGate.active {
            let phase = audioGate.phase == .playing ? audioState.phase : audioGate.phase
            return "音声プレイリスト（\(phase.title)）"
        }
        if embeddedVideoHasAudio {
            if store?.project.playlist(videoState.playlistID)?.muted == true { return "動画内音声（ミュート中）" }
            if currentTrack(.video)?.volume == 0 { return "動画内音声（音量0）" }
            if !videoMedia.ready { return "動画内音声（準備中）" }
            let phase = videoGate.phase == .playing ? videoState.phase : videoGate.phase
            return "動画内音声（\(phase.title)）"
        }
        return "停止中"
    }
    var suppressionReasons: [String] {
        guard let store else { return [] }
        let outputActive = store.project.calendarEntries == nil ? audioGate.active : videoGate.active
        var reasons = AudioSuppression.reasons(audioPlaylistActive: audioState.active && audioGate.active,
                                               videoMuted: store.project.playlist(videoState.playlistID)?.muted ?? false,
                                               audioOutputActive: outputActive)
        if audioDisconnected { reasons.append("音声出力先の再接続待ち") }
        return reasons
    }
    init(store: PlayerStore) { self.store = store }
    func startClock() {
        guard !controlWindowClosed, timer == nil else { return }
        lastScheduleDate = Date()
        store?.rememberDeviceIdentities()
        if store?.fileURL != nil { recoveryLanes = Set(MediaLane.allCases) }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    func resetSchedule(reconcile: Bool = false) {
        guard !controlWindowClosed else { return }
        lastScheduleDate = Date(); shuttingDown = false
        recoveryLanes = reconcile ? Set(MediaLane.allCases) : []
        lastRecoveryAttempt = -.infinity
    }
    var outputIsActive: Bool { videoGate.active || audioGate.active }
    func shutdown() async {
        shuttingDown = true; endProject(manual: false)
        while outputIsActive {
            try? await Task.sleep(for: .milliseconds(20))
            tick()
        }
        controlWindowDidClose()
    }
    func play(_ id: UUID) {
        guard !controlWindowClosed, let store, !store.locked, let playlist = store.project.playlist(id) else { return }
        recoveryLanes.remove(playlist.lane)
        let now = ProcessInfo.processInfo.systemUptime
        if playlist.lane == .video {
            if !videoGate.active { beginOutput(.video, now: now) }
            if store.project.calendarEntries == nil, !audioGate.active { beginOutput(.audio, now: now) }
        } else if !audioGate.active { beginOutput(.audio, now: now) }
        request(playlist, now: now)
    }

    func playTrack(_ trackID: UUID, in playlistID: UUID) {
        guard !controlWindowClosed, let store, !store.locked,
              let playlist = store.project.playlist(playlistID),
              playlist.tracks.contains(where: { $0.id == trackID }) else { return }
        recoveryLanes.remove(playlist.lane)
        readyRequests[playlist.lane] = nil
        trackRequests[playlist.lane] = (playlistID, trackID)
        store.prepareMedia()
        applyTrackRequest(playlist.lane, now: ProcessInfo.processInfo.systemUptime)
        objectWillChange.send()
    }

    private func applyTrackRequest(_ lane: MediaLane, now: TimeInterval) {
        guard !controlWindowClosed, let store, let request = trackRequests[lane] else { return }
        guard !store.locked, let playlist = store.project.playlist(request.playlistID),
              let index = playlist.tracks.firstIndex(where: { $0.id == request.trackID }) else {
            trackRequests[lane] = nil; return
        }
        let url = playlist.tracks[index].resolvedURL(relativeTo: store.directory)
        if case .failed(let error) = store.library.states[url] {
            trackRequests[lane] = nil; store.error = error; return
        }
        guard store.library.prepared(url) != nil else {
            store.message = "素材の事前読み込み完了を待っています。"; return
        }
        trackRequests[lane] = nil
        if lane == .video {
            if !videoGate.active || videoGate.phase == .fadingOut { beginOutput(.video, now: now) }
            if store.project.calendarEntries == nil, !audioGate.active || audioGate.phase == .fadingOut { beginOutput(.audio, now: now) }
            videoState.stop(); videoState.request(playlist, project: store.project, now: now, usePlaylistFades: store.project.calendarEntries == nil)
        } else {
            if !audioGate.active || audioGate.phase == .fadingOut { beginOutput(.audio, now: now) }
            audioState.stop(); audioState.request(playlist, project: store.project, now: now, usePlaylistFades: store.project.calendarEntries == nil)
        }
        let media = lane == .video ? videoMedia : audioMedia
        media.index = index
        loadTrack(playlist, media: media, now: now)
    }

    func startProject(manual: Bool = true) {
        guard !controlWindowClosed, let store, !manual || !store.locked else { return }
        let now = ProcessInfo.processInfo.systemUptime
        recoveryLanes.removeAll()
        for lane in MediaLane.allCases { startOutput(lane, now: now) }
    }
    func endProject(manual: Bool = true) {
        guard !controlWindowClosed, let store, !manual || !store.locked else { return }
        let now = ProcessInfo.processInfo.systemUptime
        recoveryLanes.removeAll()
        videoGate.end(duration: stopFade(.video), now: now)
        audioGate.end(duration: stopFade(.audio), now: now)
        readyRequests.removeAll()
        trackRequests.removeAll()
    }
    func stopImmediately(releaseOutput: Bool = true) {
        trackRequests.removeAll()
        recoveryLanes.removeAll()
        videoState.stop(); audioState.stop(); videoGate.stop(); audioGate.stop()
        videoMedia.stop(); audioMedia.stop(); readyRequests.removeAll()
        if releaseOutput {
            output.close(); store?.devices.restoreModes(); appliedDisplay = nil; appliedRate = nil
        } else {
            output.surface?.update(player: videoMedia.player, image: nil, opacity: 0, color: .black, visible: false)
        }
        videoDisconnected = false; audioDisconnected = false
        videoMedia.player.isMuted = false; audioMedia.player.isMuted = false
        videoOpacity = 0; endActivity(); objectWillChange.send()
    }
    private func openVideo() throws {
        guard let store else { return }
        guard let id = store.selectedDisplay?.id else {
            output.close(); store.devices.restoreModes(); appliedDisplay = nil; appliedRate = nil
            if store.project.displayID != nil || store.project.displayUUID != nil { throw OutputDevices.DeviceError.missingDisplay }
            return // An unconfigured external display still allows the in-app preview.
        }
        guard ensureControlWindowVisible() else { throw OutputDevices.DeviceError.missingControlWindow }
        if appliedDisplay != id || appliedRate != store.project.refreshRate {
            output.close(); store.devices.restoreModes()
            try store.devices.activate4K(displayID: id, refreshRate: store.project.refreshRate)
            appliedDisplay = id; appliedRate = store.project.refreshRate
        }
        try output.open(displayID: id)
        // A same-screen output must not cover the controls that can stop it.
        controlWindow?.orderFront(nil)
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
        videoMedia.player.isMuted = false; audioMedia.player.isMuted = false
    }
    /// Playback and preview continue independently of external device availability.
    private func beginOutput(_ lane: MediaLane, now: TimeInterval, fade: Double? = nil) {
        guard let store else { return }
        if lane == .video {
            videoGate.start(duration: fade ?? (store.project.calendarEntries == nil ? store.project.video.fades.fadeIn : 0), now: now)
            do { try openVideo(); videoDisconnected = false }
            catch { videoDisconnected = true; store.message = "映像出力先の再接続待ち：\(error.localizedDescription)" }
        } else {
            audioGate.start(duration: fade ?? (store.project.calendarEntries == nil ? store.project.audio.fades.fadeIn : 0), now: now)
        }
        // Video sound also uses the selected audio device, independently of the audio-playlist gate.
        do { try openAudio(); audioDisconnected = false }
        catch {
            audioDisconnected = true
            videoMedia.player.isMuted = true; audioMedia.player.isMuted = true
            store.message = "音声出力先の再接続待ち：\(error.localizedDescription)"
        }
    }
    private func startOutput(_ lane: MediaLane, now: TimeInterval) {
        trackRequests[lane] = nil
        guard let store else { return }
        beginOutput(lane, now: now)
        if store.project.calendarEntries != nil {
            let scheduled = CalendarScheduler.active(project: store.project, lane: lane, at: Date())
            let id = scheduled?.entry.playlistID ?? store.selectedPlaylistID
            if let playlist = store.project.playlist(id), playlist.lane == lane { request(playlist, now: now) }
            return
        }
        let schedule = store.project.schedule(for: lane)
        if let p = store.project.playlist(schedule.initialPlaylistID), p.lane == lane { request(p, now: now) }
        else { store.message = "\(lane.title)のデフォルト再生プレイリストを設定してください。" }
    }
    private func request(_ p: Playlist, now: TimeInterval) {
        trackRequests[p.lane] = nil
        guard let store, !p.tracks.isEmpty else { store?.message = "空のプレイリストは再生できません。"; return }
        // A new request cancels even a transition whose replacement media is still being prepared.
        if p.lane == .video, videoState.phase == .fadingIn || videoState.phase == .fadingOut {
            videoState.stop(); videoMedia.stop()
        } else if p.lane == .audio, audioState.phase == .fadingIn || audioState.phase == .fadingOut {
            audioState.stop(); audioMedia.stop()
        }
        let urls = p.tracks.map { $0.resolvedURL(relativeTo: store.directory) }
        for url in urls {
            if case .failed(let error) = store.library.states[url] { store.error = error; readyRequests[p.lane] = nil; return }
        }
        guard urls.allSatisfy({ store.library.prepared($0) != nil }) else {
            readyRequests[p.lane] = p.id; store.message = "素材の事前読み込み完了を待っています。"; store.prepareMedia(); return
        }
        readyRequests[p.lane] = nil
        if p.lane == .video { videoState.request(p, project: store.project, now: now, usePlaylistFades: store.project.calendarEntries == nil) }
        else { audioState.request(p, project: store.project, now: now, usePlaylistFades: store.project.calendarEntries == nil) }
    }
    func tick(date: Date = Date(), now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !controlWindowClosed, let store else { return }
        if hasVideoOutput && controlWindow == nil { controlWindowDidClose(); return }
        let project = store.project
        if !shuttingDown && (date.timeIntervalSince(lastScheduleDate) >= 0.2 || date < lastScheduleDate) {
            if date.timeIntervalSince(lastScheduleDate) > 86_400 || date < lastScheduleDate {
                stopImmediately(releaseOutput: false)
                recoveryLanes = Set(MediaLane.allCases)
            } else {
                for event in DailyScheduler.events(project: project, after: lastScheduleDate, through: date) {
                    guard !recoveryLanes.contains(event.lane) else { continue }
                    switch event.action {
                    case .startOutput: startOutput(event.lane, now: now)
                    case .endOutput:
                        let previous = CalendarScheduler.active(project: project, lane: event.lane, at: event.date.addingTimeInterval(-0.001))
                        endOutput(event.lane, now: now, fade: previous?.entry.fades.fadeOut)
                    case .playlist(let id):
                        let gate = event.lane == .video ? videoGate : audioGate
                        if let p = project.playlist(id), !p.tracks.isEmpty {
                            if project.calendarEntries != nil {
                                readyRequests[event.lane] = nil
                                trackRequests[event.lane] = nil
                                recoveryLanes.insert(event.lane)
                                continue
                            } else if !gate.active || gate.phase == .fadingOut { beginOutput(event.lane, now: now) }
                            request(p, now: now)
                        }
                    }
                }
            }
            lastScheduleDate = date
        }
        if !shuttingDown, now - lastRecoveryAttempt >= 0.2 {
            lastRecoveryAttempt = now
            for lane in recoveryLanes { recover(lane, at: date, now: now) }
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
        for lane in MediaLane.allCases { applyTrackRequest(lane, now: now) }
        videoGate.tick(now: now); audioGate.tick(now: now)
        if !videoGate.active {
            videoState.stop(); if videoMedia.playlistID != nil { videoMedia.stop() }
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
        let videoAudioGate = project.calendarEntries == nil ? audioGate : videoGate
        videoMedia.player.volume = Float(permitted ? max(0, min(1, videoAudioGate.envelope.value(at: now) * videoGain * videoVolume)) : 0)
        audioMedia.player.volume = Float(audioGate.active ? max(0, min(1, audioGate.envelope.value(at: now) * audioGain * audioVolume)) : 0)
        output.surface?.update(player: videoMedia.player, image: videoMedia.image, opacity: videoOpacity,
                               color: NSColor(hex: videoFadeColorHex), visible: videoVisible)
        if now - lastDeviceCheck > 2 {
            lastDeviceCheck = now; store.devices.refresh()
            store.library.refreshIfChanged(project: project, directory: store.directory)
            store.rememberDeviceIdentities()
            reconnectDevices()
        }
        if videoGate.active || audioGate.active || output.displayID != nil { beginActivity() } else { endActivity() }
        objectWillChange.send()
    }
    /// Wait for metadata, then calculate against the current wall clock rather than launch time.
    private func recover(_ lane: MediaLane, at date: Date, now: TimeInterval) {
        guard let store else { return }
        guard let playback = DailyScheduler.playback(project: store.project, lane: lane, at: date, now: now) else {
            recoveryLanes.remove(lane); endOutput(lane, now: now); return
        }
        let playlist = store.project.playlist(playback.state.playlistID)
        let required = [playlist, store.project.playlist(playback.state.pendingID)].compactMap { $0 }.flatMap(\.tracks)
        for track in required {
            let url = track.resolvedURL(relativeTo: store.directory)
            if case .failed(let error) = store.library.states[url] {
                recoveryLanes.remove(lane); store.error = error; return
            }
            guard store.library.prepared(url) != nil else { return }
        }
        let media = lane == .video ? videoMedia : audioMedia
        var position: ScheduledTrackPosition?
        if let playlist {
            let durations = playlist.tracks.map { track in
                track.kind == .image ? track.imageDuration : store.library.prepared(track.resolvedURL(relativeTo: store.directory))!.duration
            }
            position = ScheduledTrackPosition.resolve(durations: durations, elapsed: playback.elapsed)
            guard position != nil else { recoveryLanes.remove(lane); return }
        }
        if lane == .video { videoState = playback.state }
        else { audioState = playback.state }
        let occurrence = CalendarScheduler.active(project: store.project, lane: lane, at: date) ?? CalendarScheduler.ending(project: store.project, lane: lane, at: date)
        let began = occurrence.map { now - date.timeIntervalSince($0.interval.start) } ?? now
        beginOutput(lane, now: began, fade: occurrence?.entry.fades.fadeIn)
        if let occurrence, date >= occurrence.interval.end {
            endOutput(lane, now: now - date.timeIntervalSince(occurrence.interval.end), fade: occurrence.entry.fades.fadeOut)
        }
        if lane == .video { videoGate.tick(now: now) } else { audioGate.tick(now: now) }
        if let playlist, let position {
            media.index = position.index
            loadTrack(playlist, media: media, now: now)
            media.resumeOffset = position.offset
            media.resumeDate = date
        }
        recoveryLanes.remove(lane)
    }
    func reconnectDevices() {
        guard !controlWindowClosed, let store else { return }
        // Keep the selected display covered in black even between scheduled playbacks.
        if !shuttingDown {
            if store.selectedDisplay == nil {
                if output.displayID != nil {
                    output.close(); store.devices.restoreModes()
                    appliedDisplay = nil; appliedRate = nil
                }
                videoDisconnected = store.project.displayID != nil || store.project.displayUUID != nil
            } else if videoDisconnected || output.displayID != store.selectedDisplay?.id || appliedDisplay != store.selectedDisplay?.id || appliedRate != store.project.refreshRate {
                do {
                    try openVideo(); videoDisconnected = false
                    store.message = "映像出力先へ自動接続しました。"
                } catch {
                    videoDisconnected = true
                    store.message = "映像出力先の再接続待ち：\(error.localizedDescription)"
                }
            }
        } else { videoDisconnected = false }
        let audioMissing = store.project.audioDeviceUID.map { uid in
            !store.devices.audio.contains { $0.id == uid }
        } ?? false
        if audioGate.active || videoGate.active {
            if audioMissing {
                audioDisconnected = true
            } else if audioDisconnected || appliedAudioUID != store.project.audioDeviceUID {
                applyAudioDevice(); audioDisconnected = false
                store.message = "音声出力先へ自動接続しました。"
            }
        } else { audioDisconnected = false }
        // AVPlayer may fall back to the system device when its selected device disappears.
        videoMedia.player.isMuted = audioMissing
        audioMedia.player.isMuted = audioMissing
    }
    private func stopFade(_ lane: MediaLane) -> Double {
        guard let store else { return 0 }
        if store.project.calendarEntries == nil { return store.project.schedule(for: lane).fades.fadeOut }
        if let entry = CalendarScheduler.active(project: store.project, lane: lane, at: Date()) { return entry.entry.fades.fadeOut }
        return 0
    }
    private func endOutput(_ lane: MediaLane, now: TimeInterval, fade: Double? = nil) {
        trackRequests[lane] = nil
        guard store != nil else { return }; readyRequests[lane] = nil
        if lane == .video { videoGate.end(duration: fade ?? stopFade(.video), now: now) }
        else { audioGate.end(duration: fade ?? stopFade(.audio), now: now) }
    }
    func currentTrack(_ lane: MediaLane) -> MediaTrack? {
        guard let store else { return nil }
        let state = lane == .video ? videoState : audioState, media = lane == .video ? videoMedia : audioMedia
        return store.project.playlist(state.playlistID)?.tracks.first { $0.id == media.trackID }
    }
    private func synchronize(lane: MediaLane, state: LanePlayback, media: LaneMedia, now: TimeInterval) {
        guard !recoveryLanes.contains(lane) else { return }
        guard let store, let playlist = store.project.playlist(state.playlistID), !playlist.tracks.isEmpty else {
            if media.playlistID != nil { media.stop() }; return
        }
        if media.playlistID != playlist.id {
            media.stop(); media.playlistID = playlist.id; media.index = 0
            loadTrack(playlist, media: media, now: now)
        } else if !playlist.tracks.contains(where: { $0.id == media.trackID }) {
            media.index = min(media.index, playlist.tracks.count - 1); loadTrack(playlist, media: media, now: now)
        } else if let index = playlist.tracks.firstIndex(where: { $0.id == media.trackID }) {
            media.index = index
        }
        if media.player.currentItem?.status == .failed {
            store.error = media.player.currentItem?.error?.localizedDescription ?? "再生エラー"
            if lane == .video { videoState.stop() } else { audioState.stop() }; media.stop(); return
        }
        if !media.ready, media.image != nil || media.player.currentItem?.status == .readyToPlay {
            guard !media.seeking else { return }
            if let resumeDate = media.resumeDate {
                media.resumeOffset += Date().timeIntervalSince(resumeDate)
                media.resumeDate = nil
                // Readiness may cross a track boundary; resolve the playlist again in that case.
                if media.resumeOffset >= media.duration {
                    recoveryLanes.insert(lane); media.stop(); return
                }
            }
            if media.image == nil, media.resumeOffset > 0 {
                media.seeking = true
                let item = media.player.currentItem
                let offset = media.resumeOffset
                media.player.seek(to: CMTime(seconds: offset, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak media] finished in
                    Task { @MainActor in
                        guard let self, let media, media.player.currentItem === item else { return }
                        media.seeking = false
                        if finished { self.beginMediaPlayback(lane: lane, media: media, now: ProcessInfo.processInfo.systemUptime, offset: offset) }
                    }
                }
                return
            }
            beginMediaPlayback(lane: lane, media: media, now: now, offset: media.resumeOffset)
        }
        guard media.ready else { return }
        let elapsed = media.image != nil ? now - (media.started ?? now) : media.player.currentTime().seconds
        let fades = lane == .video ? playlist.playbackSettings.videoTrackFades : playlist.playbackSettings.audioTrackFades
        let out = min(fades.fadeOut, media.duration / 2)
        if !media.fadingOut && elapsed.isFinite && elapsed >= media.duration - out {
            media.fadingOut = true
            media.envelope = Envelope(from: media.envelope.value(at: now), to: 0, started: now - max(0, elapsed - (media.duration - out)), duration: out)
        }
        if media.ended || (media.fadingOut && media.envelope.completed(at: now)) {
            media.index = (media.index + 1) % playlist.tracks.count
            loadTrack(playlist, media: media, now: now)
        }
    }
    private func beginMediaPlayback(lane: MediaLane, media: LaneMedia, now: TimeInterval, offset: Double) {
        guard let store, let playlist = store.project.playlist(media.playlistID) else { return }
        media.ready = true; media.started = now - offset; media.resumeOffset = 0
        let fades = lane == .video ? playlist.playbackSettings.videoTrackFades : playlist.playbackSettings.audioTrackFades
        media.envelope = Envelope(from: 0, to: 1, started: now - offset, duration: min(fades.fadeIn, media.duration / 2))
        if media.image == nil { media.player.play() }
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
