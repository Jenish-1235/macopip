import AppKit
import CoreMedia
import ScreenCaptureKit

/// One pinned window: a ScreenCaptureKit stream of the source window rendered into a floating panel.
@MainActor
final class PiPController: NSObject {
    let windowID: CGWindowID
    let pid: pid_t
    var onClose: ((PiPController) -> Void)?

    private let filter: SCContentFilter
    private let panel: PiPPanel
    private let view: PiPView
    private var stream: SCStream?
    private let frameQueue = DispatchQueue(label: "macopip.frames", qos: .userInteractive)
    private let output = FrameOutput()

    private var sourceSize: CGSize
    /// Source window frame in global display coordinates (top-left origin), refreshed every second.
    private var sourceBounds: CGRect
    /// Where the window's content sits in the latest captured frame.
    private var frameGeometry: FrameGeometry?
    private var askedForEventAccess = false
    private var watchTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var userHidden = false
    private var sourceIsFrontmost = false
    private var closed = false

    private static let activeFPS = 60
    private static let hiddenFPS = 2

    init(window: SCWindow, appName: String, stackIndex: Int) {
        windowID = window.windowID
        pid = window.owningApplication?.processID ?? 0
        filter = SCContentFilter(desktopIndependentWindow: window)
        sourceSize = window.frame.size
        sourceBounds = window.frame

        let title = (window.title ?? "").isEmpty ? appName : "\(appName) — \(window.title!)"
        view = PiPView(title: title)
        view.aspectRatio = Self.aspect(of: sourceSize)
        panel = PiPPanel(contentRect: Self.initialFrame(aspect: view.aspectRatio, stackIndex: stackIndex))
        panel.contentView = view
        panel.alphaValue = Settings.opacity
        super.init()

        view.onClose = { [weak self] in self?.close() }
        view.onJump = { [weak self] in self?.jumpToSource() }
        view.onOpacityStep = { [weak self] step in self?.stepOpacity(step) }
        view.onFrameCommitted = { [weak self] in self?.saveFrame() }
        view.onScroll = { [weak self] event, point in self?.forwardScroll(event, at: point) }
        view.onMouse = { [weak self] event, point in self?.forwardMouse(event, at: point) }

        output.onFrame = { [weak self] surface, geometry in
            self?.view.display(surface)
            if let geometry { self?.frameGeometry = geometry }
        }
        output.onStop = { [weak self] in self?.close() }
    }

