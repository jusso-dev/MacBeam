import SwiftUI
import UIKit

/// Command bridge from SwiftUI toolbar controls into the underlying `RemoteCanvasView`.
@MainActor
final class RemoteCanvasController {
    weak var canvasView: RemoteCanvasView?

    func fitToScreen() {
        canvasView?.resetZoomToFit()
    }

    func toggleActualSize() {
        canvasView?.toggleActualSizeZoom()
    }

    func locatePointer() {
        canvasView?.locatePointer()
    }

    func setKeyboardVisible(_ visible: Bool) {
        if visible {
            canvasView?.becomeFirstResponder()
        } else {
            canvasView?.resignFirstResponder()
        }
    }
}

struct RemoteDisplayView: UIViewRepresentable {
    let client: RFBClient
    let inputMode: PointerInputMode
    let isScrollMode: Bool
    let pointerSize: PointerSize
    let controller: RemoteCanvasController
    let activeModifiers: Set<UInt32>
    let bottomAccessoryInset: CGFloat
    let onConsumeStickyModifiers: () -> Void
    let onSoftwareKeyboardChanged: (Bool, CGFloat) -> Void

    func makeUIView(context: Context) -> RemoteCanvasView {
        let view = RemoteCanvasView()
        view.client = client
        view.inputMode = inputMode
        view.isScrollMode = isScrollMode
        view.pointerSize = pointerSize
        view.bottomAccessoryInset = bottomAccessoryInset
        view.activeModifiersProvider = { activeModifiers }
        view.onConsumeStickyModifiers = onConsumeStickyModifiers
        view.onSoftwareKeyboardChanged = onSoftwareKeyboardChanged
        controller.canvasView = view
        return view
    }

    func updateUIView(_ uiView: RemoteCanvasView, context: Context) {
        uiView.client = client
        uiView.inputMode = inputMode
        uiView.isScrollMode = isScrollMode
        uiView.pointerSize = pointerSize
        uiView.bottomAccessoryInset = bottomAccessoryInset
        uiView.activeModifiersProvider = { activeModifiers }
        uiView.onConsumeStickyModifiers = onConsumeStickyModifiers
        uiView.onSoftwareKeyboardChanged = onSoftwareKeyboardChanged
        controller.canvasView = uiView

        if let image = client.currentImage {
            uiView.updateFramebuffer(image: image, generation: client.frameGeneration)
        }
        uiView.updateRemoteCursor(
            cursor: client.remoteCursor,
            hasServerUpdate: client.hasServerCursorUpdate,
            generation: client.cursorGeneration
        )
    }
}

/// High-performance native UIKit canvas for rendering VNC framebuffers and handling
/// touch, virtual trackpad, iPadOS hardware mouse/trackpad (hover, primary drag,
/// secondary right-click, scroll), and hardware/software keyboard input.
final class RemoteCanvasView: UIView, UIKeyInput, UIGestureRecognizerDelegate {
    weak var client: RFBClient?
    var inputMode: PointerInputMode = .trackpad {
        didSet { updateCursorLayers() }
    }
    var pointerSize: PointerSize = .large {
        didSet {
            if oldValue != pointerSize { updateCursorLayers() }
        }
    }
    /// When enabled, a one-finger drag scrolls the remote Mac (both axes, with momentum)
    /// and a two-finger drag pans the zoomed viewport. Designed for small iPhone screens.
    var isScrollMode = false {
        didSet {
            guard oldValue != isScrollMode else { return }
            longPressRecognizer?.isEnabled = !isScrollMode
            stopScrollMomentum()
        }
    }
    var bottomAccessoryInset: CGFloat = 0 {
        didSet {
            if abs(oldValue - bottomAccessoryInset) > 0.5 {
                layoutScreenLayer()
            }
        }
    }
    var activeModifiersProvider: (() -> Set<UInt32>)?
    var onConsumeStickyModifiers: (() -> Void)?
    var onSoftwareKeyboardChanged: ((Bool, CGFloat) -> Void)?

    private let screenLayer = CALayer()
    private let fallbackArrowLayer = CAShapeLayer()
    private let serverCursorLayer = CALayer()
    private let locatorRingLayer = CAShapeLayer()

    private var remoteSize: CGSize = CGSize(width: 1280, height: 800)
    private var lastFrameGeneration: UInt64 = 0
    private var lastCursorGeneration: UInt64 = 0
    private var hasServerCursor = false
    private var currentServerCursor: RFBCursor?

