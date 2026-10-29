import AppKit
import AVFoundation

/// A plain native window. AVFoundation presents the capture surfaces directly.
@MainActor
public final class PreviewWindow: NSObject, NSWindowDelegate {
    public var onClose: (() -> Void)?
    public private(set) var isClosed = false

    private let window: NSWindow
    private let preview: AVCaptureVideoPreviewLayer

    /// Attach the preview before starting the capture session.
    public init(session: AVCaptureSession, resolution: Resolution,
                transform: VideoTransform, title: String) throws {
        let size = NSSize(width: resolution.width, height: resolution.height)
        let screenSize = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
        let scale = min(1, screenSize.width * 0.85 / size.width,
                        screenSize.height * 0.85 / size.height)
        window = NSWindow(contentRect: NSRect(origin: .zero,
                                             size: NSSize(width: size.width * scale,
                                                          height: size.height * scale)),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init()

        guard let connection = preview.connection else {
            preview.session = nil
            throw CaptureError("preview_unavailable", "The capture session has no video connection for preview.")
        }
        let rotation = transform.nativeRotation
        let mirrored = transform.nativeMirrored
        guard connection.isVideoRotationAngleSupported(CGFloat(rotation)),
              !mirrored || connection.isVideoMirroringSupported else {
            preview.session = nil
            throw CaptureError("unsupported_transform", "The preview connection does not support the requested rotation or flip.")
        }
        connection.videoRotationAngle = CGFloat(rotation)
        connection.automaticallyAdjustsVideoMirroring = false
        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = mirrored
        }

        window.title = title
        window.isReleasedWhenClosed = false
        window.contentAspectRatio = size
        window.minSize = NSSize(width: 160, height: 120)
        window.delegate = self
        let view = PreviewView(preview: preview, frame: NSRect(origin: .zero, size: size))
        window.contentView = view
        window.center()
    }

    public func show() {
        NSApplication.shared.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    public func close() {
        window.close()
    }

    public func windowWillClose(_ notification: Notification) {
        guard !isClosed else { return }
        isClosed = true
        onClose?()
    }
}

@MainActor
private final class PreviewView: NSView {
    private let preview: AVCaptureVideoPreviewLayer

    init(preview: AVCaptureVideoPreviewLayer, frame: NSRect) {
        self.preview = preview
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        preview.videoGravity = .resizeAspect
        layer?.addSublayer(preview)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.frame = bounds
        CATransaction.commit()
    }
}
