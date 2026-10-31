import XCTest
import AppKit
import AVFoundation
import PlayerCore
@testable import GeoBoxPlayer

final class PlayerAppTests: XCTestCase {
    @MainActor func testTrackInterruptionLoadingLockRestartAndContinuation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let urls = (0..<3).map { directory.appendingPathComponent("\($0).png") }
        for url in urls { try bitmap.representation(using: .png, properties: [:])!.write(to: url) }
        let store = PlayerStore(restoreLastProject: false)
        store.createPlaylist(.video)
        store.addFiles(urls)
        store.playlistBinding(\.playbackSettings.videoTrackFades.fadeIn, fallback: 0).wrappedValue = 2
        store.playlistBinding(\.playbackSettings.fadeColorHex, fallback: "#000000").wrappedValue = "#123456"
        let playlist = try XCTUnwrap(store.selectedPlaylist)
        let engine = store.engine
        defer { engine.stopImmediately() }

        // A later click replaces a request that is still waiting for media.
        engine.playTrack(playlist.tracks[0].id, in: playlist.id)
        engine.playTrack(playlist.tracks[1].id, in: playlist.id)
        for _ in 0..<100 {
            engine.tick()
            if engine.videoMedia.ready { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(engine.currentTrack(.video)?.id, playlist.tracks[1].id)
        XCTAssertTrue(engine.videoMedia.ready)
        XCTAssertEqual(engine.videoMedia.envelope.duration, 2)
        XCTAssertEqual(engine.videoFadeColorHex, "#123456")
        let project = store.project
        store.locked = true
        engine.playTrack(playlist.tracks[0].id, in: playlist.id)
        XCTAssertEqual(engine.currentTrack(.video)?.id, playlist.tracks[1].id)
        store.locked = false

        // Clicking the playing track restarts it; its natural successor follows.
        engine.playTrack(playlist.tracks[1].id, in: playlist.id)
        XCTAssertFalse(engine.videoMedia.ready)
        engine.tick()
        let started = try XCTUnwrap(engine.videoMedia.started)
        engine.tick(now: started + 21)
        XCTAssertEqual(engine.currentTrack(.video)?.id, playlist.tracks[2].id)
        engine.tick(now: started + 22)
        engine.tick(now: started + 43)
        XCTAssertEqual(engine.currentTrack(.video)?.id, playlist.tracks[0].id)
        XCTAssertEqual(store.project, project, "Manual playback must not edit the project")

        store.createPlaylist(.video)
        store.addFiles([urls[0]])
        let other = try XCTUnwrap(store.selectedPlaylist)
        engine.playTrack(other.tracks[0].id, in: other.id)
        XCTAssertEqual(engine.videoState.playlistID, other.id)
        XCTAssertEqual(engine.currentTrack(.video)?.id, other.tracks[0].id)
        XCTAssertEqual(engine.videoFadeColorHex, "#000000")
        engine.playTrack(UUID(), in: playlist.id)
        XCTAssertEqual(engine.videoState.playlistID, other.id)
    }

    @MainActor func testLongImageDurationForNewAndLegacyProjects() throws {
        for legacy in [false, true] {
            let store = PlayerStore(restoreLastProject: false)
            if legacy {
                var old = PlayerProject()
                old.defaults.imageMax = 3600
                store.project = try PlayerProject.decode(old.encoded())
            }
            store.createPlaylist(.video)
            store.addFiles([URL(fileURLWithPath: "/tmp/long-still.jpg")])
            store.selectTrack(try XCTUnwrap(store.selectedPlaylist?.tracks.first?.id))
            let field = ImageDurationField(seconds: store.trackBinding(\.imageDuration, fallback: 20),
                                           maximum: store.project.defaults.imageMax)
            field.value(in: .hours).wrappedValue = 25
            field.value(in: .minutes).wrappedValue = 30
            field.value(in: .seconds).wrappedValue = 15.5
            XCTAssertEqual(store.selectedTrack?.imageDuration, 91815.5)
            let restored = try PlayerProject.decode(store.project.encoded())
            XCTAssertEqual(restored.playlists[0].tracks[0].imageDuration, 91815.5)
            XCTAssertEqual(ScheduledTrackPosition.resolve(durations: [91815.5, 20], elapsed: 7200)?.index, 0)
            XCTAssertEqual(ScheduledTrackPosition.resolve(durations: [91815.5, 20], elapsed: 91815.5)?.index, 1)
            field.value(in: .hours).wrappedValue = 168
            XCTAssertEqual(store.selectedTrack?.imageDuration, 604800)
            XCTAssertNoThrow(try store.project.validate())
        }
    }

    @MainActor func testImageDurationComponentsPreserveOtherFieldsAndProjectCompatibility() throws {
        let store = PlayerStore(restoreLastProject: false)
        store.createPlaylist(.video)
        store.change { $0.defaults.imageMax = 10800 }
        store.addFiles([URL(fileURLWithPath: "/tmp/still.jpg")])
        store.selectTrack(try XCTUnwrap(store.selectedPlaylist?.tracks.first?.id))
        let field = ImageDurationField(seconds: store.trackBinding(\.imageDuration, fallback: 20), maximum: 10800)

        XCTAssertEqual(field.value(in: .seconds).wrappedValue, 20)
        XCTAssertEqual(field.value(in: .minutes).wrappedValue, 0)
        XCTAssertEqual(field.value(in: .hours).wrappedValue, 0)
        field.value(in: .hours).wrappedValue = 1
        field.value(in: .minutes).wrappedValue = 2
        field.value(in: .seconds).wrappedValue = 3.5
        XCTAssertEqual(store.selectedTrack?.imageDuration, 3723.5)
        XCTAssertEqual(field.value(in: .hours).wrappedValue, 1)
        XCTAssertEqual(field.value(in: .minutes).wrappedValue, 2)
        XCTAssertEqual(field.value(in: .seconds).wrappedValue, 3.5)
        let restored = try PlayerProject.decode(store.project.encoded())
        XCTAssertEqual(restored.playlists[0].tracks[0].imageDuration, 3723.5)
        store.undo()
        XCTAssertEqual(store.selectedTrack?.imageDuration, 3740)

        field.value(in: .hours).wrappedValue = 3
        XCTAssertEqual(store.selectedTrack?.imageDuration, 10800)
        field.value(in: .hours).wrappedValue = 0
        XCTAssertEqual(store.selectedTrack?.imageDuration, 0.1)
        field.value(in: .seconds).wrappedValue = 0
        XCTAssertEqual(store.selectedTrack?.imageDuration, 0.1)
        field.value(in: .seconds).wrappedValue = .nan
        XCTAssertEqual(store.selectedTrack?.imageDuration, 0.1)
        store.locked = true
        field.value(in: .minutes).wrappedValue = 1
        XCTAssertEqual(store.selectedTrack?.imageDuration, 0.1)
    }

    @MainActor func testEditingLockCopyDeleteAndReorder() {
        let store = PlayerStore(restoreLastProject: false)
        store.createPlaylist(.video)
        let originalID = store.selectedPlaylistID
        store.addFiles([URL(fileURLWithPath: "/tmp/first.mp4"), URL(fileURLWithPath: "/tmp/second.jpg")])
        let first = store.selectedPlaylist!.tracks[0], second = store.selectedPlaylist!.tracks[1]
        store.moveTrack(second.id, before: first.id)
        XCTAssertEqual(store.selectedPlaylist!.tracks.map(\.id), [second.id, first.id])
        store.selectTrack(first.id); store.duplicate()
        XCTAssertEqual(store.selectedPlaylist!.tracks.count, 3)
        XCTAssertNotEqual(store.selectedTrackID, first.id)
        store.deleteSelection(); XCTAssertEqual(store.selectedPlaylist!.tracks.count, 2)
        store.selectPlaylist(originalID!); store.duplicate()
        XCTAssertEqual(store.project.playlists.count, 2)
        XCTAssertNotEqual(store.selectedPlaylistID, originalID)
        let before = store.project
        store.locked = true; store.deleteSelection(); store.createPlaylist(.audio); store.undo(); store.paste()
        XCTAssertEqual(store.project, before)
        store.locked = false; store.undo(); XCTAssertEqual(store.project.playlists.count, 1)
        store.selectedPlaylistID = originalID; store.selection = .track; store.selectedTrackID = nil
        store.deleteSelection()
        XCTAssertEqual(store.project.playlists.count, 1, "Empty track selection must never delete its parent playlist")
    }
    @MainActor func testKindRejectionAndRelativeClipboard() {
        let store = PlayerStore(restoreLastProject: false); store.fileURL = URL(fileURLWithPath: "/tmp/show/project.json")
        store.createPlaylist(.video)
        store.change { $0.playlists[0].tracks = [.init(path: "Media/a.mov", kind: .video)] }
        store.selectTrack(store.selectedPlaylist!.tracks[0].id); store.copySelection()
        store.createPlaylist(.audio); store.selection = .track
        XCTAssertFalse(store.canPaste)
        store.createPlaylist(.video); store.selection = .track; store.paste()
        XCTAssertEqual(store.selectedPlaylist!.tracks.first?.path, "/tmp/show/Media/a.mov")
    }
    @MainActor func testImageAndAudioPreparationAndMissingFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("still.png"), audioURL = directory.appendingPathComponent("sound.wav")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.setColor(.red, atX: 0, y: 0)
        try bitmap.representation(using: .png, properties: [:])!.write(to: imageURL)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = 4800
        for i in 0..<4800 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 48000) * 0.1) }
        do {
            let audioFile = try AVAudioFile(forWriting: audioURL, settings: format.settings)
            try audioFile.write(from: buffer)
        }
        var project = PlayerProject(), video = Playlist(name: "映像", lane: .video), audio = Playlist(name: "音声", lane: .audio)
        video.tracks = [.init(path: imageURL.path, kind: .image)]
        audio.tracks = [.init(path: audioURL.path, kind: .audio), .init(path: directory.appendingPathComponent("missing.wav").path, kind: .audio)]
        project.playlists = [video, audio]
        let library = MediaLibrary(); library.prepare(project: project, directory: nil)
        for _ in 0..<200 {
            if library.prepared(imageURL) != nil, library.prepared(audioURL) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(library.image(imageURL)); XCTAssertNotNil(library.prepared(imageURL))
        XCTAssertEqual(try XCTUnwrap(library.prepared(audioURL), library.states[audioURL]?.title ?? "No state").duration, 0.1, accuracy: 0.02)
        if case .failed = library.states[directory.appendingPathComponent("missing.wav")] {} else { XCTFail("Missing file must fail") }
    }
}

