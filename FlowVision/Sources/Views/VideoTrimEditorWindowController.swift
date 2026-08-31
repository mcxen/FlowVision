//
//  VideoTrimEditorWindowController.swift
//  FlowVision
//

import AVFoundation
import Cocoa

struct VideoTrimSegment: Equatable {
    var start: Double
    var end: Double

    var duration: Double { end - start }
}

enum VideoTrimEditorMode {
    case trim
    case crop
}

private struct VideoTrimCropSelection: Equatable {
    /// Bottom-origin pixel coordinates in the decoded/displayed video frame.
    /// This is the single source of truth; window resizing only changes how it
    /// is projected onto the canvas.
    var pixelRect: CGRect

    static let empty = VideoTrimCropSelection(pixelRect: .zero)

    static func fullFrame(for size: NSSize) -> VideoTrimCropSelection {
        VideoTrimCropSelection(pixelRect: CGRect(origin: .zero, size: size))
    }
}

/// Shared geometry contract for the crop UI and FFmpeg export. It mirrors
/// IINA's model: keep the selection in source pixels, project it onto an
/// aspect-fitted video canvas, then flip Y exactly once at the FFmpeg boundary.
private struct VideoCropGeometry {
    let sourcePixelSize: NSSize
    let canvasBounds: NSRect

    var isValid: Bool {
        sourcePixelSize.width > 0 && sourcePixelSize.height > 0 &&
            canvasBounds.width > 0 && canvasBounds.height > 0
    }

    var fullPixelRect: NSRect {
        NSRect(origin: .zero, size: sourcePixelSize)
    }

    func canvasRect(for pixelRect: NSRect) -> NSRect {
        guard isValid else { return .zero }
        let xScale = canvasBounds.width / sourcePixelSize.width
        let yScale = canvasBounds.height / sourcePixelSize.height
        return NSRect(
            x: canvasBounds.minX + pixelRect.minX * xScale,
            y: canvasBounds.minY + pixelRect.minY * yScale,
            width: pixelRect.width * xScale,
            height: pixelRect.height * yScale
        )
    }

    func pixelRect(for canvasRect: NSRect) -> NSRect {
        guard isValid else { return .zero }
        let xScale = sourcePixelSize.width / canvasBounds.width
        let yScale = sourcePixelSize.height / canvasBounds.height
        let converted = NSRect(
            x: (canvasRect.minX - canvasBounds.minX) * xScale,
            y: (canvasRect.minY - canvasBounds.minY) * yScale,
            width: canvasRect.width * xScale,
            height: canvasRect.height * yScale
        )
        return converted.intersection(fullPixelRect)
    }

    func evenFFmpegRect(for pixelRect: NSRect) -> (x: Int, y: Int, width: Int, height: Int)? {
        guard isValid else { return nil }
        let bounded = pixelRect.intersection(fullPixelRect)
        guard bounded.width >= 2, bounded.height >= 2 else { return nil }

        var x = max(0, Int(bounded.minX.rounded(.down)))
        var y = max(0, Int((sourcePixelSize.height - bounded.maxY).rounded(.down)))
        var width = max(2, Int(bounded.width.rounded(.down)))
        var height = max(2, Int(bounded.height.rounded(.down)))
        x -= x % 2
        y -= y % 2
        width -= width % 2
        height -= height % 2
        width = min(width, max(2, Int(sourcePixelSize.width) - x))
        height = min(height, max(2, Int(sourcePixelSize.height) - y))
        width -= width % 2
        height -= height % 2
        guard width >= 2, height >= 2 else { return nil }
        return (x, y, width, height)
    }
}

private protocol VideoTrimTimelineViewDelegate: AnyObject {
    func timelineView(_ timeline: VideoTrimTimelineView, didSeekTo seconds: Double)
    func timelineView(_ timeline: VideoTrimTimelineView, didSelectSegment index: Int)
    func timelineView(_ timeline: VideoTrimTimelineView, didChangeSegment segment: VideoTrimSegment, at index: Int)
}

private final class VideoTrimTimelineView: NSView {
    weak var delegate: VideoTrimTimelineViewDelegate?
    var duration: Double = 1 { didSet { needsDisplay = true } }
    var segments: [VideoTrimSegment] = [] { didSet { needsDisplay = true } }
    var selectedSegmentIndex = 0 { didSet { needsDisplay = true } }
    var playhead: Double = 0 { didSet { needsDisplay = true } }
    var thumbnails: [NSImage?] = Array(repeating: nil, count: 12) {
        didSet {
            needsDisplay = true
            updateSkeletonAnimation()
        }
    }
    var isLoadingThumbnails = true {
        didSet {
            needsDisplay = true
            updateSkeletonAnimation()
        }
    }

    private enum DragMode { case none, start, end, seek }
    private enum HandleSide { case start, end }
    private var dragMode: DragMode = .none
    private var dragOriginX: CGFloat = 0
    private var dragInitialSegment: VideoTrimSegment?
    private let handleVisualWidth: CGFloat = 16
    private let handleHitWidth: CGFloat = 24
    private let selectionEdgeHeight: CGFloat = 4
    private let minimumSegmentDuration = 0.08
    private var skeletonTimer: Timer?
    private var skeletonPhase: CGFloat = 0

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { skeletonTimer?.invalidate() }

