import XCTest
import AppKit
import AVFoundation
import PlayerCore
@testable import GeoBoxPlayer

final class PlayerAppTests: XCTestCase {
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
        store.fileURL = directory.appendingPathComponent("project.geobox.json")
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