extension PlayerAppTests {
    @MainActor func testCacheRefreshAfterReferencedFileAppears() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("later.png")
        var project = PlayerProject(), playlist = Playlist(name: "Cache", lane: .video)
        let track = MediaTrack(path: url.path, kind: .image)
        playlist.tracks = [track, track.duplicated()]; project.playlists = [playlist]
        let library = MediaLibrary(); library.prepare(project: project, directory: nil)
        for _ in 0..<50 {
            if case .failed = library.states[url] { break }; try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(library.states.count, 1, "Same path must share its cache")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
        library.refreshIfChanged(project: project, directory: nil)
        for _ in 0..<100 {
            if library.prepared(url) != nil { break }; try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(library.prepared(url))
    }
    @MainActor func testSaveAndReopenWithRelativePaths() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PlayerStore(restoreLastProject: false)
        store.createPlaylist(.video); store.addFiles([directory.appendingPathComponent("clip.mov")])
        store.fileURL = directory.appendingPathComponent("project.player")
        XCTAssertTrue(store.save())
        let read = try PlayerProject.decode(Data(contentsOf: store.fileURL!))
        XCTAssertEqual(read.playlists[0].tracks[0].path, "clip.mov")
        XCTAssertFalse(store.isDirty)
        let reopened = PlayerStore(restoreLastProject: false); reopened.openProject(at: store.fileURL!)
        XCTAssertEqual(reopened.project, read)
    }
    @MainActor func testMP4H264AndMOVProResDecode() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (codec, fileType, ext) in [(AVVideoCodecType.h264, AVFileType.mp4, "mp4"), (.proRes422, .mov, "mov")] {
            let url = directory.appendingPathComponent("sample.\(ext)")
            let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: codec, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64
            ])
            writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
            var pixelBuffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32ARGB, nil, &pixelBuffer), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixelBuffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), 255, CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            for frame in 0..<6 {
                var attempts = 0
                while !input.isReadyForMoreMediaData, attempts < 500 { attempts += 1; try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
            }
            input.markAsFinished(); await writer.finishWriting()
            XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            let decoded = try await generator.image(at: .zero)
            XCTAssertEqual(decoded.image.width, 64)
            var project = PlayerProject(), playlist = Playlist(name: "Decode", lane: .video)
            playlist.tracks = [.init(path: url.path, kind: .video)]; project.playlists = [playlist]
            let library = MediaLibrary(); library.prepare(project: project, directory: nil)
            for _ in 0..<200 {
                if library.prepared(url) != nil { break }; try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNotNil(library.prepared(url), library.states[url]?.title ?? "No state")
        }
    }
}

