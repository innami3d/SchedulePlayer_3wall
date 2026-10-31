import AppKit
import AVFoundation
import SwiftUI

extension NSColor {
    convenience init(hex: String) {
        let rgb = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                  blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}

final class VideoSurface: NSView {
    private let mediaLayer = CALayer()
    private let imageLayer = CALayer()
    private let playerLayer = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(mediaLayer); mediaLayer.addSublayer(imageLayer); mediaLayer.addSublayer(playerLayer)
        imageLayer.contentsGravity = .resizeAspect; playerLayer.videoGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() {
        super.layout(); CATransaction.begin(); CATransaction.setDisableActions(true)
        mediaLayer.frame = bounds; imageLayer.frame = bounds; playerLayer.frame = bounds
        mediaLayer.contentsScale = window?.backingScaleFactor ?? 2
        imageLayer.contentsScale = mediaLayer.contentsScale; playerLayer.contentsScale = mediaLayer.contentsScale
        CATransaction.commit()
    }
    func update(player: AVPlayer, image: NSImage?, opacity: Double, color: NSColor, visible: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.backgroundColor = color.cgColor
        if playerLayer.player !== player { playerLayer.player = player }
        var rect = CGRect(origin: .zero, size: image?.size ?? .zero)
        imageLayer.contents = image?.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        imageLayer.isHidden = image == nil; playerLayer.isHidden = image != nil || !visible
        mediaLayer.opacity = Float(visible ? opacity : 0)
        CATransaction.commit()
    }
}

@MainActor
final class VideoOutput {
    private var window: NSWindow?
    private(set) var displayID: UInt32?
    var surface: VideoSurface? { window?.contentView as? VideoSurface }
    func open(displayID: UInt32) throws {
        guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == displayID }) else {
            throw OutputDevices.DeviceError.missingDisplay
        }
        if self.displayID == displayID, window != nil { window?.setFrame(screen.frame, display: true); return }
        close()
        let output = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        output.isReleasedWhenClosed = false; output.backgroundColor = .black; output.isOpaque = true
        output.ignoresMouseEvents = true; output.hidesOnDeactivate = false
        output.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        output.contentView = VideoSurface(frame: NSRect(origin: .zero, size: screen.frame.size))
        output.setFrame(screen.frame, display: true); output.orderFrontRegardless()
        window = output; self.displayID = displayID
    }
    func close() { window?.close(); window = nil; displayID = nil }
}

struct PreviewSurface: NSViewRepresentable {
    @ObservedObject var engine: PlaybackEngine
    func makeNSView(context: Context) -> VideoSurface { VideoSurface(frame: .zero) }
    func updateNSView(_ view: VideoSurface, context: Context) {
        view.update(player: engine.videoMedia.player, image: engine.videoMedia.image, opacity: engine.videoOpacity,
                    color: NSColor(hex: engine.videoFadeColorHex), visible: engine.videoState.active)
    }
}