    func stopSkeletonAnimation() {
        skeletonTimer?.invalidate()
        skeletonTimer = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSkeletonAnimation()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let content = bounds.insetBy(dx: 1, dy: 1)
        let mediaRect = timelineRect(in: content)
        NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
        NSBezierPath(roundedRect: content, xRadius: 8, yRadius: 8).fill()

        let slotWidth = mediaRect.width / CGFloat(max(1, thumbnails.count))
        for (index, thumbnail) in thumbnails.enumerated() {
            let rect = NSRect(x: mediaRect.minX + CGFloat(index) * slotWidth, y: mediaRect.minY, width: slotWidth + 0.5, height: mediaRect.height)
            if let thumbnail {
                drawAspectFill(thumbnail, in: rect)
            } else {
                let wave = isLoadingThumbnails
                    ? (sin(skeletonPhase + CGFloat(index) * 0.72) + 1) / 2
                    : 0
                NSColor(calibratedWhite: 0.115 + wave * 0.075, alpha: 1).setFill()
                rect.fill()
            }
        }

        if segments.indices.contains(selectedSegmentIndex) {
            let selectedRect = rect(for: segments[selectedSegmentIndex], in: mediaRect)
            NSColor.black.withAlphaComponent(0.58).setFill()
            NSRect(x: mediaRect.minX, y: mediaRect.minY, width: max(0, selectedRect.minX - mediaRect.minX), height: mediaRect.height).fill(using: .sourceOver)
            NSRect(x: selectedRect.maxX, y: mediaRect.minY, width: max(0, mediaRect.maxX - selectedRect.maxX), height: mediaRect.height).fill(using: .sourceOver)
        }

        for (index, segment) in segments.enumerated() {
            let rangeRect = rect(for: segment, in: mediaRect)
            let selected = index == selectedSegmentIndex
            if selected {
                NSColor.systemYellow.withAlphaComponent(0.08).setFill()
                rangeRect.fill(using: .sourceOver)
                drawSelectionEdges(for: rangeRect)
                drawHandle(at: rangeRect.minX, side: .start, in: content, active: dragMode == .start)
                drawHandle(at: rangeRect.maxX, side: .end, in: content, active: dragMode == .end)
            } else {
                NSColor.systemBlue.withAlphaComponent(0.85).setStroke()
                let border = NSBezierPath(roundedRect: rangeRect.insetBy(dx: 1, dy: 5), xRadius: 4, yRadius: 4)
                border.lineWidth = 2
                border.stroke()
            }
        }

        let headX = x(for: playhead, in: mediaRect)
        NSColor.white.setStroke()
        let head = NSBezierPath()
        head.move(to: NSPoint(x: headX, y: mediaRect.minY + selectionEdgeHeight))
        head.line(to: NSPoint(x: headX, y: mediaRect.maxY - selectionEdgeHeight))
        head.lineWidth = 2
        head.stroke()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard segments.indices.contains(selectedSegmentIndex) else { return }
        let content = bounds.insetBy(dx: 1, dy: 1)
        let mediaRect = timelineRect(in: content)
        let selected = rect(for: segments[selectedSegmentIndex], in: mediaRect)
        addCursorRect(handleHitRect(at: selected.minX, in: content), cursor: .resizeLeftRight)
        addCursorRect(handleHitRect(at: selected.maxX, in: content), cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), duration > 0 else { return }
        window?.makeFirstResponder(self)
        let content = bounds.insetBy(dx: 1, dy: 1)
        let mediaRect = timelineRect(in: content)
        if selectedSegmentIndex < segments.count {
            let selected = rect(for: segments[selectedSegmentIndex], in: mediaRect)
            if handleHitRect(at: selected.minX, in: content).contains(point) {
                dragMode = .start
                beginHandleDrag(at: point)
                return
            }
            if handleHitRect(at: selected.maxX, in: content).contains(point) {
                dragMode = .end
                beginHandleDrag(at: point)
                return
            }
        }
        let seconds = time(for: point.x)
        if let hit = segments.indices.reversed().first(where: { segments[$0].start <= seconds && seconds <= segments[$0].end }) {
            selectedSegmentIndex = hit
            delegate?.timelineView(self, didSelectSegment: hit)
        }
        dragMode = .seek
        playhead = seconds
        delegate?.timelineView(self, didSeekTo: seconds)
    }

    override func mouseDragged(with event: NSEvent) {
        updateDrag(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        updateDrag(at: convert(event.locationInWindow, from: nil))
        dragMode = .none
        dragInitialSegment = nil
        needsDisplay = true
    }

    private func beginHandleDrag(at point: NSPoint) {
        dragOriginX = point.x
        dragInitialSegment = segments[selectedSegmentIndex]
        let edge = dragMode == .start ? segments[selectedSegmentIndex].start : segments[selectedSegmentIndex].end
        playhead = edge
        delegate?.timelineView(self, didSeekTo: edge)
        needsDisplay = true
    }

    private func updateDrag(at point: NSPoint) {
        let mediaRect = timelineRect(in: bounds.insetBy(dx: 1, dy: 1))
        let seconds = time(for: point.x)
        let delta = Double((point.x - dragOriginX) / max(1, mediaRect.width)) * duration
        switch dragMode {
        case .start where selectedSegmentIndex < segments.count && dragInitialSegment != nil:
            var segment = dragInitialSegment!
            segment.start = min(max(0, segment.start + delta), segment.end - minimumSegmentDuration)
            segments[selectedSegmentIndex] = segment
            playhead = segment.start
            delegate?.timelineView(self, didChangeSegment: segment, at: selectedSegmentIndex)
            delegate?.timelineView(self, didSeekTo: segment.start)
        case .end where selectedSegmentIndex < segments.count && dragInitialSegment != nil:
            var segment = dragInitialSegment!
            segment.end = max(min(duration, segment.end + delta), segment.start + minimumSegmentDuration)
            segments[selectedSegmentIndex] = segment
            playhead = segment.end
            delegate?.timelineView(self, didChangeSegment: segment, at: selectedSegmentIndex)
            delegate?.timelineView(self, didSeekTo: segment.end)
        case .seek:
            playhead = seconds
            delegate?.timelineView(self, didSeekTo: seconds)
        default:
            break
        }
    }

    private func time(for x: CGFloat) -> Double {
        let rect = timelineRect(in: bounds.insetBy(dx: 1, dy: 1))
        return min(duration, max(0, Double((x - rect.minX) / max(1, rect.width)) * duration))
    }

    private func x(for seconds: Double, in rect: NSRect) -> CGFloat {
        rect.minX + CGFloat(min(1, max(0, seconds / max(duration, 0.001)))) * rect.width
    }

    private func rect(for segment: VideoTrimSegment, in rect: NSRect) -> NSRect {
        let startX = x(for: segment.start, in: rect)
        let endX = x(for: segment.end, in: rect)
        return NSRect(x: startX, y: rect.minY, width: max(1, endX - startX), height: rect.height)
    }

    private func timelineRect(in content: NSRect) -> NSRect {
        content.insetBy(dx: handleVisualWidth / 2, dy: 0)
    }

    private func handleHitRect(at x: CGFloat, in content: NSRect) -> NSRect {
        NSRect(x: x - handleHitWidth, y: content.minY, width: handleHitWidth * 2, height: content.height)
    }

    private func drawSelectionEdges(for rangeRect: NSRect) {
        NSColor.systemYellow.setFill()
        NSRect(x: rangeRect.minX, y: rangeRect.minY, width: rangeRect.width, height: selectionEdgeHeight).fill()
        NSRect(x: rangeRect.minX, y: rangeRect.maxY - selectionEdgeHeight, width: rangeRect.width, height: selectionEdgeHeight).fill()
    }

    private func drawHandle(at x: CGFloat, side: HandleSide, in rect: NSRect, active: Bool) {
        let handle = NSRect(x: x - handleVisualWidth / 2, y: rect.minY, width: handleVisualWidth, height: rect.height)
        let path = NSBezierPath(roundedRect: handle, xRadius: 5, yRadius: 5)
        (active ? NSColor(calibratedRed: 1, green: 0.88, blue: 0.12, alpha: 1) : NSColor.systemYellow).setFill()
        path.fill()

        NSColor.black.withAlphaComponent(active ? 0.78 : 0.62).setStroke()
        let direction: CGFloat = side == .start ? -1 : 1
        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: x + direction * 2, y: handle.midY - 6))
        chevron.line(to: NSPoint(x: x - direction * 1.5, y: handle.midY))
        chevron.line(to: NSPoint(x: x + direction * 2, y: handle.midY + 6))
        chevron.lineWidth = 2
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        chevron.stroke()
    }

    private func drawAspectFill(_ image: NSImage, in rect: NSRect) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = max(rect.width / image.size.width, rect.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let destination = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        image.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func updateSkeletonAnimation() {
        let shouldAnimate = window != nil
            && isLoadingThumbnails
            && thumbnails.contains(where: { $0 == nil })
        if shouldAnimate, skeletonTimer == nil {
            skeletonTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.skeletonPhase += 0.32
                self.needsDisplay = true
            }
        } else if !shouldAnimate {
            skeletonTimer?.invalidate()
            skeletonTimer = nil
        }
    }
}