extension PlayerAppTests {
    @MainActor func testDisplayReconnectUsesPersistentIdentityInsteadOfRecycledNumber() {
        let other = OutputDevices.Display(id: 10, name: "同じ名前", rates: [30], uuid: "other")
        let reconnected = OutputDevices.Display(id: 99, name: "同じ名前", rates: [30], uuid: "saved")
        XCTAssertEqual(OutputDevices.matchingDisplay(id: 10, uuid: "saved", in: [other, reconnected])?.id, 99)
        XCTAssertNil(OutputDevices.matchingDisplay(id: 10, uuid: "saved", in: [other]))
        XCTAssertEqual(OutputDevices.matchingDisplay(id: 10, uuid: nil, in: [other])?.id, 10)
        XCTAssertNil(OutputDevices.matchingDisplay(id: nil, uuid: nil, in: [other]))
    }
}

extension PlayerAppTests {
    @MainActor func testMissingAudioMutesBothPlayersAndRecoversWithoutRestartingPlayback() {
        let store = PlayerStore(restoreLastProject: false)
        store.project.audio.fades = .init(fadeIn: 0, fadeOut: 0)
        let engine = store.engine
        engine.startProject()
        defer { engine.stopImmediately() }
        XCTAssertTrue(engine.audioGate.active)
        store.project.audioDeviceUID = "missing-" + UUID().uuidString
        engine.reconnectDevices()
        XCTAssertTrue(engine.audioDisconnected)
        XCTAssertTrue(engine.audioGate.active, "Keep the playback session alive while waiting for its device")
        XCTAssertTrue(engine.videoMedia.player.isMuted); XCTAssertTrue(engine.audioMedia.player.isMuted)
        store.project.audioDeviceUID = nil
        engine.reconnectDevices()
        XCTAssertFalse(engine.audioDisconnected)
        XCTAssertFalse(engine.videoMedia.player.isMuted); XCTAssertFalse(engine.audioMedia.player.isMuted)
        engine.endProject()
        engine.reconnectDevices()
        XCTAssertFalse(engine.audioGate.active, "A device becoming available must not restart a stopped output")
    }
}

