//
//  CurtainModeView.swift
//  FlowVision
//

import Cocoa

enum CurtainTransitionAxis {
    case horizontal
    case vertical
}

final class CurtainModeView: NSView {
    private let ambientGlow = NSView()
    private let leftCard = CurtainMediaCardView()
    private let rightCard = CurtainMediaCardView()
    private let centerPlate = NSView()
    private var transitionOverlay: NSImageView?
    private var isPresented = false
    private var presentationGeneration = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.08).cgColor

        ambientGlow.wantsLayer = true
        let glow = CAGradientLayer()
        glow.type = .radial
        glow.colors = [
            NSColor.white.withAlphaComponent(0.13).cgColor,
            NSColor.controlAccentColor.withAlphaComponent(0.045).cgColor,
            NSColor.clear.cgColor,
        ]
        glow.locations = [0, 0.38, 1]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        ambientGlow.layer = glow
        addSubview(ambientGlow)

        addSubview(leftCard)
        addSubview(rightCard)

        centerPlate.wantsLayer = true
        centerPlate.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.34).cgColor
        centerPlate.layer?.cornerRadius = 20
        centerPlate.layer?.borderWidth = 1
        centerPlate.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        centerPlate.layer?.shadowColor = NSColor.black.cgColor
        centerPlate.layer?.shadowOpacity = 0.66
        centerPlate.layer?.shadowRadius = 34
        centerPlate.layer?.shadowOffset = NSSize(width: 0, height: -14)
        addSubview(centerPlate)
    }

    override func layout() {
        super.layout()
        ambientGlow.frame = bounds.insetBy(dx: -bounds.width * 0.08, dy: -bounds.height * 0.08)
        ambientGlow.layer?.frame = ambientGlow.bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func update(left: FileModel?, right: FileModel?) {
        leftCard.update(file: left, side: .left)
        rightCard.update(file: right, side: .right)
    }

    func layoutCards(centerFrame: NSRect, animated: Bool) {
        let sideWidth = max(130, centerFrame.width * 0.52)
        let sideHeight = max(100, centerFrame.height * 0.52)
        let visibleOffset = max(70, centerFrame.width * 0.405)
        let verticalOffset = centerFrame.height * 0.055
        let leftFrame = NSRect(
            x: centerFrame.midX - visibleOffset - sideWidth / 2,
            y: centerFrame.midY - sideHeight / 2 - verticalOffset,
            width: sideWidth,
            height: sideHeight
        )
        let rightFrame = NSRect(
            x: centerFrame.midX + visibleOffset - sideWidth / 2,
            y: centerFrame.midY - sideHeight / 2 - verticalOffset,
            width: sideWidth,
            height: sideHeight
        )

        let applyFrames = {
            self.centerPlate.frame = centerFrame.insetBy(dx: -2, dy: -2)
            self.leftCard.frame = leftFrame
            self.rightCard.frame = rightFrame
            self.leftCard.alphaValue = self.leftCard.hasMedia ? 0.68 : 0
            self.rightCard.alphaValue = self.rightCard.hasMedia ? 0.68 : 0
            self.leftCard.applyRestingDepth(side: .left)
            self.rightCard.applyRestingDepth(side: .right)
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.38
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.76, 0.20, 1)
                self.centerPlate.animator().frame = centerFrame.insetBy(dx: -2, dy: -2)
                self.leftCard.animator().frame = leftFrame
                self.rightCard.animator().frame = rightFrame
                self.leftCard.animator().alphaValue = self.leftCard.hasMedia ? 0.68 : 0
                self.rightCard.animator().alphaValue = self.rightCard.hasMedia ? 0.68 : 0
            }
            leftCard.applyRestingDepth(side: .left, animated: true)
            rightCard.applyRestingDepth(side: .right, animated: true)
        } else {
            applyFrames()
        }
    }

    func animateSwitch(direction: Int, axis: CurtainTransitionAxis, centerFrame: NSRect) {
        let card = direction < 0 ? leftCard : rightCard
        guard card.hasMedia else { return }
        transitionOverlay?.removeFromSuperview()
        guard let snapshot = card.snapshotImage() else { return }

        let overlay = NSImageView(frame: card.frame)
        overlay.image = snapshot
        overlay.imageScaling = .scaleAxesIndependently
        overlay.wantsLayer = true
        overlay.layer?.cornerRadius = 18
        overlay.layer?.masksToBounds = false
        overlay.layer?.shadowColor = NSColor.black.cgColor
        overlay.layer?.shadowOpacity = 0.72
        overlay.layer?.shadowRadius = 30
        overlay.layer?.shadowOffset = NSSize(width: 0, height: -12)
        guard let hostView = superview else { return }
        hostView.addSubview(overlay, positioned: .above, relativeTo: nil)
        transitionOverlay = overlay

        let startFrame = card.frame
        let anticipationFrame: NSRect
        switch axis {
        case .horizontal:
            anticipationFrame = startFrame.offsetBy(dx: CGFloat(direction) * 18, dy: 4)
        case .vertical:
            anticipationFrame = startFrame.offsetBy(dx: CGFloat(direction) * -12, dy: CGFloat(direction) * -22)
        }
        overlay.frame = anticipationFrame
        overlay.alphaValue = 0.86
        overlay.layer?.transform = CATransform3DMakeScale(0.94, 0.94, 1)

        let duration = axis == .horizontal ? 0.36 : 0.42
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 0.82, 0.18, 1)
            overlay.animator().frame = centerFrame
            overlay.animator().alphaValue = 1
            overlay.layer?.transform = CATransform3DIdentity
            self.centerPlate.animator().alphaValue = 0.78
        }, completionHandler: { [weak self, weak overlay] in
            guard let self, let overlay else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                overlay.animator().alphaValue = 0
                self.centerPlate.animator().alphaValue = 1
            }, completionHandler: {
                overlay.removeFromSuperview()
                if self.transitionOverlay === overlay {
                    self.transitionOverlay = nil
                }
            })
        })
    }

    func setPresented(_ presented: Bool, centerFrame: NSRect, animated: Bool) {
        presentationGeneration += 1
        let generation = presentationGeneration
        isPresented = presented
        layer?.removeAllAnimations()
        if presented {
            isHidden = false
            alphaValue = 1
            centerPlate.frame = centerFrame.insetBy(dx: 12, dy: 12)
            centerPlate.alphaValue = 0
            ambientGlow.alphaValue = 0
            leftCard.alphaValue = 0
            rightCard.alphaValue = 0
            guard animated else {
                centerPlate.alphaValue = 1
                ambientGlow.alphaValue = 1
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.42
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 0.82, 0.18, 1)
                self.centerPlate.animator().frame = centerFrame.insetBy(dx: -2, dy: -2)
                self.centerPlate.animator().alphaValue = 1
                self.ambientGlow.animator().alphaValue = 1
            }
        } else if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.20
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.animator().alphaValue = 0
            }, completionHandler: {
                guard self.presentationGeneration == generation, !self.isPresented else { return }
                self.alphaValue = 1
                self.isHidden = true
            })
        } else {
            isHidden = true
        }
    }
}

