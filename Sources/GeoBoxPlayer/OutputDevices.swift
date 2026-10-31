import AppKit
import AVFoundation
import CoreAudio

@MainActor
final class OutputDevices: ObservableObject {
    struct Display: Identifiable {
        var id: CGDirectDisplayID
        var name: String
        var rates: [Double]
    }
    struct Audio: Identifiable { var id: String; var name: String }
    @Published private(set) var displays: [Display] = []
    @Published private(set) var audio: [Audio] = []
    private var screenObserver: NSObjectProtocol?
    private var originalModes: [CGDirectDisplayID: CGDisplayMode] = [:]
    init() {
        refresh()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func refresh() {
        displays = NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return nil }
            let rates = Array(Set(Self.modes(id).map(\.refreshRate).filter { $0 > 0 })).sorted()
            return Display(id: id, name: screen.localizedName, rates: rates)
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { audio = []; return }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { audio = []; return }
        audio = ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0,
                  let uid = Self.string(id, kAudioDevicePropertyDeviceUID), let name = Self.string(id, kAudioObjectPropertyName) else { return nil }
            return Audio(id: uid, name: name)
        }
    }
    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
    static func modes(_ id: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []).filter {
            ($0.pixelWidth == 3840 && $0.pixelHeight == 2160) || ($0.pixelWidth == 4096 && $0.pixelHeight == 2160)
        }
    }
    func activate4K(displayID: CGDirectDisplayID, refreshRate: Double) throws {
        guard NSScreen.screens.contains(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == displayID }) else { throw DeviceError.missingDisplay }
        let options = Self.modes(displayID).filter { abs($0.refreshRate - refreshRate) < 0.1 }
        guard let mode = options.sorted(by: { $0.width > $1.width }).first else { throw DeviceError.unsupportedMode }
        if originalModes[displayID] == nil { originalModes[displayID] = CGDisplayCopyDisplayMode(displayID) }
        guard CGDisplaySetDisplayMode(displayID, mode, nil) == .success else { throw DeviceError.modeFailed }
    }
    func restoreModes() {
        for (id, mode) in originalModes { _ = CGDisplaySetDisplayMode(id, mode, nil) }
        originalModes.removeAll()
    }
    enum DeviceError: LocalizedError {
        case missingDisplay, unsupportedMode, modeFailed, missingAudio
        var errorDescription: String? {
            switch self {
            case .missingDisplay: return "映像出力先が接続されていません。"
            case .unsupportedMode: return "選択した出力先に、指定した送出リフレッシュレートの4Kモードがありません。"
            case .modeFailed: return "4K出力モードへ切り替えられませんでした。"
            case .missingAudio: return "選択した音声出力先が接続されていません。"
            }
        }
    }
}