extension PlayerAppTests {
    @MainActor func testScheduledRecoverySeeksAudioAfterPreparationAndRespectsStop() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("resume.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000 * 120)!
        buffer.frameLength = buffer.frameCapacity
        memset(buffer.floatChannelData![0], 0, Int(buffer.frameLength) * MemoryLayout<Float>.size)
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        let store = PlayerStore(restoreLastProject: false)
        defer { store.engine.stopImmediately() }
        let date = Date()
        store.project.video.end = store.project.video.start // Do not open a display during the test.
        store.project.audio.start = .at(date.addingTimeInterval(-60))
        store.project.audio.end = .at(date.addingTimeInterval(60))
        store.project.audio.fades = .init(fadeIn: 0, fadeOut: 0)
        var playlist = Playlist(name: "Scheduled audio", lane: .audio)
        playlist.playbackSettings.audioTrackFades = .init(fadeIn: 8, fadeOut: 4)
        playlist.playbackSettings.videoTrackFades = .init(fadeIn: 1, fadeOut: 2)
        playlist.tracks = [.init(path: url.path, kind: .audio)]
        playlist.start = store.project.audio.start
        store.project.playlists = [playlist]
        store.project.calendarEntries = [CalendarEntry(playlistID: playlist.id, start: date.addingTimeInterval(-60), end: date.addingTimeInterval(60), fades: .init(fadeIn: 0, fadeOut: 0))]
        store.engine.resetSchedule(reconcile: true)
        store.engine.tick()
        XCTAssertFalse(store.engine.audioGate.active, "Wait for metadata before starting recovery")
        store.prepareMedia()
        for _ in 0..<250 {
            store.engine.tick()
            if store.engine.audioMedia.ready { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.engine.audioState.playlistID, playlist.id)
        XCTAssertEqual(store.engine.audioMedia.trackID, playlist.tracks[0].id)
        XCTAssertTrue(store.engine.audioMedia.ready)
        XCTAssertEqual(store.engine.audioMedia.player.currentTime().seconds, 60, accuracy: 3)
        XCTAssertEqual(store.engine.audioMedia.envelope.duration, 8)
        XCTAssertFalse(store.engine.videoGate.active)
        store.engine.endProject()
        store.engine.tick()
        XCTAssertFalse(store.engine.audioGate.active)
        // A manual stop also cancels recovery still waiting for metadata.
        store.engine.resetSchedule(reconcile: true)
        store.engine.endProject()
        store.engine.tick(now: ProcessInfo.processInfo.systemUptime + 1)
        XCTAssertFalse(store.engine.audioGate.active)
    }
}

extension PlayerAppTests {
    @MainActor func testPreviewWithoutOutputDevicesForManualProjectAndScheduledPlayback() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("preview.png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
        let store = PlayerStore(restoreLastProject: false)
        let engine = store.engine
        defer { engine.stopImmediately() }
        store.project.video.fades = .init(fadeIn: 0, fadeOut: 0)
        store.project.audio.fades = .init(fadeIn: 0, fadeOut: 0)
        var playlist = Playlist(name: "Preview", lane: .video)
        playlist.fades = .init(fadeIn: 0, fadeOut: 0)
        playlist.tracks = [.init(path: url.path, kind: .image, imageDuration: 120)]
        store.project.playlists = [playlist]; store.selectedPlaylistID = playlist.id
        store.prepareMedia()
        for _ in 0..<100 {
            if store.library.prepared(url) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(store.library.prepared(url))
        // No display or audio device has been explicitly selected.
        engine.play(playlist.id); engine.tick()
        XCTAssertEqual(engine.videoState.playlistID, playlist.id)
        XCTAssertNotNil(engine.videoMedia.image)
        XCTAssertEqual(engine.videoOpacity, 1)
        XCTAssertFalse(engine.videoDisconnected)
        XCTAssertTrue(engine.status.contains("プレビューのみ"))
        XCTAssertNil(store.error)
        engine.stopImmediately()
        // An unavailable saved audio device must not prevent video preview either.
        store.project.audioDeviceUID = "missing-" + UUID().uuidString
        engine.startProject(); engine.tick()
        XCTAssertEqual(engine.videoState.playlistID, playlist.id)
        XCTAssertEqual(engine.videoOpacity, 1)
        XCTAssertTrue(engine.audioDisconnected)
        XCTAssertTrue(engine.videoMedia.player.isMuted)
        XCTAssertTrue(engine.audioMedia.player.isMuted)
        XCTAssertNil(store.error)
        engine.stopImmediately()
        // Automatic startup recovery shares the same output-independent preview behavior.
        let date = Date()
        store.project.video.start = .at(date.addingTimeInterval(-5))
        store.project.video.end = .at(date.addingTimeInterval(60))
        store.project.calendarEntries = [CalendarEntry(playlistID: playlist.id, start: date.addingTimeInterval(-5), end: date.addingTimeInterval(60), fades: .init(fadeIn: 0, fadeOut: 0))]
        store.project.audio.end = store.project.audio.start
        engine.resetSchedule(reconcile: true); engine.tick()
        XCTAssertEqual(engine.videoState.playlistID, playlist.id)
        XCTAssertNotNil(engine.videoMedia.image)
        XCTAssertEqual(engine.videoOpacity, 1)
        XCTAssertFalse(engine.videoDisconnected)
        let started = try XCTUnwrap(engine.videoMedia.started)
        XCTAssertEqual(ProcessInfo.processInfo.systemUptime - started, 5, accuracy: 1.5)
    }
}

extension PlayerAppTests {
    @MainActor func testSaveOverwritesOpenedProjectsIncludingLegacyExtensions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for filename in ["existing.player", "legacy.geobox.json", "existing.json"] {
            let url = directory.appendingPathComponent(filename)
            var original = PlayerProject(); original.name = "Before"
            try original.encoded().write(to: url)
            let store = PlayerStore(restoreLastProject: false)
            store.openProject(at: url)
            XCTAssertEqual(store.project.name, url.deletingPathExtension().lastPathComponent)
            XCTAssertFalse(store.isDirty)
            store.change { $0.defaults.imageDuration = 30 }
            XCTAssertTrue(store.isDirty)
            XCTAssertTrue(store.save())
            XCTAssertEqual(store.fileURL, url)
            XCTAssertFalse(store.isDirty)
            let saved = try PlayerProject.decode(Data(contentsOf: url))
            XCTAssertEqual(saved.name, url.deletingPathExtension().lastPathComponent)
            XCTAssertEqual(saved.defaults.imageDuration, 30)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 3)
    }