private final class VideoTrimLoadingView: NSView {
    private let shimmerLayer = CAGradientLayer()
    private let indicator = NSProgressIndicator()
    private let label = NSTextField(labelWithString: NSLocalizedString("Loading...", comment: "加载中..."))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor(calibratedWhite: 0.055, alpha: 1).cgColor

        shimmerLayer.colors = [
            NSColor(calibratedWhite: 0.07, alpha: 1).cgColor,
            NSColor(calibratedWhite: 0.14, alpha: 1).cgColor,
            NSColor(calibratedWhite: 0.07, alpha: 1).cgColor
        ]
        shimmerLayer.locations = [0, 0.5, 1]
        shimmerLayer.startPoint = CGPoint(x: -0.8, y: 0.5)
        shimmerLayer.endPoint = CGPoint(x: 0.2, y: 0.5)
        layer?.addSublayer(shimmerLayer)

        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.startAnimation(nil)
        addSubview(indicator)

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -10),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.topAnchor.constraint(equalTo: indicator.bottomAnchor, constant: 8)
        ])

        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = -240
        animation.toValue = 720
        animation.duration = 1.35
        animation.repeatCount = .infinity
        shimmerLayer.add(animation, forKey: "flowvision.trim.shimmer")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        shimmerLayer.frame = bounds.insetBy(dx: -bounds.width * 0.35, dy: 0)
    }

    func revealContent() {
        guard !isHidden else { return }
        indicator.stopAnimation(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.isHidden = true
        }
    }
}

private final class TrimAVPlayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = playerLayer
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// An image view normally reports the pixel dimensions of its image as its
/// intrinsic content size. A portrait preview (for example 1080 x 1920) would
/// therefore grow the editor window and prevent it from being resized smaller.
/// The editor owns the preview geometry, so frames must always fit that canvas.
private final class TrimPreviewImageView: NSImageView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