    func start() async throws {
        let stream = SCStream(filter: filter, configuration: makeConfiguration(fps: Self.activeFPS), delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: frameQueue)
        try await stream.startCapture()
        self.stream = stream

        panel.orderFrontRegardless()

        watchTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSource() }
        }
        // Hide while you're looking at the real window; reappear when you switch away.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sourceIsFrontmost = app?.processIdentifier == self.pid
                self.updateVisibility()
            }
        }
    }

    func setUserHidden(_ hidden: Bool) {
        userHidden = hidden
        updateVisibility()
    }

    func close() {
        guard !closed else { return }
        closed = true
        saveFrame()
        watchTimer?.invalidate()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        stream?.stopCapture { _ in }
        stream = nil
        panel.orderOut(nil)
        onClose?(self)
    }

    func jumpToSource() {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        // A background app can't reliably activate others on macOS 14+; asking Workspace to
        // "open" the running app does, and it switches to the app's Space.
        if let url = app.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        } else {
            app.activate()
        }
    }

    // MARK: - Private

    private func updateVisibility() {
        let visible = !userHidden && !sourceIsFrontmost
        if visible {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
        applyConfiguration(fps: visible ? Self.activeFPS : Self.hiddenFPS)
    }

    private func stepOpacity(_ step: CGFloat) {
        let value = min(1, max(0.25, panel.alphaValue + step))
        panel.alphaValue = value
        Settings.opacity = value
    }

    /// Tracks the source window: closes when it goes away, follows its size and title.
    private func checkSource() {
        guard let info = WindowCatalog.info(for: windowID) else { close(); return }
        if !info.title.isEmpty, let appName = NSRunningApplication(processIdentifier: pid)?.localizedName {
            view.title = "\(appName) — \(info.title)"
        }

        sourceBounds = info.bounds
        let size = info.bounds.size
        guard abs(size.width - sourceSize.width) > 1 || abs(size.height - sourceSize.height) > 1 else { return }
        sourceSize = size
        view.aspectRatio = Self.aspect(of: size)

        // Keep the width and the top edge, adjust height to the new aspect ratio.
        var frame = panel.frame
        let newHeight = frame.width / view.aspectRatio
        frame.origin.y += frame.height - newHeight
        frame.size.height = newHeight
        panel.setFrame(frame, display: true)

        applyConfiguration(fps: panel.isVisible ? Self.activeFPS : Self.hiddenFPS)
    }

    /// Re-targets the scroll event at the matching spot in the source window and posts it
    /// straight to the source app, so neither focus nor the cursor moves.
    private func forwardScroll(_ event: NSEvent, at point: CGPoint) {
        guard CGPreflightPostEventAccess() else {
            if !askedForEventAccess {
                askedForEventAccess = true
                CGRequestPostEventAccess()
            }
            return
        }
        guard let scroll = event.cgEvent?.copy(), let setWindowLocation = Self.setWindowLocation else { return }

        let local = windowLocal(point)
        scroll.location = CGPoint(x: sourceBounds.minX + local.x, y: sourceBounds.minY + local.y)
        // Vertical only: a sideways swipe means back/forward in browsers.
        scroll.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 0)
        scroll.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: 0)
        scroll.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: 0)
        // Events posted straight to a process skip the window server's routing, so AppKit
        // drops them unless they carry the target window (field 51) and the window-relative
        // location that the window server would normally fill in.
        scroll.setIntegerValueField(Self.windowNumberField, value: Int64(windowID))
        setWindowLocation(scroll, local)
        scroll.postToPid(pid)
    }

    /// Re-targets a click/drag at the matching spot in the source window, posted straight to
    /// the source app like the scroll events, so the app underneath keeps focus.
    private func forwardMouse(_ event: NSEvent, at point: CGPoint) {
        guard CGPreflightPostEventAccess() else {
            if !askedForEventAccess {
                askedForEventAccess = true
                CGRequestPostEventAccess()
            }
            return
        }
        guard let mouse = event.cgEvent?.copy(), let setWindowLocation = Self.setWindowLocation else { return }

        let isButtonDown = event.type == .leftMouseDown || event.type == .rightMouseDown
        // On a press, use the window's current frame: the cached one can lag behind a move.
        if isButtonDown, let live = WindowCatalog.info(for: windowID)?.bounds { sourceBounds = live }
        let local = windowLocal(point)
        let global = CGPoint(x: sourceBounds.minX + local.x, y: sourceBounds.minY + local.y)

        func prepare(_ e: CGEvent) {
            e.location = global
            e.setIntegerValueField(Self.windowNumberField, value: Int64(windowID))
            setWindowLocation(e, local)
        }

        // Apps (web views especially) need a hover before they accept a click.
        if isButtonDown,
           let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: global, mouseButton: .left) {
            prepare(move)
            move.postToPid(pid)
        }
        prepare(mouse)
        mouse.postToPid(pid)
    }

    /// Maps a point normalized to the captured frame (top-left origin) to window-relative points.
    /// ScreenCaptureKit scales the window into the frame and may leave empty space around it,
    /// so the frame's own content rect and scale are used rather than the window's bounds.
    private func windowLocal(_ point: CGPoint) -> CGPoint {
        guard let g = frameGeometry, g.contentScale > 0 else {
            return CGPoint(x: point.x * sourceBounds.width, y: point.y * sourceBounds.height)
        }
        let x = (point.x * g.surfaceSize.width - g.contentRect.minX) / g.contentScale
        let y = (point.y * g.surfaceSize.height - g.contentRect.minY) / g.contentScale
        return CGPoint(x: x, y: y)
    }

    private static let windowNumberField = CGEventField(rawValue: 51)!

    /// Private CoreGraphics API (re-exported from SkyLight); takes a top-left-origin point
    /// relative to the window frame.
    private static let setWindowLocation: (@convention(c) (CGEvent, CGPoint) -> Void)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else {
            NSLog("MacoPiP: CGEventSetWindowLocation unavailable; scroll forwarding disabled")
            return nil
        }
        return unsafeBitCast(symbol, to: (@convention(c) (CGEvent, CGPoint) -> Void).self)
    }()

    private func applyConfiguration(fps: Int) {
        stream?.updateConfiguration(makeConfiguration(fps: fps)) { error in
            if let error { NSLog("MacoPiP: updateConfiguration failed: \(error.localizedDescription)") }
        }
    }

    private func makeConfiguration(fps: Int) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        var width = sourceSize.width * scale
        var height = sourceSize.height * scale
        let maxSide: CGFloat = 3072
        let shrink = min(1, maxSide / max(width, height, 1))
        width *= shrink
        height *= shrink

        config.width = max(2, Int(width.rounded()))
        config.height = max(2, Int(height.rounded()))
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 5
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.capturesAudio = false
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.ignoreShadowsSingleWindow = true
        return config
    }

    private func saveFrame() {
        Settings.lastFrame = panel.frame
    }

    private static func aspect(of size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 16.0 / 10.0 }
        return size.width / size.height
    }

    private static func initialFrame(aspect: CGFloat, stackIndex: Int) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var width = min(max(Settings.lastFrame?.width ?? 480, 180), visible.width * 0.8)
        if width / aspect > visible.height * 0.8 { width = visible.height * 0.8 * aspect }
        let height = width / aspect

        // Reuse the last position (anchored at its top edge) for the first pin.
        if stackIndex == 0, let last = Settings.lastFrame {
            let frame = NSRect(x: last.minX, y: last.maxY - height, width: width, height: height)
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(frame) }) { return frame }
        }

        let margin: CGFloat = 24
        let offset = CGFloat(stackIndex) * 30
        return NSRect(x: visible.maxX - width - margin - offset,
                      y: visible.minY + margin + offset,
                      width: width, height: height)
    }
}