    @MainActor func testProjectNameFollowsSaveDestinationAndRenamedFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PlayerStore(restoreLastProject: false)
        XCTAssertEqual(store.project.name, "新規プロジェクト")
        let destination = directory.appendingPathComponent("展示.夜間.player")
        store.fileURL = destination
        XCTAssertTrue(store.save())
        XCTAssertEqual(store.project.name, "展示.夜間")
        XCTAssertEqual(try PlayerProject.decode(Data(contentsOf: destination)).name, "展示.夜間")

        let renamed = directory.appendingPathComponent("展示.昼間.player")
        try FileManager.default.moveItem(at: destination, to: renamed)
        store.openProject(at: renamed)
        XCTAssertEqual(store.project.name, "展示.昼間")
        XCTAssertTrue(store.save())
        XCTAssertEqual(try PlayerProject.decode(Data(contentsOf: renamed)).name, "展示.昼間")
        store.change { $0.defaults.imageDuration = 45 }
        store.undo()
        XCTAssertEqual(store.project.name, "展示.昼間")
        store.redo()
        XCTAssertEqual(store.project.name, "展示.昼間")
        XCTAssertTrue(store.save())
        store.newProject()
        XCTAssertEqual(store.project.name, "新規プロジェクト")
    }
}

extension PlayerAppTests {
    @MainActor func testCalendarDropUndoLockDeleteAndSave() throws {
        let store = PlayerStore(restoreLastProject: false)
        store.createPlaylist(.video)
        let playlist = try XCTUnwrap(store.selectedPlaylist)
        XCTAssertNil(store.project.video.initialPlaylistID)
        let start = Date()
        let id = try XCTUnwrap(store.addCalendarEntry(playlistID: playlist.id, start: start))
        XCTAssertEqual(store.project.calendarEntries?.first?.end, start.addingTimeInterval(3600))
        store.undo(); XCTAssertTrue(store.project.calendarEntries?.isEmpty == true)
        store.redo(); XCTAssertEqual(store.project.calendarEntries?.first?.id, id)
        store.locked = true
        XCTAssertNil(store.addCalendarEntry(playlistID: playlist.id, start: start))
        store.locked = false
        store.selectScheduler(); XCTAssertTrue(store.showingScheduler)
        store.selectPlaylist(playlist.id); XCTAssertFalse(store.showingScheduler)
        store.deleteSelection()
        XCTAssertTrue(store.project.calendarEntries?.isEmpty == true)
        try store.project.validate()
        store.undo()
        XCTAssertEqual(store.project.calendarEntries?.first?.playlistID, playlist.id)
    }
}