    // Viewport transform (scale relative to fit-to-screen, plus pan offset in view points)
    private var userZoomScale: CGFloat = 1.0
    private var panOffset: CGPoint = .zero
    private var pinchStartScale: CGFloat = 1.0
    private var isPinching = false

    // Virtual cursor position in remote framebuffer coordinates
    private var cursorPoint: CGPoint = CGPoint(x: 640, y: 400)
    private var isDraggingLeftButton = false
    private var lastPanLocation: CGPoint = .zero
    private var scrollAccumulatorY: CGFloat = 0
    private var scrollAccumulatorX: CGFloat = 0
    private weak var longPressRecognizer: UILongPressGestureRecognizer?

    // Scroll momentum (keeps flick-scrolling natural on iPhone)
    private var momentumLink: CADisplayLink?
    private var momentumVelocity: CGPoint = .zero
    private var momentumLastTimestamp: CFTimeInterval = 0
    private let scrollStepThreshold: CGFloat = 12
    private var isTwoFingerViewportPan = false
    private var scrollGestureUsesTouches = false
    private enum ScrollAxisLock { case vertical, horizontal, free }
    private var scrollAxisLock: ScrollAxisLock?

    // Keyboard avoidance & hardware key tracking (prevents stuck keys on modifier release)
    private var keyboardOverlapHeight: CGFloat = 0
    private var activeHardwareKeySyms: [UIKeyboardHIDUsage: UInt32] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func commonInit() {
        backgroundColor = .black
        isMultipleTouchEnabled = true
        clipsToBounds = true
        accessibilityLabel = "Remote Mac Display"
        accessibilityHint = "Use touch, virtual trackpad, or an attached keyboard and mouse to control your Mac."

        screenLayer.contentsGravity = .resize
        screenLayer.magnificationFilter = .linear
        screenLayer.minificationFilter = .trilinear
        layer.addSublayer(screenLayer)

        setupCursorLayers()
        setupGestures()
        observeKeyboardNotifications()
    }

    private func setupCursorLayers() {
        let arrow = UIBezierPath()
        arrow.move(to: .zero)
        arrow.addLine(to: CGPoint(x: 0, y: 18))
        arrow.addLine(to: CGPoint(x: 4.5, y: 13.5))
        arrow.addLine(to: CGPoint(x: 9, y: 21))
        arrow.addLine(to: CGPoint(x: 11.5, y: 19.5))
        arrow.addLine(to: CGPoint(x: 7, y: 12))
        arrow.addLine(to: CGPoint(x: 13.5, y: 12))
        arrow.close()

        fallbackArrowLayer.path = arrow.cgPath
        fallbackArrowLayer.fillColor = UIColor.black.cgColor
        fallbackArrowLayer.strokeColor = UIColor.white.cgColor
        fallbackArrowLayer.lineWidth = 1.6
        fallbackArrowLayer.shadowColor = UIColor.black.cgColor
        fallbackArrowLayer.shadowOpacity = 0.55
        fallbackArrowLayer.shadowRadius = 2.5
        fallbackArrowLayer.shadowOffset = CGSize(width: 0, height: 1)
        screenLayer.addSublayer(fallbackArrowLayer)

        serverCursorLayer.contentsGravity = .resize
        serverCursorLayer.magnificationFilter = .linear
        serverCursorLayer.isHidden = true
        // Soft outline so the pointer stays visible on any background.
        serverCursorLayer.shadowColor = UIColor.white.cgColor
        serverCursorLayer.shadowOpacity = 0.9
        serverCursorLayer.shadowRadius = 1.5
        serverCursorLayer.shadowOffset = .zero
        screenLayer.addSublayer(serverCursorLayer)

        locatorRingLayer.fillColor = UIColor.clear.cgColor
        locatorRingLayer.strokeColor = UIColor.systemYellow.cgColor
        locatorRingLayer.lineWidth = 3
        locatorRingLayer.opacity = 0
        screenLayer.addSublayer(locatorRingLayer)

        updateCursorLayers()
    }