private final class CurtainMediaCardView: NSView {
    enum Side { case left, right }

    private let imageView = NSImageView()
    private let shadeView = NSView()
    private let videoBadge = NSVisualEffectView()
    private let videoIcon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private var representedPath = ""
    private var thumbnailOperation: Operation?
    private static let thumbnailQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "FlowVision.Curtain.Thumbnails"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private(set) var hasMedia = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = false
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.48
        layer?.shadowRadius = 24
        layer?.shadowOffset = NSSize(width: 0, height: -8)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 18
        imageView.layer?.masksToBounds = true
        addSubview(imageView)

        shadeView.wantsLayer = true
        let shade = CAGradientLayer()
        shade.colors = [
            NSColor.white.withAlphaComponent(0.08).cgColor,
            NSColor.clear.cgColor,
            NSColor.black.withAlphaComponent(0.50).cgColor,
        ]
        shade.locations = [0, 0.52, 1]
        shade.startPoint = CGPoint(x: 0.5, y: 1)
        shade.endPoint = CGPoint(x: 0.5, y: 0)
        shadeView.layer = shade
        shadeView.layer?.cornerRadius = 18
        shadeView.layer?.masksToBounds = true
        addSubview(shadeView)

        videoBadge.blendingMode = .withinWindow
        videoBadge.material = .hudWindow
        videoBadge.state = .active
        videoBadge.wantsLayer = true
        videoBadge.layer?.cornerRadius = 14
        addSubview(videoBadge)