/// Content placement within a captured frame, all in frame points (top-left origin).
struct FrameGeometry {
    let surfaceSize: CGSize
    let contentRect: CGRect
    let contentScale: CGFloat

    init?(info: [SCStreamFrameInfo: Any], surface: IOSurfaceRef) {
        guard let rectDict = info[.contentRect],
              let rect = CGRect(dictionaryRepresentation: rectDict as! CFDictionary),
              let scale = info[.contentScale] as? CGFloat,
              let factor = info[.scaleFactor] as? CGFloat, factor > 0
        else { return nil }
        surfaceSize = CGSize(width: CGFloat(IOSurfaceGetWidth(surface)) / factor,
                             height: CGFloat(IOSurfaceGetHeight(surface)) / factor)
        contentRect = rect
        contentScale = scale
    }
}

/// Receives frames on the capture queue and hands complete ones to the main thread.
private final class FrameOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((IOSurfaceRef, FrameGeometry?) -> Void)?
    var onStop: (() -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else { return }

        let geometry = attachments.first.flatMap { FrameGeometry(info: $0, surface: surface) }
        DispatchQueue.main.async { [weak self] in self?.onFrame?(surface, geometry) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("MacoPiP: stream stopped: \(error.localizedDescription)")
        DispatchQueue.main.async { [weak self] in self?.onStop?() }
    }
}

enum Settings {
    static var opacity: CGFloat {
        get {
            let value = UserDefaults.standard.double(forKey: "opacity")
            return value == 0 ? 1 : CGFloat(value)
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: "opacity") }
    }

    static var lastFrame: NSRect? {
        get { UserDefaults.standard.string(forKey: "lastFrame").map(NSRectFromString) }
        set { UserDefaults.standard.set(newValue.map(NSStringFromRect), forKey: "lastFrame") }
    }
}