/// Keeps the render surface itself at the media aspect ratio. Player output,
/// deterministic preview frames and crop handles are all children of this
/// exact canvas, so none of them independently estimate letterbox insets.
private final class VideoTrimPreviewContainerView: NSView {
    let videoCanvasView = NSView()
    var displayAspectSize: NSSize = .zero {
        didSet {
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        videoCanvasView.wantsLayer = true
        videoCanvasView.layer?.backgroundColor = NSColor.black.cgColor
        addSubview(videoCanvasView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        guard displayAspectSize.width > 0, displayAspectSize.height > 0 else {
            videoCanvasView.frame = bounds
            return
        }
        videoCanvasView.frame = AVMakeRect(aspectRatio: displayAspectSize, insideRect: bounds)
    }
}

private final class VideoTrimCropOverlayView: NSView {
    var sourceSize: NSSize = .zero {
        didSet {
            if selection.pixelRect.isEmpty, sourceSize.width > 0, sourceSize.height > 0 {
                selection = .fullFrame(for: sourceSize)
            } else if oldValue.width > 0, oldValue.height > 0,
                      sourceSize.width > 0, sourceSize.height > 0,
                      oldValue != sourceSize {
                let oldRect = selection.pixelRect
                selection = VideoTrimCropSelection(pixelRect: NSRect(
                    x: oldRect.minX / oldValue.width * sourceSize.width,
                    y: oldRect.minY / oldValue.height * sourceSize.height,
                    width: oldRect.width / oldValue.width * sourceSize.width,
                    height: oldRect.height / oldValue.height * sourceSize.height
                ))
            }
            needsDisplay = true
        }
    }
    var selection: VideoTrimCropSelection = .empty {
        didSet {
            needsDisplay = true
            discardCursorRects()
        }
    }
    var cropEnabled = false {
        didSet {
            isHidden = !cropEnabled
            needsDisplay = true
            discardCursorRects()
        }
    }
    var onSelectionChanged: ((VideoTrimCropSelection) -> Void)?

    private enum DragMode {
        case none, create, move
        case left, right, top, bottom
        case topLeft, topRight, bottomLeft, bottomRight
    }

    private var dragMode: DragMode = .none
    private var dragStartPoint = NSPoint.zero
    private var dragStartRect = NSRect.zero
    private let handleRadius: CGFloat = 5.5
    private let hitTolerance: CGFloat = 14
    private let minimumDisplaySize: CGFloat = 24

    private var geometry: VideoCropGeometry {
        VideoCropGeometry(sourcePixelSize: sourceSize, canvasBounds: bounds)
    }

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.zPosition = 30
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard cropEnabled, let videoRect = videoContentRect else { return }
        let cropRect = geometry.canvasRect(for: selection.pixelRect)

        let shade = NSBezierPath(rect: bounds)
        shade.appendRect(cropRect)
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.58).setFill()
        shade.fill()

        NSColor.white.withAlphaComponent(0.28).setStroke()
        let thirds = NSBezierPath()
        for fraction in [CGFloat(1.0 / 3.0), CGFloat(2.0 / 3.0)] {
            let x = cropRect.minX + cropRect.width * fraction
            thirds.move(to: NSPoint(x: x, y: cropRect.minY))
            thirds.line(to: NSPoint(x: x, y: cropRect.maxY))
            let y = cropRect.minY + cropRect.height * fraction
            thirds.move(to: NSPoint(x: cropRect.minX, y: y))
            thirds.line(to: NSPoint(x: cropRect.maxX, y: y))
        }
        thirds.lineWidth = 1
        thirds.stroke()

        NSColor.white.setStroke()
        let border = NSBezierPath(rect: cropRect.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        border.stroke()

        for point in handlePoints(for: cropRect) {
            let handleRect = NSRect(
                x: point.x - handleRadius,
                y: point.y - handleRadius,
                width: handleRadius * 2,
                height: handleRadius * 2
            )
            NSColor.black.withAlphaComponent(0.72).setFill()
            NSBezierPath(ovalIn: handleRect.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: handleRect).fill()
        }

        let pixelSize = cropPixelSize
        let sizeText = "\(pixelSize.width) × \(pixelSize.height)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = sizeText.size(withAttributes: attributes)
        var badge = NSRect(
            x: cropRect.minX,
            y: cropRect.maxY + 8,
            width: textSize.width + 16,
            height: textSize.height + 8
        )
        if badge.maxY > videoRect.maxY {
            badge.origin.y = cropRect.maxY - badge.height - 8
        }
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 6, yRadius: 6).fill()
        sizeText.draw(
            at: NSPoint(x: badge.minX + 8, y: badge.minY + 4),
            withAttributes: attributes
        )
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard cropEnabled, videoContentRect != nil else { return }
        let rect = geometry.canvasRect(for: selection.pixelRect)
        let cursorPairs: [(NSPoint, NSCursor)] = [
            (NSPoint(x: rect.minX, y: rect.minY), .crosshair),
            (NSPoint(x: rect.maxX, y: rect.minY), .crosshair),
            (NSPoint(x: rect.minX, y: rect.maxY), .crosshair),
            (NSPoint(x: rect.maxX, y: rect.maxY), .crosshair),
            (NSPoint(x: rect.midX, y: rect.minY), .resizeUpDown),
            (NSPoint(x: rect.midX, y: rect.maxY), .resizeUpDown),
            (NSPoint(x: rect.minX, y: rect.midY), .resizeLeftRight),
            (NSPoint(x: rect.maxX, y: rect.midY), .resizeLeftRight)
        ]
        for (point, cursor) in cursorPairs {
            addCursorRect(
                NSRect(x: point.x - hitTolerance, y: point.y - hitTolerance, width: hitTolerance * 2, height: hitTolerance * 2),
                cursor: cursor
            )
        }
        addCursorRect(rect.insetBy(dx: hitTolerance, dy: hitTolerance), cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard cropEnabled, let videoRect = videoContentRect else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard videoRect.contains(point) else { return }
        window?.makeFirstResponder(self)
        dragStartPoint = point
        dragStartRect = geometry.canvasRect(for: selection.pixelRect)
        dragMode = dragMode(at: point, selectionRect: dragStartRect)
        if dragMode == .create {
            dragStartRect = NSRect(origin: point, size: .zero)
        } else if dragMode == .move {
            NSCursor.closedHand.set()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard cropEnabled, dragMode != .none, let videoRect = videoContentRect else { return }
        let rawPoint = convert(event.locationInWindow, from: nil)
        let point = NSPoint(
            x: min(max(rawPoint.x, videoRect.minX), videoRect.maxX),
            y: min(max(rawPoint.y, videoRect.minY), videoRect.maxY)
        )
        var rect = dragStartRect
        let dx = point.x - dragStartPoint.x
        let dy = point.y - dragStartPoint.y

        switch dragMode {
        case .create:
            rect = NSRect(
                x: min(dragStartPoint.x, point.x),
                y: min(dragStartPoint.y, point.y),
                width: abs(dx),
                height: abs(dy)
            )
        case .move:
            rect.origin.x = min(max(videoRect.minX, dragStartRect.minX + dx), videoRect.maxX - rect.width)
            rect.origin.y = min(max(videoRect.minY, dragStartRect.minY + dy), videoRect.maxY - rect.height)
        case .left, .topLeft, .bottomLeft:
            rect.origin.x = min(point.x, dragStartRect.maxX - minimumDisplaySize)
            rect.size.width = dragStartRect.maxX - rect.minX
        case .right, .topRight, .bottomRight:
            rect.size.width = max(minimumDisplaySize, point.x - dragStartRect.minX)
        default:
            break
        }

        switch dragMode {
        case .top, .topLeft, .topRight:
            rect.size.height = max(minimumDisplaySize, point.y - dragStartRect.minY)
        case .bottom, .bottomLeft, .bottomRight:
            rect.origin.y = min(point.y, dragStartRect.maxY - minimumDisplaySize)
            rect.size.height = dragStartRect.maxY - rect.minY
        default:
            break
        }

        rect = rect.intersection(videoRect)
        guard rect.width >= minimumDisplaySize, rect.height >= minimumDisplaySize else { return }
        selection = VideoTrimCropSelection(pixelRect: geometry.pixelRect(for: rect))
        onSelectionChanged?(selection)
    }

    override func mouseUp(with event: NSEvent) {
        dragMode = .none
        NSCursor.arrow.set()
    }

    func setAspectRatio(_ ratio: CGFloat?) {
        guard geometry.isValid else { return }
        guard let ratio, ratio > 0 else {
            selection = .fullFrame(for: sourceSize)
            onSelectionChanged?(selection)
            return
        }
        let fullPixels = geometry.fullPixelRect
        var size = fullPixels.size
        if size.width / size.height > ratio {
            size.width = size.height * ratio
        } else {
            size.height = size.width / ratio
        }
        let rect = NSRect(
            x: fullPixels.midX - size.width / 2,
            y: fullPixels.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        selection = VideoTrimCropSelection(pixelRect: rect)
        onSelectionChanged?(selection)
    }

    var cropPixelSize: (width: Int, height: Int) {
        guard let rect = geometry.evenFFmpegRect(for: selection.pixelRect) else { return (0, 0) }
        return (rect.width, rect.height)
    }

    private var videoContentRect: NSRect? {
        guard geometry.isValid else { return nil }
        return bounds
    }

    private func handlePoints(for rect: NSRect) -> [NSPoint] {
        [
            NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.midX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.minY),
            NSPoint(x: rect.minX, y: rect.midY), NSPoint(x: rect.maxX, y: rect.midY),
            NSPoint(x: rect.minX, y: rect.maxY), NSPoint(x: rect.midX, y: rect.maxY), NSPoint(x: rect.maxX, y: rect.maxY)
        ]
    }

    private func dragMode(at point: NSPoint, selectionRect rect: NSRect) -> DragMode {
        let nearLeft = abs(point.x - rect.minX) <= hitTolerance
        let nearRight = abs(point.x - rect.maxX) <= hitTolerance
        // AppKit view coordinates are bottom-origin. Keep the overlay in the
        // same coordinate space as NSImageView and only flip Y when creating
        // the top-origin FFmpeg crop expression.
        let nearTop = abs(point.y - rect.maxY) <= hitTolerance
        let nearBottom = abs(point.y - rect.minY) <= hitTolerance
        if nearLeft && nearTop { return .topLeft }
        if nearRight && nearTop { return .topRight }
        if nearLeft && nearBottom { return .bottomLeft }
        if nearRight && nearBottom { return .bottomRight }
        if nearLeft { return .left }
        if nearRight { return .right }
        if nearTop { return .top }
        if nearBottom { return .bottom }
        if rect.contains(point) { return .move }
        return .create
    }
}

final class VideoTrimEditorWindowController: NSWindowController, NSWindowDelegate, VideoTrimTimelineViewDelegate {
    private let sourceURL: URL
    private let duration: Double
    private let sourceSize: NSSize?
    private let initialMode: VideoTrimEditorMode
    private let completion: ([VideoTrimSegment], ViewController.VideoCropRect?) -> Void
    private let onClose: () -> Void
    private let initialStartTime: Double
    private var segments: [VideoTrimSegment]
    private var selectedSegmentIndex = 0
    private var isClosed = false

    private let previewContainer = VideoTrimPreviewContainerView()
    private let mpvView = FlowMPVVideoView()
    private var mpvPlayer: MPVPlayerBackend?
    private let avView = TrimAVPlayerView()
    private var avPlayer: AVPlayer?
    private let framePreviewView = TrimPreviewImageView()
    private let previewLoadingView = VideoTrimLoadingView()
    private let cropOverlayView = VideoTrimCropOverlayView()
    private let timelineView = VideoTrimTimelineView()
    private let playButton = NSButton()
    private let timeLabel = NSTextField(labelWithString: "")
    private let segmentPopup = NSPopUpButton()
    private let deleteSegmentButton = NSButton()
    private let cropSizeLabel = NSTextField(labelWithString: "")
    private let cropAspectPopup = NSPopUpButton()
    private let exportButton = NSButton()
    private var progressTimer: Timer?
    private var didStartLoading = false
    private var previewRequestInFlight = false
    private var pendingPreviewRequest: (seconds: Double, generation: Int)?
    private var previewGeneration = 0
    private var playbackRequested = false
    private var thumbnailJobsRemaining = 0
    private let frameExtractionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "netdcy.FlowVision.VideoTrimFrameExtraction"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    init(
        sourceURL: URL,
        duration: Double,
        sourceSize: NSSize?,
        initialSegment: VideoTrimSegment,
        initialMode: VideoTrimEditorMode = .trim,
        onClose: @escaping () -> Void,
        completion: @escaping ([VideoTrimSegment], ViewController.VideoCropRect?) -> Void
    ) {
        self.sourceURL = sourceURL
        self.duration = duration
        self.sourceSize = sourceSize
        self.initialMode = initialMode
        self.completion = completion
        self.onClose = onClose
        self.initialStartTime = initialSegment.start
        self.segments = [initialSegment]

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = sourceURL.lastPathComponent
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1)
        window.contentMinSize = NSSize(width: 720, height: 460)
        window.contentResizeIncrements = NSSize(width: 1, height: 1)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildInterface()
        configureCropControls()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        fitInitialWindowToVisibleScreen()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.contentView?.layoutSubtreeIfNeeded()
        guard !didStartLoading else { return }
        didStartLoading = true
        configurePlayback(startTime: initialStartTime)
        requestPreviewFrame(at: initialStartTime)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.generateThumbnails()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard !isClosed else { return }
        isClosed = true
        progressTimer?.invalidate()
        progressTimer = nil
        previewGeneration += 1
        pendingPreviewRequest = nil
        frameExtractionQueue.cancelAllOperations()
        timelineView.stopSkeletonAnimation()
        mpvPlayer?.stop()
        mpvPlayer = nil
        avPlayer?.pause()
        avPlayer = nil
        onClose()
    }

    private func fitInitialWindowToVisibleScreen() {
        guard let window, let screen = window.screen ?? NSScreen.main else {
            window?.center()
            return
        }

        let visible = screen.visibleFrame.insetBy(dx: 24, dy: 24)
        let targetContentSize = NSSize(
            width: min(1120, visible.width),
            height: min(760, visible.height)
        )
        window.setContentSize(targetContentSize)
        window.setFrameOrigin(NSPoint(
            x: visible.midX - window.frame.width / 2,
            y: visible.midY - window.frame.height / 2
        ))
        window.setFrame(window.constrainFrameRect(window.frame, to: screen), display: false)
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.wantsLayer = true
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        let metadata = makeMetadataBar()
        metadata.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(metadata)

        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.displayAspectSize = sourceSize ?? NSSize(width: 16, height: 9)
        root.addSubview(previewContainer)

        timelineView.translatesAutoresizingMaskIntoConstraints = false
        timelineView.duration = duration
        timelineView.segments = segments
        timelineView.selectedSegmentIndex = selectedSegmentIndex
        timelineView.playhead = segments[0].start
        timelineView.delegate = self
        root.addSubview(timelineView)

        let bottomBar = makeBottomBar()
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            // fullSizeContentView lets this metadata share the actual titlebar
            // row. The leading inset clears the traffic-light controls.
            metadata.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 92),
            metadata.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            metadata.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            metadata.heightAnchor.constraint(equalToConstant: 28),

            previewContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            previewContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            previewContainer.topAnchor.constraint(equalTo: metadata.bottomAnchor, constant: 8),
            previewContainer.bottomAnchor.constraint(equalTo: timelineView.topAnchor, constant: -10),

            timelineView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            timelineView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            timelineView.heightAnchor.constraint(equalToConstant: 56),
            timelineView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -8),

            bottomBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            bottomBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            bottomBar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            bottomBar.heightAnchor.constraint(equalToConstant: 38)
        ])
    }

    private func makeMetadataBar() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 14

        let fileLabel = NSTextField(labelWithString: sourceURL.lastPathComponent)
        fileLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        fileLabel.textColor = .secondaryLabelColor
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(fileLabel)
        stack.addArrangedSubview(makeMetadataLabel(symbol: "clock", text: formatCompactTime(duration)))
        if let sourceSize {
            stack.addArrangedSubview(makeMetadataLabel(symbol: "rectangle", text: "\(Int(sourceSize.width)) × \(Int(sourceSize.height))"))
        }
        if let bytes = try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            stack.addArrangedSubview(makeMetadataLabel(symbol: "internaldrive", text: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))
        }
        return stack
    }

    private func makeMetadataLabel(symbol: String, text: String) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        image.contentTintColor = .tertiaryLabelColor
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(image)
        stack.addArrangedSubview(label)
        return stack
    }

    private func makeBottomBar() -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 1).cgColor
        bar.layer?.cornerRadius = 9

        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: NSLocalizedString("Play", comment: "播放"))
        playButton.bezelStyle = .texturedRounded
        playButton.target = self
        playButton.action = #selector(togglePlayback)

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        timeLabel.textColor = .secondaryLabelColor

        segmentPopup.target = self
        segmentPopup.action = #selector(selectSegmentFromPopup)
        segmentPopup.bezelStyle = .rounded

        let addButton = NSButton(title: NSLocalizedString("Add Segment", comment: "添加片段"), target: self, action: #selector(addSegment))
        addButton.bezelStyle = .texturedRounded
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)

        deleteSegmentButton.bezelStyle = .texturedRounded
        deleteSegmentButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: NSLocalizedString("Delete Segment", comment: "删除片段"))
        deleteSegmentButton.target = self
        deleteSegmentButton.action = #selector(deleteSegment)

        cropSizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        cropSizeLabel.textColor = .secondaryLabelColor
        cropSizeLabel.toolTip = NSLocalizedString("Crop Output Size", comment: "裁剪输出尺寸")

        cropAspectPopup.target = self
        cropAspectPopup.action = #selector(changeCropAspect)
        cropAspectPopup.bezelStyle = .rounded
        cropAspectPopup.toolTip = NSLocalizedString("Crop Aspect Ratio", comment: "裁剪比例")

        let destinationLabel = NSTextField(labelWithString: NSLocalizedString("Save to Original Folder", comment: "保存到原文件夹"))
        destinationLabel.font = .systemFont(ofSize: 12, weight: .medium)
        destinationLabel.textColor = .tertiaryLabelColor

        let cancelButton = NSButton(title: NSLocalizedString("Cancel", comment: "取消"), target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded

        exportButton.target = self
        exportButton.action = #selector(export)
        exportButton.bezelStyle = .rounded
        exportButton.keyEquivalent = "\r"
        exportButton.contentTintColor = .controlAccentColor

        let controls = NSStackView(views: [
            playButton,
            timeLabel,
            segmentPopup,
            addButton,
            deleteSegmentButton,
            cropSizeLabel,
            cropAspectPopup,
            destinationLabel,
            NSView(),
            cancelButton,
            exportButton
        ])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 10
        controls.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            controls.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            controls.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 34),
            segmentPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 170),
            cropAspectPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 104),
            cancelButton.widthAnchor.constraint(equalToConstant: 70),
            exportButton.widthAnchor.constraint(equalToConstant: 100)
        ])
        refreshSegmentControls()
        return bar
    }

    private func configurePlayback(startTime: Double) {
        let videoCanvas = previewContainer.videoCanvasView
        mpvView.translatesAutoresizingMaskIntoConstraints = false
        avView.translatesAutoresizingMaskIntoConstraints = false
        videoCanvas.addSubview(mpvView)
        videoCanvas.addSubview(avView)
        videoCanvas.addSubview(framePreviewView)
        videoCanvas.addSubview(previewLoadingView)
        videoCanvas.addSubview(cropOverlayView)
        framePreviewView.translatesAutoresizingMaskIntoConstraints = false
        framePreviewView.imageScaling = .scaleProportionallyUpOrDown
        framePreviewView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        framePreviewView.setContentHuggingPriority(.defaultLow, for: .vertical)
        framePreviewView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        framePreviewView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        framePreviewView.wantsLayer = true
        framePreviewView.layer?.backgroundColor = NSColor.black.cgColor
        framePreviewView.isHidden = true
        // CAOpenGLLayer may recompose after its first swap. Explicit z-order
        // keeps the deterministic FFmpeg frame and loading skeleton above it.
        framePreviewView.layer?.zPosition = 10
        previewLoadingView.translatesAutoresizingMaskIntoConstraints = false
        previewLoadingView.layer?.zPosition = 20
        cropOverlayView.translatesAutoresizingMaskIntoConstraints = false
        cropOverlayView.sourceSize = sourceSize ?? .zero
        cropOverlayView.onSelectionChanged = { [weak self] _ in
            self?.refreshCropSizeLabel()
        }
        for view in [mpvView, avView, framePreviewView, previewLoadingView, cropOverlayView] {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: videoCanvas.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: videoCanvas.trailingAnchor),
                view.topAnchor.constraint(equalTo: videoCanvas.topAnchor),
                view.bottomAnchor.constraint(equalTo: videoCanvas.bottomAnchor)
            ])
        }

        avView.isHidden = true
        if let backend = MPVPlayerBackend(renderView: mpvView),
           backend.load(url: sourceURL, startTime: startTime, volume: globalVar.videoVolume, rate: 1, rotation: 0, abRange: nil, loop: false, endHandler: nil) {
            mpvPlayer = backend
            backend.setPaused(true)
        } else {
            mpvView.isHidden = true
            avView.isHidden = false
            let player = AVPlayer(url: sourceURL)
            avPlayer = player
            avView.playerLayer.player = player
            player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600))
            player.pause()
        }

        // libmpv finishes attaching its render context asynchronously. Seek
        // once more after the window is visible so the first preview frame is
        // presented even when the source player had already reached EOF.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, !self.isClosed else { return }
            self.seek(to: startTime, requestPreview: false)
            self.setPaused(true, requestPreview: false)
            if self.framePreviewView.image == nil {
                self.showPlaybackSurface()
            }
            // The real player remains a complete fallback when FFmpegKit is
            // unavailable or a deterministic preview frame cannot be decoded.
            self.previewLoadingView.revealContent()
        }

        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            self?.updatePlaybackProgress()
        }
    }

    private func updatePlaybackProgress() {
        let current = currentTime
        guard current.isFinite else { return }
        timelineView.playhead = current
        if selectedSegmentIndex < segments.count, current >= segments[selectedSegmentIndex].end {
            setPaused(true, requestPreview: false)
            seek(to: segments[selectedSegmentIndex].start)
        }
        refreshTimeLabel()
        refreshPlayButton()
    }

    private var currentTime: Double {
        if let mpvPlayer { return mpvPlayer.currentTime }
        return avPlayer?.currentTime().seconds ?? 0
    }

    private var isPlaying: Bool {
        playbackRequested
    }

    private func seek(to seconds: Double, requestPreview: Bool = true) {
        let bounded = min(duration, max(0, seconds))
        mpvPlayer?.seek(to: bounded)
        avPlayer?.seek(to: CMTime(seconds: bounded, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        timelineView.playhead = bounded
        if requestPreview {
            requestPreviewFrame(at: bounded)
        }
        refreshTimeLabel()
    }

    private func setPaused(_ paused: Bool, requestPreview: Bool = true) {
        playbackRequested = !paused
        if !paused {
            showPlaybackSurface()
        }
        mpvPlayer?.setPaused(paused)
        if paused { avPlayer?.pause() } else { avPlayer?.play() }
        if paused, requestPreview {
            requestPreviewFrame(at: currentTime)
        }
        refreshPlayButton()
    }

    @objc private func togglePlayback() {
        if isPlaying {
            setPaused(true)
        } else {
            if selectedSegmentIndex < segments.count,
               (currentTime < segments[selectedSegmentIndex].start || currentTime >= segments[selectedSegmentIndex].end) {
                seek(to: segments[selectedSegmentIndex].start, requestPreview: false)
            }
            setPaused(false)
        }
    }

    @objc private func selectSegmentFromPopup() {
        let index = segmentPopup.indexOfSelectedItem
        guard segments.indices.contains(index) else { return }
        setPaused(true, requestPreview: false)
        selectedSegmentIndex = index
        timelineView.selectedSegmentIndex = index
        seek(to: segments[index].start)
        refreshSegmentControls()
    }

    @objc private func addSegment() {
        setPaused(true, requestPreview: false)
        let start = min(max(0, currentTime), max(0, duration - 0.1))
        let end = min(duration, max(start + 0.1, start + min(10, duration * 0.2)))
        segments.append(VideoTrimSegment(start: start, end: end))
        selectedSegmentIndex = segments.count - 1
        timelineView.segments = segments
        timelineView.selectedSegmentIndex = selectedSegmentIndex
        seek(to: start)
        refreshSegmentControls()
    }

    @objc private func deleteSegment() {
        guard segments.count > 1, segments.indices.contains(selectedSegmentIndex) else { return }
        setPaused(true, requestPreview: false)
        segments.remove(at: selectedSegmentIndex)
        selectedSegmentIndex = min(selectedSegmentIndex, segments.count - 1)
        timelineView.segments = segments
        timelineView.selectedSegmentIndex = selectedSegmentIndex
        seek(to: segments[selectedSegmentIndex].start)
        refreshSegmentControls()
    }

    @objc private func cancel() { close() }

    @objc private func export() {
        let validSegments = segments
            .filter { $0.start >= 0 && $0.end <= duration + 0.001 && $0.duration > 0.05 }
            .sorted { $0.start < $1.start }
        guard !validSegments.isEmpty else { NSSound.beep(); return }
        completion(validSegments, makeCropRect())
        close()
    }

    fileprivate func timelineView(_ timeline: VideoTrimTimelineView, didSeekTo seconds: Double) {
        setPaused(true, requestPreview: false)
        seek(to: seconds)
    }

    fileprivate func timelineView(_ timeline: VideoTrimTimelineView, didSelectSegment index: Int) {
        guard segments.indices.contains(index) else { return }
        selectedSegmentIndex = index
        refreshSegmentControls()
    }

    fileprivate func timelineView(_ timeline: VideoTrimTimelineView, didChangeSegment segment: VideoTrimSegment, at index: Int) {
        guard segments.indices.contains(index) else { return }
        segments[index] = segment
        refreshSegmentControls()
    }

    private func refreshSegmentControls() {
        segmentPopup.removeAllItems()
        for (index, segment) in segments.enumerated() {
            segmentPopup.addItem(withTitle: String(format: NSLocalizedString("Segment %d  %@–%@", comment: "片段 %d  %@–%@"), index + 1, formatCompactTime(segment.start), formatCompactTime(segment.end)))
        }
        segmentPopup.selectItem(at: selectedSegmentIndex)
        deleteSegmentButton.isEnabled = segments.count > 1
        exportButton.title = String(format: NSLocalizedString("Export %d Clips", comment: "导出 %d 段"), segments.count)
        timelineView.segments = segments
        timelineView.selectedSegmentIndex = selectedSegmentIndex
        refreshTimeLabel()
        refreshCropSizeLabel()
    }

    private func configureCropControls() {
        cropAspectPopup.removeAllItems()
        cropAspectPopup.addItems(withTitles: [
            NSLocalizedString("No Crop", comment: "不裁剪"),
            NSLocalizedString("Free Crop", comment: "自由裁剪"),
            "16:9",
            "4:3",
            "1:1",
            "9:16"
        ])
        cropAspectPopup.isEnabled = sourceSize != nil
        cropAspectPopup.selectItem(at: initialMode == .crop ? 1 : 0)
        cropOverlayView.cropEnabled = initialMode == .crop && sourceSize != nil
        if let sourceSize {
            cropOverlayView.selection = .fullFrame(for: sourceSize)
        }
        refreshCropSizeLabel()
    }

    @objc private func changeCropAspect() {
        guard let sourceSize else { return }
        let index = cropAspectPopup.indexOfSelectedItem
        cropOverlayView.cropEnabled = index > 0
        switch index {
        case 0:
            cropOverlayView.selection = .fullFrame(for: sourceSize)
        case 1:
            if cropOverlayView.selection.pixelRect.isEmpty {
                cropOverlayView.selection = .fullFrame(for: sourceSize)
            }
        case 2:
            cropOverlayView.setAspectRatio(16.0 / 9.0)
        case 3:
            cropOverlayView.setAspectRatio(4.0 / 3.0)
        case 4:
            cropOverlayView.setAspectRatio(1)
        case 5:
            cropOverlayView.setAspectRatio(9.0 / 16.0)
        default:
            break
        }
        refreshCropSizeLabel()
    }

    private func refreshCropSizeLabel() {
        let effectiveSourceSize = cropOverlayView.sourceSize
        guard effectiveSourceSize.width > 0, effectiveSourceSize.height > 0 else {
            cropSizeLabel.stringValue = NSLocalizedString("Crop Unavailable", comment: "无法裁剪")
            return
        }
        let size: (width: Int, height: Int)
        if cropOverlayView.cropEnabled {
            size = cropOverlayView.cropPixelSize
        } else {
            size = (Int(effectiveSourceSize.width), Int(effectiveSourceSize.height))
        }
        cropSizeLabel.stringValue = "✂︎ \(size.width) × \(size.height)"
    }

    private func makeCropRect() -> ViewController.VideoCropRect? {
        guard cropOverlayView.cropEnabled else { return nil }
        let sourceSize = cropOverlayView.sourceSize
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }
        let pixels = cropOverlayView.selection.pixelRect
        if abs(pixels.minX) <= 1,
           abs(pixels.minY) <= 1,
           abs(pixels.width - sourceSize.width) <= 1,
           abs(pixels.height - sourceSize.height) <= 1 {
            return nil
        }
        let geometry = VideoCropGeometry(sourcePixelSize: sourceSize, canvasBounds: cropOverlayView.bounds)
        guard let rect = geometry.evenFFmpegRect(for: pixels) else { return nil }
        return ViewController.VideoCropRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    private func refreshTimeLabel() {
        guard segments.indices.contains(selectedSegmentIndex) else { return }
        let segment = segments[selectedSegmentIndex]
        timeLabel.stringValue = "\(formatCompactTime(segment.start)) ~ \(formatCompactTime(segment.end))"
    }

    private func refreshPlayButton() {
        let name = isPlaying ? "pause.fill" : "play.fill"
        playButton.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    private func generateThumbnails() {
        let count = timelineView.thumbnails.count
        guard FFmpegKitWrapper.shared.getIfLoaded() else {
            timelineView.isLoadingThumbnails = false
            return
        }
        thumbnailJobsRemaining = count
        for index in 0..<count {
            let operation = BlockOperation { [weak self] in
                guard let self else { return }
                let time = index == 0
                    ? min(self.duration, 0.05)
                    : self.duration * (Double(index) + 0.5) / Double(count)
                let output = FileManager.default.temporaryDirectory
                    .appendingPathComponent("FlowVision-trim-thumb-\(UUID().uuidString).jpg")
                let posix = Locale(identifier: "en_US_POSIX")
                let scaleFilter = "scale=240:135:force_original_aspect_ratio=increase,crop=240:135"
                let args = [
                    "-y", "-ss", String(format: "%.3f", locale: posix, time), "-noaccurate_seek",
                    "-i", self.sourceURL.path,
                    "-map", "0:v:0", "-frames:v", "1",
                    "-vf", scaleFilter,
                    "-q:v", "5", "-update", "1", output.path
                ]
                var image: NSImage?
                if let session = FFmpegKitWrapper.shared.executeFFmpegCommand(args),
                   FFmpegKitWrapper.shared.isSuccess(FFmpegKitWrapper.shared.getReturnCode(from: session)),
                   let data = try? Data(contentsOf: output) {
                    image = NSImage(data: data)
                }
                try? FileManager.default.removeItem(at: output)

                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.isClosed else { return }
                    if let image {
                        self.timelineView.thumbnails[index] = image
                    }
                    self.thumbnailJobsRemaining -= 1
                    if self.thumbnailJobsRemaining == 0 {
                        self.timelineView.isLoadingThumbnails = false
                    }
                }
            }
            operation.queuePriority = .veryLow
            operation.qualityOfService = .utility
            frameExtractionQueue.addOperation(operation)
        }
    }

    /// The real player owns continuous playback. FFmpeg frames are used only
    /// while paused/scrubbing, and high-priority preview jobs can jump ahead of
    /// the remaining low-priority timeline thumbnails between decoder calls.
    private func requestPreviewFrame(at seconds: Double) {
        let bounded = min(duration, max(0, seconds))
        previewGeneration += 1
        let generation = previewGeneration
        pendingPreviewRequest = (bounded, generation)
        schedulePendingPreviewRequest()
    }

    private func schedulePendingPreviewRequest() {
        guard !previewRequestInFlight,
              let request = pendingPreviewRequest else { return }
        pendingPreviewRequest = nil
        previewRequestInFlight = true

        let operation = BlockOperation { [weak self] in
            guard let self else { return }
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("FlowVision-trim-preview-\(UUID().uuidString).jpg")
            let posix = Locale(identifier: "en_US_POSIX")
            var args = ["-y"]
            if request.seconds > 0.01 {
                // Input-side seek still starts at the nearby keyframe, while
                // FFmpeg's normal accurate-seek discard keeps the paused frame
                // aligned with the selected timestamp.
                args += ["-ss", String(format: "%.3f", locale: posix, request.seconds)]
            }
            args += [
                "-i", self.sourceURL.path,
                "-map", "0:v:0", "-frames:v", "1",
                "-vf", "scale=1280:-2:force_original_aspect_ratio=decrease",
                "-q:v", "3", "-update", "1", output.path
            ]
            var image: NSImage?
            if FFmpegKitWrapper.shared.getIfLoaded(),
               let session = FFmpegKitWrapper.shared.executeFFmpegCommand(args),
               FFmpegKitWrapper.shared.isSuccess(FFmpegKitWrapper.shared.getReturnCode(from: session)),
               let data = try? Data(contentsOf: output) {
                image = NSImage(data: data)
            }
            try? FileManager.default.removeItem(at: output)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if request.generation == self.previewGeneration, let image {
                    self.displayPreviewImage(image)
                }
                self.previewRequestInFlight = false
                self.schedulePendingPreviewRequest()
            }
        }
        operation.queuePriority = .veryHigh
        operation.qualityOfService = .userInitiated
        frameExtractionQueue.addOperation(operation)
    }

    private func displayPreviewImage(_ image: NSImage) {
        framePreviewView.image = image
        previewContainer.displayAspectSize = image.size
        if let sourceSize,
           (sourceSize.width >= sourceSize.height) != (image.size.width >= image.size.height) {
            cropOverlayView.sourceSize = NSSize(width: sourceSize.height, height: sourceSize.width)
        }
        refreshCropSizeLabel()
        if !playbackRequested {
            framePreviewView.isHidden = false
            mpvView.isHidden = true
            avView.isHidden = true
        }
        previewLoadingView.revealContent()
    }

    private func showPlaybackSurface() {
        framePreviewView.isHidden = true
        if mpvPlayer != nil {
            mpvView.isHidden = false
            avView.isHidden = true
        } else {
            mpvView.isHidden = true
            avView.isHidden = false
        }
        previewLoadingView.revealContent()
    }

    private func formatCompactTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, remainder) }
        return String(format: "%02d:%02d", minutes, remainder)
    }
}
