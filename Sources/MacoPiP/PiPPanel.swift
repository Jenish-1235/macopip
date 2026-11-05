import AppKit

/// Borderless floating panel that can sit over other apps' full-screen Spaces
/// without ever taking focus away from them.
final class PiPPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        acceptsMouseMovedEvents = true
        animationBehavior = .utilityWindow
    }

    // Never key: keystrokes always stay with the full-screen app underneath.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Shows the mirrored frames, plus hover controls. Clicks, drags and scrolls over the mirror
/// are forwarded to the real window. Drag the control bar (or hold ⌥ and drag anywhere) to move,
/// drag near an edge to resize (aspect ratio is kept).
final class PiPView: NSView {
    var aspectRatio: CGFloat = 16.0 / 10.0
    var onClose: (() -> Void)?
    var onJump: (() -> Void)?
    var onOpacityStep: ((CGFloat) -> Void)?
    var onFrameCommitted: (() -> Void)?
    /// Scroll over the mirror; the point is normalized to 0...1 from the top-left corner.
    var onScroll: ((NSEvent, CGPoint) -> Void)?
    /// Mouse button events over the mirror, same normalized point as `onScroll`.
    var onMouse: ((NSEvent, CGPoint) -> Void)?

    private let videoLayer = CALayer()
    private let controls = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let waitingLabel = NSTextField(labelWithString: "Waiting for window content…")
    /// Aspect ratio of the latest captured frame; the mirror is letterboxed to this.
    private var contentAspect: CGFloat?
    private var trackingArea: NSTrackingArea?

    private enum DragMode { case none, forward(right: Bool), resize(left: Bool, bottom: Bool, horizontal: Bool) }
    private var dragMode = DragMode.none
    private var startFrame = NSRect.zero
    private var startMouse = NSPoint.zero
    private let edgeGrab: CGFloat = 14
    private let minWidth: CGFloat = 180

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor

        videoLayer.contentsGravity = .resizeAspect
        videoLayer.minificationFilter = .trilinear
        videoLayer.magnificationFilter = .linear
        layer?.addSublayer(videoLayer)

        waitingLabel.textColor = .secondaryLabelColor
        waitingLabel.font = .systemFont(ofSize: 12)
        waitingLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(waitingLabel)
        NSLayoutConstraint.activate([
            waitingLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            waitingLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setupControls(title: title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupControls(title: String) {
        controls.material = .hudWindow
        controls.blendingMode = .withinWindow
        controls.state = .active
        controls.wantsLayer = true
        controls.layer?.cornerRadius = 8
        controls.alphaValue = 0
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)

        titleLabel.stringValue = title
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [
            makeButton("xmark", "Unpin", #selector(closeTapped)),
            titleLabel,
            makeButton("sun.min", "Less opaque", #selector(fadeTapped)),
            makeButton("sun.max", "More opaque", #selector(unfadeTapped)),
            makeButton("arrow.up.forward.app", "Go to app", #selector(jumpTapped)),
        ])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(stack)

        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            controls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            controls.heightAnchor.constraint(equalToConstant: 28),
            stack.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
        ])
    }

    private func makeButton(_ symbol: String, _ tooltip: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage()
        let button = FirstMouseButton(image: image, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .white
        button.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        button.toolTip = tooltip
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    @objc private func closeTapped() { onClose?() }
    @objc private func jumpTapped() { onJump?() }
    @objc private func fadeTapped() { onOpacityStep?(-0.15) }
    @objc private func unfadeTapped() { onOpacityStep?(0.15) }

    var title: String {
        get { titleLabel.stringValue }
        set { titleLabel.stringValue = newValue }
    }

    func display(_ surface: IOSurfaceRef) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.contents = surface
        let w = IOSurfaceGetWidth(surface), h = IOSurfaceGetHeight(surface)
        if w > 0, h > 0 { contentAspect = CGFloat(w) / CGFloat(h) }
        CATransaction.commit()
        if !waitingLabel.isHidden { waitingLabel.isHidden = true }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }

    // MARK: Hover controls

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { setControlsVisible(true) }
    override func mouseExited(with event: NSEvent) { setControlsVisible(false) }

    private func setControlsVisible(_ visible: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            controls.animator().alphaValue = visible ? 1 : 0
        }
    }

    // MARK: Scroll

    override func scrollWheel(with event: NSEvent) {
        guard let point = normalizedPoint(of: event) else { return }
        onScroll?(event, point)
    }

    /// Where the frame is actually drawn inside the view (it is aspect-fitted).
    private var contentRect: CGRect {
        guard let aspect = contentAspect, bounds.width > 0, bounds.height > 0 else { return bounds }
        if bounds.width / bounds.height > aspect {
            let w = bounds.height * aspect
            return CGRect(x: (bounds.width - w) / 2, y: 0, width: w, height: bounds.height)
        }
        let h = bounds.width / aspect
        return CGRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
    }

    private func normalizedPoint(of event: NSEvent) -> CGPoint? {
        let rect = contentRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let x = min(max((p.x - rect.minX) / rect.width, 0), 1)
        let y = min(max((p.y - rect.minY) / rect.height, 0), 1)
        return CGPoint(x: x, y: 1 - y)
    }

    private func forward(_ event: NSEvent) {
        guard let point = normalizedPoint(of: event) else { return }
        onMouse?(event, point)
    }

    // MARK: Move / resize

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let p = convert(event.locationInWindow, from: nil)
        let nearLeft = p.x < edgeGrab, nearRight = p.x > bounds.width - edgeGrab
        let nearBottom = p.y < edgeGrab, nearTop = p.y > bounds.height - edgeGrab

        if nearLeft || nearRight || nearBottom || nearTop {
            dragMode = .resize(left: nearLeft, bottom: nearBottom, horizontal: nearLeft || nearRight)
            startFrame = window.frame
            startMouse = NSEvent.mouseLocation
        } else if controls.frame.contains(p) || event.modifierFlags.contains(.option) {
            dragMode = .none
            window.performDrag(with: event)
            onFrameCommitted?()
        } else {
            dragMode = .forward(right: false)
            forward(event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        dragMode = .forward(right: true)
        forward(event)
    }

    override func mouseMoved(with event: NSEvent) {
        if !controls.frame.contains(convert(event.locationInWindow, from: nil)) { forward(event) }
    }

    override func rightMouseDragged(with event: NSEvent) { forward(event) }
    override func rightMouseUp(with event: NSEvent) {
        forward(event)
        dragMode = .none
    }

    override func mouseDragged(with event: NSEvent) {
        if case .forward = dragMode { forward(event); return }
        guard case let .resize(left, bottom, horizontal) = dragMode, let window else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - startMouse.x, dy = mouse.y - startMouse.y

        var width: CGFloat
        if horizontal {
            width = startFrame.width + (left ? -dx : dx)
        } else {
            width = (startFrame.height + (bottom ? -dy : dy)) * aspectRatio
        }
        let maxWidth = (window.screen ?? NSScreen.main)?.visibleFrame.width ?? 3000
        width = min(max(width, minWidth), maxWidth)
        let height = width / aspectRatio

        let x = left ? startFrame.maxX - width : startFrame.minX
        let y = bottom ? startFrame.maxY - height : startFrame.minY
        window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    override func mouseUp(with event: NSEvent) {
        if case .forward = dragMode { forward(event) }
        if case .resize = dragMode { onFrameCommitted?() }
        dragMode = .none
    }
}