        videoIcon.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Video")
        videoIcon.contentTintColor = .white
        videoIcon.imageScaling = .scaleProportionallyDown
        videoBadge.addSubview(videoIcon)

        nameLabel.textColor = .white
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.alignment = .center
        nameLabel.wantsLayer = true
        nameLabel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.42).cgColor
        addSubview(nameLabel)
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        shadeView.frame = bounds
        shadeView.layer?.frame = shadeView.bounds
        videoBadge.frame = NSRect(x: bounds.midX - 14, y: bounds.midY - 14, width: 28, height: 28)
        videoIcon.frame = videoBadge.bounds.insetBy(dx: 7, dy: 7)
        nameLabel.frame = NSRect(x: 12, y: 10, width: max(0, bounds.width - 24), height: 22)
    }

    func update(file: FileModel?, side: Side) {
        thumbnailOperation?.cancel()
        representedPath = file?.path ?? ""
        hasMedia = file != nil
        isHidden = file == nil
        guard let file else {
            imageView.image = nil
            return
        }
        imageView.image = file.image
        videoBadge.isHidden = file.type != .video
        nameLabel.stringValue = URL(string: file.path)?.lastPathComponent.removingPercentEncoding ?? ""
        applyRestingDepth(side: side)

        guard imageView.image == nil, let url = URL(string: file.path) else { return }
        let expectedPath = representedPath
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let self, operation?.isCancelled == false else { return }
            let lease = NetworkIOCoordinator.shared.beginBackgroundAccess(
                for: url,
                shouldContinue: { operation?.isCancelled == false }
            )
            guard lease != nil else { return }
            defer { lease?.end() }
            guard operation?.isCancelled == false else { return }
            let image = getImageThumb(url: url, refSize: file.originalSize)
            DispatchQueue.main.async {
                guard operation?.isCancelled == false, self.representedPath == expectedPath else { return }
                self.imageView.image = image
            }
        }
        thumbnailOperation = operation
        Self.thumbnailQueue.addOperation(operation)
    }

    func applyRestingDepth(side: Side, animated: Bool = false) {
        var transform = CATransform3DIdentity
        transform.m34 = -1 / 760
        transform = CATransform3DScale(transform, 0.965, 0.965, 1)
        transform = CATransform3DRotate(transform, side == .left ? 0.105 : -0.105, 0, 1, 0)
        let changes = {
            self.layer?.transform = transform
            self.layer?.shadowOpacity = 0.48
            self.layer?.shadowRadius = 24
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.38
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.76, 0.20, 1)
                changes()
            }
        } else {
            changes()
        }
    }

    func snapshotImage() -> NSImage? {
        guard bounds.width > 0, bounds.height > 0,
              let representation = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: representation)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(representation)
        return image
    }
}

final class CurtainProgressView: NSView {
    weak var largeImageView: LargeImageView?
    private var timer: Timer?
    private var isDragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    func setActive(_ active: Bool) {
        timer?.invalidate()
        timer = nil
        guard active else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    deinit {
        timer?.invalidate()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let player = largeImageView else { return }
        let duration = player.videoDurationSeconds
        let fraction = duration.isFinite && duration > 0 ? max(0, min(1, player.videoCurrentTimeSeconds / duration)) : 0
        let track = bounds.insetBy(dx: 1, dy: max(0, (bounds.height - 5) / 2))
        NSColor.white.withAlphaComponent(0.24).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()
        let fill = NSRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: 2.5, yRadius: 2.5).fill()
        let knob = NSRect(x: track.minX + track.width * fraction - 5, y: track.midY - 5, width: 10, height: 10)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        seek(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        seek(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        seek(with: event)
        isDragging = false
    }

    private func seek(with event: NSEvent) {
        guard let player = largeImageView else { return }
        let duration = player.videoDurationSeconds
        guard duration.isFinite, duration > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let fraction = max(0, min(1, point.x / max(1, bounds.width)))
        player.seekVideo(to: duration * Double(fraction))
        needsDisplay = true
    }
}
