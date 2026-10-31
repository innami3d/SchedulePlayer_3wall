import AppKit
import AVFoundation
import PlayerCore

@MainActor
final class MediaLibrary: ObservableObject {
    struct Prepared {
        let url: URL
        let asset: AVURLAsset?
        let duration: Double
        let hasAudio: Bool
        let codecs: String
    }
    enum State {
        case loading, ready(Prepared), failed(String)
        var title: String {
            switch self {
            case .loading: return "読み込み中"
            case .ready(let media): return media.asset == nil ? "準備完了" : String(format: "準備完了 · %.1f秒 · %@", media.duration, media.codecs)
            case .failed(let message): return "エラー：" + message
            }
        }
    }
    @Published private(set) var states: [URL: State] = [:]
    private var signatures: [URL: String] = [:]
    private var task: Task<Void, Never>?
    private var generation = 0
    private var preparing = false
    private let images = NSCache<NSURL, NSImage>()
    init() { images.totalCostLimit = 256 * 1024 * 1024 }
    var summary: String {
        let ready = states.values.filter { if case .ready = $0 { return true }; return false }.count
        let failed = states.values.filter { if case .failed = $0 { return true }; return false }.count
        return "素材 \(ready)/\(states.count) 準備完了" + (failed > 0 ? " · \(failed)件エラー" : "")
    }
    func prepared(_ url: URL) -> Prepared? { if case .ready(let media) = states[url] { return media }; return nil }
    func image(_ url: URL) -> NSImage? {
        if let cached = images.object(forKey: url as NSURL) { return cached }
        guard let image = NSImage(contentsOf: url), image.isValid else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let decoded = NSImage(cgImage: cg, size: image.size)
        images.setObject(decoded, forKey: url as NSURL, cost: cg.bytesPerRow * cg.height)
        return decoded
    }
    func prepare(project: PlayerProject, directory: URL?) {
        task?.cancel()
        generation += 1; let currentGeneration = generation; preparing = true
        let tracks = project.playlists.flatMap(\.tracks)
        var unique: [URL: MediaKind] = [:]
        for track in tracks { unique[track.resolvedURL(relativeTo: directory)] = track.kind }
        let retained = Set(unique.keys)
        states = states.filter { retained.contains($0.key) }; signatures = signatures.filter { retained.contains($0.key) }
        task = Task { [weak self] in
            guard let self else { return }
            defer { if generation == currentGeneration { preparing = false } }
            for (url, kind) in unique.sorted(by: { $0.key.path < $1.key.path }) {
                if Task.isCancelled { return }
                do {
                    let info = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
                    guard info.isRegularFile == true else { throw LibraryError.invalidFile }
                    let signature = "\(info.contentModificationDate?.timeIntervalSince1970 ?? 0):\(info.fileSize ?? 0)"
                    if signatures[url] == signature, prepared(url) != nil { continue }
                    states[url] = .loading; images.removeObject(forKey: url as NSURL)
                    if kind == .image {
                        guard image(url) != nil else { throw LibraryError.invalidImage }
                        states[url] = .ready(Prepared(url: url, asset: nil, duration: 0, hasAudio: false, codecs: "画像"))
                    } else {
                        let asset = AVURLAsset(url: url)
                        guard try await asset.load(.isPlayable) else { throw LibraryError.notPlayable }
                        let duration = try await asset.load(.duration).seconds
                        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                        let videoTracks = try await asset.loadTracks(withMediaType: .video)
                        guard duration.isFinite, duration > 0,
                              kind == .video ? !videoTracks.isEmpty : !audioTracks.isEmpty else { throw LibraryError.invalidFile }
                        var codecs: [String] = []
                        for track in videoTracks + audioTracks {
                            for description in try await track.load(.formatDescriptions) {
                                let code = CMFormatDescriptionGetMediaSubType(description)
                                let bytes: [UInt8] = [UInt8((code >> 24) & 255), UInt8((code >> 16) & 255), UInt8((code >> 8) & 255), UInt8(code & 255)]
                                codecs.append(String(bytes: bytes, encoding: .ascii) ?? "不明")
                            }
                        }
                        guard !Task.isCancelled else { return }
                        states[url] = .ready(Prepared(url: url, asset: asset, duration: duration, hasAudio: !audioTracks.isEmpty,
                                                      codecs: Array(Set(codecs)).sorted().joined(separator: " / ")))
                    }
                    signatures[url] = signature
                } catch {
                    guard !Task.isCancelled else { return }
                    states[url] = .failed(error.localizedDescription)
                }
            }
        }
    }
    func refreshIfChanged(project: PlayerProject, directory: URL?) {
        guard !preparing else { return }
        for track in project.playlists.flatMap(\.tracks) {
            let url = track.resolvedURL(relativeTo: directory)
            if let info = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) {
                let signature = "\(info.contentModificationDate?.timeIntervalSince1970 ?? 0):\(info.fileSize ?? 0)"
                if signature != signatures[url] { prepare(project: project, directory: directory); return }
            } else if case .ready = states[url] {
                prepare(project: project, directory: directory); return
            }
        }
    }
    enum LibraryError: LocalizedError {
        case invalidFile, invalidImage, notPlayable
        var errorDescription: String? {
            switch self {
            case .invalidFile: return "ファイルが存在しないか、有効な再生時間・トラックがありません。"
            case .invalidImage: return "画像を読み込めません。"
            case .notPlayable: return "この形式・コーデックをAVFoundationで再生できません。"
            }
        }
    }
}
