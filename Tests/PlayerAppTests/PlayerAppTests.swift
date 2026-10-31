import XCTest
import AppKit
import AVFoundation
import PlayerCore
@testable import GeoBoxPlayer

final class PlayerAppTests: XCTestCase {
    @MainActor func testEditingLockCopyDeleteAndReorder() {
        let store = PlayerStore()
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
    }
    @MainActor func testKindRejectionAndRelativeClipboard() {
        let store = PlayerStore(); store.fileURL = URL(fileURLWithPath: "/tmp/show/project.json")
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
