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
    private let leftCard = CurtainMediaCardView()
    private let rightCard = CurtainMediaCardView()
    private var transitionOverlays = [NSImageView]()
    private var isPresented = false
    private var presentationGeneration = 0
    private var transitionGeneration = 0

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
        addSubview(leftCard)
        addSubview(rightCard)
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
            self.leftCard.frame = leftFrame
            self.rightCard.frame = rightFrame
            self.leftCard.alphaValue = self.leftCard.hasMedia ? 0.82 : 0
            self.rightCard.alphaValue = self.rightCard.hasMedia ? 0.82 : 0
            self.leftCard.applyRestingDepth(side: .left)
            self.rightCard.applyRestingDepth(side: .right)
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 0.82, 0.18, 1)
                self.leftCard.animator().frame = leftFrame
                self.rightCard.animator().frame = rightFrame
                self.leftCard.animator().alphaValue = self.leftCard.hasMedia ? 0.82 : 0
                self.rightCard.animator().alphaValue = self.rightCard.hasMedia ? 0.82 : 0
            }
            leftCard.applyRestingDepth(side: .left, animated: true)
            rightCard.applyRestingDepth(side: .right, animated: true)
        } else {
            applyFrames()
        }
    }

    func animateSwitch(direction: Int, axis: CurtainTransitionAxis, centerFrame: NSRect, currentSnapshot: NSImage?) {
        transitionGeneration += 1
        let generation = transitionGeneration
        let card = direction < 0 ? leftCard : rightCard
        guard card.hasMedia else { return }
        transitionOverlays.forEach { $0.removeFromSuperview() }
        transitionOverlays.removeAll()
        guard let incomingSnapshot = card.snapshotImage(), let hostView = superview else { return }

        let incoming = makeTransitionView(image: incomingSnapshot, frame: card.frame)
        hostView.addSubview(incoming, positioned: .above, relativeTo: nil)
        transitionOverlays.append(incoming)

        var outgoing: NSImageView?
        if let currentSnapshot {
            let view = makeTransitionView(image: currentSnapshot, frame: centerFrame)
            hostView.addSubview(view, positioned: .below, relativeTo: incoming)
            transitionOverlays.append(view)
            outgoing = view
        }

        let outgoingTarget: NSRect
        switch axis {
        case .horizontal:
            outgoingTarget = direction > 0 ? leftCard.frame : rightCard.frame
        case .vertical:
            outgoingTarget = centerFrame.offsetBy(dx: 0, dy: CGFloat(direction) * centerFrame.height * -0.78)
        }
        incoming.alphaValue = 1
        incoming.layer?.transform = coverFlowTransform(relativeOffset: CGFloat(direction), travelDirection: direction)
        outgoing?.layer?.transform = coverFlowTransform(relativeOffset: 0, travelDirection: direction)

        let duration = axis == .horizontal ? 0.27 : 0.34
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.12, 0.78, 0.16, 1)
            incoming.animator().frame = centerFrame
            incoming.layer?.transform = self.coverFlowTransform(relativeOffset: 0, travelDirection: direction)
            outgoing?.animator().frame = outgoingTarget
            outgoing?.animator().alphaValue = axis == .horizontal ? 0.82 : 0
            outgoing?.layer?.transform = self.coverFlowTransform(relativeOffset: CGFloat(-direction), travelDirection: direction)
        }, completionHandler: { [weak self] in
            guard let self, self.transitionGeneration == generation else { return }
            self.transitionOverlays.forEach { $0.removeFromSuperview() }
            self.transitionOverlays.removeAll()
        })
    }

    private func coverFlowTransform(relativeOffset: CGFloat, travelDirection: Int) -> CATransform3D {
        let clamped = max(-1, min(1, relativeOffset))
        var transform = CATransform3DIdentity
        transform.m34 = -1 / 700
        transform = CATransform3DTranslate(transform, 0, 0, -abs(clamped) * 105)
        transform = CATransform3DRotate(transform, -clamped * 0.82, 0, 1, 0)
        let scale = 1 - abs(clamped) * 0.18
        transform = CATransform3DScale(transform, scale, scale, 1)
        // Incoming and outgoing cards overlap at the midpoint; bias the incoming card forward.
        transform.m43 += relativeOffset.sign == CGFloat(travelDirection).sign ? 1 : 0
        return transform
    }

    private func makeTransitionView(image: NSImage, frame: NSRect) -> NSImageView {
        let view = NSImageView(frame: frame)
        view.image = image
        view.imageScaling = .scaleAxesIndependently
        view.wantsLayer = true
        view.layer?.cornerRadius = 16
        view.layer?.masksToBounds = true
        view.layer?.shadowColor = NSColor.black.cgColor
        view.layer?.shadowOpacity = 0.42
        view.layer?.shadowRadius = 18
        view.layer?.shadowOffset = NSSize(width: 0, height: -7)
        return view
    }

    func setPresented(_ presented: Bool, centerFrame: NSRect, animated: Bool) {
        presentationGeneration += 1
        let generation = presentationGeneration
        isPresented = presented
        layer?.removeAllAnimations()
        if !presented {
            transitionGeneration += 1
            transitionOverlays.forEach { $0.removeFromSuperview() }
            transitionOverlays.removeAll()
        }
        if presented {
            isHidden = false
            alphaValue = 1
            leftCard.alphaValue = 0
            rightCard.alphaValue = 0
            guard animated else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 0.82, 0.18, 1)
                self.leftCard.animator().alphaValue = self.leftCard.hasMedia ? 0.82 : 0
                self.rightCard.animator().alphaValue = self.rightCard.hasMedia ? 0.82 : 0
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
    private let videoBadge = NSView()
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

        videoBadge.wantsLayer = true
        videoBadge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.66).cgColor
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
        transform = CATransform3DScale(transform, 0.96, 0.96, 1)
        transform = CATransform3DRotate(transform, side == .left ? 0.095 : -0.095, 0, 1, 0)
        let changes = {
            self.layer?.transform = transform
            self.layer?.shadowOpacity = 0.48
            self.layer?.shadowRadius = 24
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
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