extension PlayerAppTests {
    @MainActor func testRecurringScopeChangeIsAtomicUndoableAndLocked() throws {
        let store = PlayerStore(restoreLastProject: false)
        store.createPlaylist(.video)
        let id = try XCTUnwrap(store.selectedPlaylistID)
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(10 * 3600)
        let series = CalendarEntry(playlistID: id, start: start, end: start.addingTimeInterval(3600), repetition: .daily)
        store.change { $0.calendarEntries = [series] }
        let before = store.project
        var draft = series
        draft.start = Calendar.current.date(byAdding: .day, value: 3, to: start)!
        draft.end = draft.start.addingTimeInterval(7200)
        store.editCalendarEntry(id: series.id, occurrenceStart: draft.start, replacement: draft, scope: .following)
        let after = store.project
        XCTAssertEqual(after.calendarEntries?.count, 2)
        store.undo(); XCTAssertEqual(store.project, before)
        store.redo(); XCTAssertEqual(store.project, after)
        store.locked = true
        store.editCalendarEntry(id: series.id, occurrenceStart: start, replacement: nil, scope: .all)
        XCTAssertEqual(store.project, after)
        store.locked = false
        store.selectPlaylist(id); store.deleteSelection()
        XCTAssertTrue(store.project.calendarEntries?.isEmpty == true)
        try store.project.validate()
    }
}