    private func updateCursorLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if hasServerCursor {
            fallbackArrowLayer.isHidden = true
            serverCursorLayer.isHidden = (currentServerCursor == nil)
        } else {
            serverCursorLayer.isHidden = true
            fallbackArrowLayer.isHidden = (inputMode != .trackpad)
        }
        updateCursorLayerPosition()
        CATransaction.commit()
    }

    func updateRemoteCursor(cursor: RFBCursor?, hasServerUpdate: Bool, generation: UInt64) {
        guard generation != lastCursorGeneration else { return }
        lastCursorGeneration = generation
        hasServerCursor = hasServerUpdate
        currentServerCursor = cursor

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let cursor, let cgImage = RFBFramebuffer.makeCursorCGImage(from: cursor) {
            serverCursorLayer.contents = cgImage
        } else {
            serverCursorLayer.contents = nil
        }
        CATransaction.commit()
        updateCursorLayers()
    }

    private func setupGestures() {
        let directTouchType = NSNumber(value: UITouch.TouchType.direct.rawValue)
        let indirectPointerType = NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)

        // 1. Double-tap -> Double left-click
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.numberOfTouchesRequired = 1
        doubleTap.buttonMaskRequired = .primary
        addGestureRecognizer(doubleTap)

        // 2. Two-finger tap -> Right click
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTapsRequired = 1
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.allowedTouchTypes = [directTouchType]
        addGestureRecognizer(twoFingerTap)

        // 3. Hardware mouse / trackpad secondary right-click
        let secondaryClick = UITapGestureRecognizer(target: self, action: #selector(handleSecondaryClick(_:)))
        secondaryClick.numberOfTapsRequired = 1
        secondaryClick.buttonMaskRequired = .secondary
        secondaryClick.allowedTouchTypes = [indirectPointerType]
        addGestureRecognizer(secondaryClick)

        // 4. Single-finger tap -> Left click (waits for double-tap & two-finger tap to fail so taps never duplicate)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.numberOfTouchesRequired = 1
        singleTap.buttonMaskRequired = .primary
        singleTap.require(toFail: doubleTap)
        singleTap.require(toFail: twoFingerTap)
        addGestureRecognizer(singleTap)

        // 5. Long-press -> Right click (Direct Touch) or Drag & Drop (Trackpad)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.35
        longPress.allowedTouchTypes = [directTouchType]
        singleTap.require(toFail: longPress)
        addGestureRecognizer(longPress)
        longPressRecognizer = longPress

        // 6. Hardware mouse/trackpad click-and-drag (preserves primary/secondary button mask throughout drag)
        let pointerDrag = UIPanGestureRecognizer(target: self, action: #selector(handleIndirectPointerDrag(_:)))
        pointerDrag.allowedTouchTypes = [indirectPointerType]
        pointerDrag.maximumNumberOfTouches = 1
        pointerDrag.delegate = self
        addGestureRecognizer(pointerDrag)

        // 7. Direct touch one-finger pan -> Relative trackpad movement or viewport pan
        let oneFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleOneFingerPan(_:)))
        oneFingerPan.minimumNumberOfTouches = 1
        oneFingerPan.maximumNumberOfTouches = 1
        oneFingerPan.allowedTouchTypes = [directTouchType]
        oneFingerPan.delegate = self
        addGestureRecognizer(oneFingerPan)

        // 8. Two-finger pan & iPadOS indirect scroll wheel -> Remote macOS scrolling
        let twoFingerScroll = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
        twoFingerScroll.minimumNumberOfTouches = 2
        twoFingerScroll.maximumNumberOfTouches = 2
        twoFingerScroll.allowedScrollTypesMask = .all
        twoFingerScroll.delegate = self
        twoFingerTap.require(toFail: twoFingerScroll)
        addGestureRecognizer(twoFingerScroll)

        // 9. Pinch -> Smooth viewport zoom (arbitrated cleanly against remote scrolling)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        // 10. iPadOS hardware trackpad/mouse hover -> exact cursor tracking
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Never allow pinch and two-finger scroll to fire simultaneously so zooming never scrolls the Mac.
        return false
    }

    // MARK: - Keyboard Overlap Tracking

    private func observeKeyboardNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardFrameChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    @objc private func handleKeyboardFrameChange(_ notification: Notification) {
        guard let endFrameValue = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else {
            return
        }
        let endFrameInWindow = endFrameValue.cgRectValue
        let endFrameInView = convert(endFrameInWindow, from: nil)
        let intersection = bounds.intersection(endFrameInView)
        let overlap = intersection.isNull ? 0 : max(0, bounds.maxY - intersection.minY)
        updateKeyboardOverlap(overlap)
    }

    @objc private func handleKeyboardWillHide(_ notification: Notification) {
        updateKeyboardOverlap(0)
    }

    private func updateKeyboardOverlap(_ overlap: CGFloat) {
        let clamped = max(0, overlap)
        guard abs(clamped - keyboardOverlapHeight) > 0.5 else { return }
        keyboardOverlapHeight = clamped
        let isSoftwareKeyboardVisible = clamped > 60
        onSoftwareKeyboardChanged?(isSoftwareKeyboardVisible, clamped)
        layoutScreenLayer()
    }

    // MARK: - Framebuffer & Layout

    func updateFramebuffer(image: CGImage, generation: UInt64) {
        guard generation != lastFrameGeneration else { return }
        lastFrameGeneration = generation

        let newSize = CGSize(width: image.width, height: image.height)
        let sizeChanged = newSize != remoteSize
        if sizeChanged {
            remoteSize = newSize
            cursorPoint = CGPoint(x: newSize.width / 2, y: newSize.height / 2)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        screenLayer.contents = image
        if sizeChanged {
            layoutScreenLayer()
        }
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutScreenLayer()
        CATransaction.commit()
    }

    private var usableBounds: CGRect {
        let bottomInset = keyboardOverlapHeight + bottomAccessoryInset
        let usableHeight = max(120, bounds.height - bottomInset)
        return CGRect(x: 0, y: 0, width: bounds.width, height: usableHeight)
    }

    private func fitFrame() -> CGRect {
        let area = usableBounds
        guard area.width > 0, area.height > 0, remoteSize.width > 0, remoteSize.height > 0 else {
            return area
        }
        let scale = min(area.width / remoteSize.width, area.height / remoteSize.height)
        let w = remoteSize.width * scale
        let h = remoteSize.height * scale
        return CGRect(
            x: area.minX + (area.width - w) / 2,
            y: area.minY + (area.height - h) / 2,
            width: w,
            height: h
        )
    }

    private func layoutScreenLayer() {
        let area = usableBounds
        let base = fitFrame()
        let scaledW = base.width * userZoomScale
        let scaledH = base.height * userZoomScale

        let maxPanX = max(0, (scaledW - area.width) / 2)
        let maxPanY = max(0, (scaledH - area.height) / 2)
        panOffset.x = min(maxPanX, max(-maxPanX, panOffset.x))
        panOffset.y = min(maxPanY, max(-maxPanY, panOffset.y))

        let originX = area.minX + (area.width - scaledW) / 2 + panOffset.x
        let originY = area.minY + (area.height - scaledH) / 2 + panOffset.y
        screenLayer.frame = CGRect(x: originX, y: originY, width: scaledW, height: scaledH)
        updateCursorLayerPosition()
    }

    private func updateCursorLayerPosition() {
        guard remoteSize.width > 0, remoteSize.height > 0, screenLayer.bounds.width > 0 else { return }
        let scaleX = screenLayer.bounds.width / remoteSize.width
        let scaleY = screenLayer.bounds.height / remoteSize.height
        let lx = cursorPoint.x * scaleX
        let ly = cursorPoint.y * scaleY

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fallbackArrowLayer.position = CGPoint(x: lx, y: ly)
        fallbackArrowLayer.setAffineTransform(CGAffineTransform(scaleX: pointerSize.multiplier, y: pointerSize.multiplier))
        if let cursor = currentServerCursor {
            // Size the pointer on *screen*, not by framebuffer scale. A Mac framebuffer shrunk to fit
            // an iPhone would otherwise turn the cursor into a few points and make it impossible to find.
            let cursorScale = serverCursorDisplayScale(cursor: cursor, framebufferScale: scaleX)
            let cw = CGFloat(cursor.width) * cursorScale
            let ch = CGFloat(cursor.height) * cursorScale
            let hx = CGFloat(cursor.hotspotX) * cursorScale
            let hy = CGFloat(cursor.hotspotY) * cursorScale
            serverCursorLayer.frame = CGRect(x: lx - hx, y: ly - hy, width: cw, height: ch)
        }
        locatorRingLayer.position = CGPoint(x: lx, y: ly)
        CATransaction.commit()
    }

    /// Keeps the cursor between a readable minimum and a sensible maximum on screen, whatever the zoom.
    private func serverCursorDisplayScale(cursor: RFBCursor, framebufferScale: CGFloat) -> CGFloat {
        let largestSide = CGFloat(max(cursor.width, cursor.height, 1))
        let minScale = (28 * pointerSize.multiplier) / largestSide
        let maxScale = (48 * pointerSize.multiplier) / largestSide
        return min(maxScale, max(minScale, framebufferScale))
    }

    /// Brings the pointer into view (when zoomed) and pulses a ring around it.
    func locatePointer() {
        guard remoteSize.width > 0, remoteSize.height > 0 else { return }
        if userZoomScale > 1.02 {
            // Centre the viewport on the cursor.
            let area = usableBounds
            let f = screenLayer.frame
            let cursorInView = CGPoint(
                x: f.minX + (cursorPoint.x / remoteSize.width) * f.width,
                y: f.minY + (cursorPoint.y / remoteSize.height) * f.height
            )
            panOffset.x += area.midX - cursorInView.x
            panOffset.y += area.midY - cursorInView.y
            if UIAccessibility.isReduceMotionEnabled {
                layoutScreenLayer()
            } else {
                UIView.animate(withDuration: 0.25) { self.layoutScreenLayer() }
            }
        }
        updateCursorLayers()

        let radius: CGFloat = 30
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        locatorRingLayer.path = UIBezierPath(
            ovalIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)
        ).cgPath
        CATransaction.commit()

        locatorRingLayer.removeAllAnimations()
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 2.4
        scale.toValue = 0.6
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.15, 0.75, 1]
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.7
        group.repeatCount = UIAccessibility.isReduceMotionEnabled ? 1 : 2
        locatorRingLayer.add(group, forKey: "locate")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func resetZoomToFit() {
        userZoomScale = 1.0
        panOffset = .zero
        if UIAccessibility.isReduceMotionEnabled {
            layoutScreenLayer()
        } else {
            UIView.animate(withDuration: 0.2) {
                self.layoutScreenLayer()
            }
        }
    }

    func toggleActualSizeZoom() {
        let base = fitFrame()
        guard base.width > 0 else { return }
        if userZoomScale > 1.05 {
            resetZoomToFit()
        } else {
            let displayScale = window?.screen.scale ?? max(1.0, traitCollection.displayScale)
            let nativeScale = (remoteSize.width / displayScale) / base.width
            // If native 1:1 is barely larger than fit, provide a useful 2× inspection zoom.
            userZoomScale = min(5.0, max(nativeScale > 1.15 ? nativeScale : 2.0, 1.25))
            layoutScreenLayer()
        }
    }

    private func viewPointToRemotePoint(_ pt: CGPoint) -> CGPoint {
        let f = screenLayer.frame
        guard f.width > 0, f.height > 0 else { return cursorPoint }
        let nx = max(0, min(1, (pt.x - f.minX) / f.width))
        let ny = max(0, min(1, (pt.y - f.minY) / f.height))
        return CGPoint(x: nx * remoteSize.width, y: ny * remoteSize.height)
    }

    private func clampCursor() {
        cursorPoint.x = max(0, min(remoteSize.width - 1, cursorPoint.x))
        cursorPoint.y = max(0, min(remoteSize.height - 1, cursorPoint.y))
    }

    // MARK: - Gesture Handlers

    @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        if inputMode == .directTouch || gesture.location(in: self) != .zero && hasIndirectPointerTouch(gesture) {
            if inputMode == .directTouch {
                cursorPoint = viewPointToRemotePoint(gesture.location(in: self))
                clampCursor()
                updateCursorLayerPosition()
            }
        }
        sendClick(button: .left)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if inputMode == .directTouch {
            cursorPoint = viewPointToRemotePoint(gesture.location(in: self))
            clampCursor()
            updateCursorLayerPosition()
        }
        sendClick(button: .left)
        sendClick(button: .left)
    }

    @objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
        if inputMode == .directTouch {
            cursorPoint = viewPointToRemotePoint(gesture.location(in: self))
            clampCursor()
            updateCursorLayerPosition()
        }
        sendClick(button: .right)
    }

    @objc private func handleSecondaryClick(_ gesture: UITapGestureRecognizer) {
        cursorPoint = viewPointToRemotePoint(gesture.location(in: self))
        clampCursor()
        updateCursorLayerPosition()
        sendClick(button: .right)
    }

    @objc private func handleIndirectPointerDrag(_ gesture: UIPanGestureRecognizer) {
        cursorPoint = viewPointToRemotePoint(gesture.location(in: self))
        clampCursor()
        updateCursorLayerPosition()

        switch gesture.state {
        case .began, .changed:
            let dragButton: RFBPointerButton = gesture.buttonMask.contains(.secondary) ? .right : .left
            isDraggingLeftButton = (dragButton == .left)
            client?.sendPointerEvent(x: Int(cursorPoint.x), y: Int(cursorPoint.y), buttons: dragButton)
        case .ended, .cancelled, .failed:
            isDraggingLeftButton = false
            client?.sendPointerEvent(x: Int(cursorPoint.x), y: Int(cursorPoint.y), buttons: [])
        default:
            break
        }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch inputMode {
        case .directTouch:
            if gesture.state == .began {
                cursorPoint = viewPointToRemotePoint(gesture.location(in: self))
                clampCursor()
                updateCursorLayerPosition()
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                sendClick(button: .right)
            }
        case .trackpad:
            switch gesture.state {
            case .began:
                isDraggingLeftButton = true
                lastPanLocation = gesture.location(in: self)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                client?.sendPointerEvent(x: Int(cursorPoint.x), y: Int(cursorPoint.y), buttons: .left)
            case .changed:
                let loc = gesture.location(in: self)
                let scaleFactor = (remoteSize.width / max(1, screenLayer.frame.width)) * 1.35
                cursorPoint.x += (loc.x - lastPanLocation.x) * scaleFactor
                cursorPoint.y += (loc.y - lastPanLocation.y) * scaleFactor
                lastPanLocation = loc
                clampCursor()
                updateCursorLayerPosition()
                client?.sendPointerEvent(x: Int(cursorPoint.x), y: Int(cursorPoint.y), buttons: .left)
            case .ended, .cancelled, .failed:
                isDraggingLeftButton = false
                client?.sendPointerEvent(x: Int(cursorPoint.x), y: Int(cursorPoint.y), buttons: [])
            default:
                break
            }
        }
    }

    @objc private func handleOneFingerPan(_ gesture: UIPanGestureRecognizer) {
        if isScrollMode {
            handleOneFingerScroll(gesture)
            return
        }

        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)

        switch inputMode {
        case .trackpad:
            let speed = hypot(translation.x, translation.y)
            let accel: CGFloat = speed > 14 ? 1.85 : (speed > 6 ? 1.45 : 1.15)
            let scaleFactor = (remoteSize.width / max(1, screenLayer.frame.width)) * accel
            cursorPoint.x += translation.x * scaleFactor
            cursorPoint.y += translation.y * scaleFactor
            clampCursor()
            updateCursorLayerPosition()

            let buttons: RFBPointerButton = isDraggingLeftButton ? .left : []
            client?.sendPointerEvent(x: Int(cursorPoint.x), y: Int(cursorPoint.y), buttons: buttons)

            if userZoomScale > 1.05 {
                let area = usableBounds
                let cursorInView = CGPoint(
                    x: screenLayer.frame.minX + (cursorPoint.x / remoteSize.width) * screenLayer.frame.width,
                    y: screenLayer.frame.minY + (cursorPoint.y / remoteSize.height) * screenLayer.frame.height
                )
                let margin: CGFloat = 44
                if cursorInView.x < margin { panOffset.x += (margin - cursorInView.x) }
                if cursorInView.x > area.width - margin { panOffset.x -= (cursorInView.x - (area.width - margin)) }
                if cursorInView.y < margin { panOffset.y += (margin - cursorInView.y) }
                if cursorInView.y > area.maxY - margin { panOffset.y -= (cursorInView.y - (area.maxY - margin)) }
                layoutScreenLayer()
            }

        case .directTouch:
            if userZoomScale > 1.02 {
                panOffset.x += translation.x
                panOffset.y += translation.y
                layoutScreenLayer()
            } else {
                cursorPoint = viewPointToRemotePoint(gesture.location(in: self))
                clampCursor()
                updateCursorLayerPosition()
                let isActive = gesture.state == .began || gesture.state == .changed
                client?.sendPointerEvent(
                    x: Int(cursorPoint.x),
                    y: Int(cursorPoint.y),
                    buttons: isActive ? .left : []
                )
            }
        }
    }

    @objc private func handleScrollPan(_ gesture: UIPanGestureRecognizer) {
        guard !isPinching else {
            resetScrollAccumulators()
            gesture.setTranslation(.zero, in: self)
            return
        }

        // Scroll Mode: two fingers move the zoomed viewport (one finger already scrolls the Mac).
        // Indirect scroll-wheel input reports zero touches and always scrolls the Mac.
        if gesture.state == .began {
            isTwoFingerViewportPan = isScrollMode && userZoomScale > 1.02 && gesture.numberOfTouches >= 2
        }
        if isTwoFingerViewportPan {
            let translation = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            panOffset.x += translation.x
            panOffset.y += translation.y
            layoutScreenLayer()
            if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                isTwoFingerViewportPan = false
            }
            return
        }

        switch gesture.state {
        case .began:
            stopScrollMomentum()
            resetScrollAccumulators()
            // Mouse wheels / trackpads report zero touches; only finger flicks get momentum.
            scrollGestureUsesTouches = gesture.numberOfTouches >= 2
        case .changed:
            let delta = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            emitScrollSteps(dx: delta.x, dy: delta.y)
        case .ended:
            if scrollGestureUsesTouches {
                startScrollMomentum(velocity: gesture.velocity(in: self))
            } else {
                resetScrollAccumulators()
            }
        default:
            resetScrollAccumulators()
        }
    }

    /// Scroll Mode one-finger drag: natural-direction scrolling of the remote Mac in both axes.
    /// Mostly-straight drags lock to one axis so vertical scrolls don't drift sideways.
    private func handleOneFingerScroll(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            stopScrollMomentum()
            resetScrollAccumulators()
            scrollAxisLock = nil
            if inputMode == .directTouch {
                // Scroll whatever is under the finger, like a native iOS scroll view.
                cursorPoint = viewPointToRemotePoint(gesture.location(in: self))
                clampCursor()
                updateCursorLayerPosition()
                client?.sendPointerEvent(x: Int(cursorPoint.x), y: Int(cursorPoint.y), buttons: [])
            }
            fallthrough
        case .changed:
            let delta = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            if scrollAxisLock == nil {
                let total = CGPoint(x: abs(scrollAccumulatorX + delta.x), y: abs(scrollAccumulatorY + delta.y))
                if max(total.x, total.y) >= 6 {
                    if total.y > total.x * 2 {
                        scrollAxisLock = .vertical
                    } else if total.x > total.y * 2 {
                        scrollAxisLock = .horizontal
                    } else {
                        scrollAxisLock = .free
                    }
                }
            }
            emitScrollSteps(dx: lockedDelta(delta).x, dy: lockedDelta(delta).y)
        case .ended:
            startScrollMomentum(velocity: lockedDelta(gesture.velocity(in: self)))
        default:
            resetScrollAccumulators()
        }
    }

    private func lockedDelta(_ delta: CGPoint) -> CGPoint {
        switch scrollAxisLock {
        case .vertical: return CGPoint(x: 0, y: delta.y)
        case .horizontal: return CGPoint(x: delta.x, y: 0)
        case .free, nil: return delta
        }
    }

    private func resetScrollAccumulators() {
        scrollAccumulatorX = 0
        scrollAccumulatorY = 0
    }

    /// Converts finger travel (view points) into discrete RFB wheel ticks.
    private func emitScrollSteps(dx: CGFloat, dy: CGFloat) {
        scrollAccumulatorY += dy
        scrollAccumulatorX += dx

        while abs(scrollAccumulatorY) >= scrollStepThreshold {
            let btn: RFBPointerButton = scrollAccumulatorY > 0 ? .scrollUp : .scrollDown
            client?.sendScroll(x: Int(cursorPoint.x), y: Int(cursorPoint.y), button: btn)
            scrollAccumulatorY += scrollAccumulatorY > 0 ? -scrollStepThreshold : scrollStepThreshold
        }
        while abs(scrollAccumulatorX) >= scrollStepThreshold {
            let btn: RFBPointerButton = scrollAccumulatorX > 0 ? .scrollLeft : .scrollRight
            client?.sendScroll(x: Int(cursorPoint.x), y: Int(cursorPoint.y), button: btn)
            scrollAccumulatorX += scrollAccumulatorX > 0 ? -scrollStepThreshold : scrollStepThreshold
        }
    }

    // MARK: - Scroll Momentum

    private func startScrollMomentum(velocity: CGPoint) {
        stopScrollMomentum()
        let maxSpeed: CGFloat = 2400
        let v = CGPoint(
            x: max(-maxSpeed, min(maxSpeed, velocity.x)),
            y: max(-maxSpeed, min(maxSpeed, velocity.y))
        )
        guard hypot(v.x, v.y) > 250, !UIAccessibility.isReduceMotionEnabled else {
            resetScrollAccumulators()
            return
        }
        momentumVelocity = v
        momentumLastTimestamp = 0
        let link = CADisplayLink(target: self, selector: #selector(stepScrollMomentum(_:)))
        link.add(to: .main, forMode: .common)
        momentumLink = link
    }

    @objc private func stepScrollMomentum(_ link: CADisplayLink) {
        guard momentumLastTimestamp > 0 else {
            momentumLastTimestamp = link.timestamp
            return
        }
        let dt = min(1.0 / 30.0, link.timestamp - momentumLastTimestamp)
        momentumLastTimestamp = link.timestamp

        emitScrollSteps(dx: momentumVelocity.x * dt, dy: momentumVelocity.y * dt)

        let decay = pow(0.94, dt * 60)
        momentumVelocity.x *= decay
        momentumVelocity.y *= decay
        if hypot(momentumVelocity.x, momentumVelocity.y) < 40 {
            stopScrollMomentum()
        }
    }

    private func stopScrollMomentum() {
        momentumLink?.invalidate()
        momentumLink = nil
        momentumVelocity = .zero
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Any new touch catches an in-flight momentum scroll, matching iOS behaviour.
        stopScrollMomentum()
        super.touchesBegan(touches, with: event)
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            stopScrollMomentum()
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            isPinching = true
            scrollAccumulatorX = 0
            scrollAccumulatorY = 0
            pinchStartScale = userZoomScale
        case .changed:
            let next = pinchStartScale * gesture.scale
            userZoomScale = max(1.0, min(5.0, next))
            layoutScreenLayer()
        case .ended, .cancelled, .failed:
            isPinching = false
            if userZoomScale < 1.05 {
                resetZoomToFit()
            }
        default:
            break
        }
    }

    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        guard gesture.state == .began || gesture.state == .changed else { return }
        cursorPoint = viewPointToRemotePoint(gesture.location(in: self))
        clampCursor()
        updateCursorLayerPosition()
        let buttons: RFBPointerButton = isDraggingLeftButton ? .left : []
        client?.sendPointerEvent(x: Int(cursorPoint.x), y: Int(cursorPoint.y), buttons: buttons)
    }

    private func hasIndirectPointerTouch(_ gesture: UIGestureRecognizer) -> Bool {
        gesture.allowedTouchTypes.contains(NSNumber(value: UITouch.TouchType.indirectPointer.rawValue))
    }

    private func sendClick(button: RFBPointerButton) {
        let x = Int(cursorPoint.x)
        let y = Int(cursorPoint.y)
        client?.sendPointerEvent(x: x, y: y, buttons: button)
        client?.sendPointerEvent(x: x, y: y, buttons: [])
    }

    // MARK: - Software Keyboard (`UIKeyInput`)

    override var canBecomeFirstResponder: Bool { true }

    var hasText: Bool { true }

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no

    func insertText(_ text: String) {
        let stickyMods = Array(activeModifiersProvider?() ?? [])
        for ch in text {
            if let sym = RFBKeySym.from(character: ch) {
                client?.sendKeyTap(keySym: sym, modifiers: stickyMods)
            }
        }
        if !stickyMods.isEmpty {
            onConsumeStickyModifiers?()
        }
    }

    func deleteBackward() {
        let stickyMods = Array(activeModifiersProvider?() ?? [])
        client?.sendKeyTap(keySym: RFBKeySym.backSpace, modifiers: stickyMods)
        if !stickyMods.isEmpty {
            onConsumeStickyModifiers?()
        }
    }

    // MARK: - Hardware Keyboard (`pressesBegan` / `pressesEnded`) for iPadOS

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key, let sym = RFBKeySym.from(key: key) else { continue }
            activeHardwareKeySyms[key.keyCode] = sym
            client?.sendKeyEvent(keySym: sym, down: true)
            handled = true
        }
        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            guard let sym = activeHardwareKeySyms.removeValue(forKey: key.keyCode) ?? RFBKeySym.from(key: key) else { continue }
            client?.sendKeyEvent(keySym: sym, down: false)
            handled = true
        }
        if !handled {
            super.pressesEnded(presses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            if let sym = activeHardwareKeySyms.removeValue(forKey: key.keyCode) ?? RFBKeySym.from(key: key) {
                client?.sendKeyEvent(keySym: sym, down: false)
            }
        }
        super.pressesCancelled(presses, with: event)
    }
}