extension PlayerAppTests {
    @MainActor func testScheduledVideoSoundWithoutAudioScheduleAndSuppressionRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let silentURL = directory.appendingPathComponent("silent.mov")
        let soundURL = directory.appendingPathComponent("sound.wav")
        let movieURL = directory.appendingPathComponent("with-sound.mov")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let samples = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000 * 4)!
        samples.frameLength = samples.frameCapacity
        for index in 0..<Int(samples.frameLength) {
            samples.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * 440 / 8000) * 0.1)
        }
        do { let file = try AVAudioFile(forWriting: soundURL, settings: format.settings); try file.write(from: samples) }
        let writer = try AVAssetWriter(outputURL: silentURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 16])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 16, kCVPixelBufferHeightKey as String: 16
        ])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32ARGB, nil, &pixel), kCVReturnSuccess)
        let bitmap = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(bitmap, [])
        memset(CVPixelBufferGetBaseAddress(bitmap), 127, CVPixelBufferGetDataSize(bitmap))
        CVPixelBufferUnlockBaseAddress(bitmap, [])
        for frame in 0..<120 {
            var attempts = 0
            while !input.isReadyForMoreMediaData, attempts < 200 { attempts += 1; try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(adaptor.append(bitmap, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished(); await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        let composition = AVMutableComposition()
        let videoSource = AVURLAsset(url: silentURL), audioSource = AVURLAsset(url: soundURL)
        let videoTracks = try await videoSource.loadTracks(withMediaType: .video)
        let audioTracks = try await audioSource.loadTracks(withMediaType: .audio)
        let duration = try await videoSource.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(range, of: XCTUnwrap(videoTracks.first), at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(range, of: XCTUnwrap(audioTracks.first), at: .zero)
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
        exporter.outputURL = movieURL; exporter.outputFileType = .mov
        await exporter.export()
        XCTAssertEqual(exporter.status, .completed, exporter.error?.localizedDescription ?? "")

        let store = PlayerStore(restoreLastProject: false), now = Date()
        let engine = store.engine
        defer { engine.stopImmediately() }
        var video = Playlist(name: "動画内音声", lane: .video)
        video.tracks = [.init(path: movieURL.path, kind: .video, volume: 0.4)]
        var audio = Playlist(name: "独立音声", lane: .audio)
        audio.tracks = [.init(path: soundURL.path, kind: .audio)]
        store.project.playlists = [video, audio]
        let entry = CalendarEntry(playlistID: video.id, start: now.addingTimeInterval(-1), end: now.addingTimeInterval(120), fades: .init(fadeIn: 0, fadeOut: 0))
        store.project.calendarEntries = [entry]
        store.prepareMedia()
        for _ in 0..<200 {
            if store.library.prepared(movieURL) != nil, store.library.prepared(soundURL) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(try XCTUnwrap(store.library.prepared(movieURL)).hasAudio)
        engine.resetSchedule(reconcile: true)
        for _ in 0..<200 {
            engine.tick()
            if engine.videoMedia.ready { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        engine.tick()
        XCTAssertFalse(engine.audioGate.active, "No independent audio schedule is needed for video sound")
        XCTAssertFalse(engine.audioState.active)
        XCTAssertEqual(engine.videoMedia.player.volume, 0.4, accuracy: 0.001)
        XCTAssertFalse(engine.videoMedia.player.isMuted)
        XCTAssertTrue(engine.suppressionReasons.isEmpty)
        XCTAssertTrue(engine.status.contains("動画内音声（再生中）"))
        store.change { $0.playlists[0].muted = true }; engine.tick()
        XCTAssertEqual(engine.videoMedia.player.volume, 0)
        XCTAssertTrue(engine.status.contains("動画内音声（ミュート中）"))
        store.change { $0.playlists[0].muted = false }

        store.change { $0.calendarEntries?.append(.init(playlistID: audio.id, start: now.addingTimeInterval(-1), end: now.addingTimeInterval(120), fades: .init(fadeIn: 0, fadeOut: 0))) }
        engine.resetSchedule(reconcile: true)
        for _ in 0..<200 {
            engine.tick()
            if engine.audioMedia.ready && engine.videoMedia.ready { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        engine.tick()
        XCTAssertEqual(engine.videoMedia.player.volume, 0, "The independent audio playlist still takes priority")
        XCTAssertGreaterThan(engine.audioMedia.player.volume, 0)
        XCTAssertTrue(engine.status.contains("音声プレイリスト"))
        store.change { $0.calendarEntries?.removeAll { $0.playlistID == audio.id } }
        engine.resetSchedule(reconcile: true)
        for _ in 0..<200 {
            engine.tick()
            if engine.videoMedia.ready && !engine.audioGate.active { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        engine.tick()
        XCTAssertEqual(engine.videoMedia.player.volume, 0.4, accuracy: 0.001)
        store.project.audioDeviceUID = "missing-" + UUID().uuidString
        engine.reconnectDevices(); engine.tick()
        XCTAssertTrue(engine.audioDisconnected)
        XCTAssertTrue(engine.videoMedia.player.isMuted)
        store.project.audioDeviceUID = nil
        engine.reconnectDevices(); engine.tick()
        XCTAssertFalse(engine.audioDisconnected)
        XCTAssertFalse(engine.videoMedia.player.isMuted)
        XCTAssertEqual(engine.videoMedia.player.volume, 0.4, accuracy: 0.001)
        // Video sound follows the video's scheduled fade even while the audio lane is stopped.
        store.change { $0.calendarEntries?[0].fades.fadeIn = 10 }
        engine.resetSchedule(reconcile: true)
        for _ in 0..<200 {
            engine.tick()
            if engine.videoMedia.ready { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        engine.tick()
        XCTAssertFalse(engine.audioGate.active)
        XCTAssertEqual(engine.videoMedia.player.volume, Float(engine.videoOpacity * 0.4), accuracy: 0.001)
        XCTAssertGreaterThan(engine.videoMedia.player.volume, 0)
        engine.tick(date: entry.end.addingTimeInterval(1))
        XCTAssertEqual(engine.videoMedia.player.volume, 0)
    }
}
