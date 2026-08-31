//
//  VideoPlayerControlsView.swift
//  FlowVision
//

import Foundation
import Cocoa
import AVFoundation
import AVKit

/// Decorative progress layers must not become the AppKit mouse target. The
/// parent controls view owns the enlarged scrub hit area and all drag events.
private final class ProgressDecorationView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class PassiveVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - ClickableSlider

private class ClickableSlider: NSSlider {
    override func mouseDown(with event: NSEvent) {
        guard let cell = cell as? NSSliderCell else {
            super.mouseDown(with: event)
            return
        }
        // Jump to the clicked position immediately
        let point = convert(event.locationInWindow, from: nil)
        let barRect = cell.barRect(flipped: isFlipped)
        // Account for the knob inset used in CustomVolumeSliderCell.drawBar
        let knobSize: CGFloat = 10
        let halfKnob = knobSize / 2
        let visibleBarX = barRect.origin.x + halfKnob
        let visibleBarWidth = barRect.width - knobSize
        var fraction = (point.x - visibleBarX) / visibleBarWidth
        if userInterfaceLayoutDirection == .rightToLeft { fraction = 1 - fraction }
        let clampedFraction = max(0.0, min(1.0, Double(fraction)))
        doubleValue = minValue + clampedFraction * (maxValue - minValue)
        sendAction(action, to: target)
        // Continue with drag tracking
        super.mouseDown(with: event)
    }
}

// MARK: - CustomVolumeSliderCell

private class CustomVolumeSliderCell: NSSliderCell {
    
    private let barColor = NSColor.white.withAlphaComponent(0.2)
    private let filledColor = NSColor.white.withAlphaComponent(0.6)
    private let knobColor = hexToNSColor(hex: "#DDDDDD", alpha: 1.0)
    private let knobSize: CGFloat = 10
    
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let halfKnob = knobSize / 2
        let barRect = NSRect(
            x: rect.origin.x + halfKnob,
            y: rect.midY - 1.5,
            width: rect.width - knobSize,
            height: 3
        )
        let barPath = NSBezierPath(roundedRect: barRect, xRadius: 1.5, yRadius: 1.5)
        barColor.setFill()
        barPath.fill()
        
        let fraction = CGFloat((doubleValue - minValue) / (maxValue - minValue))
        let filledWidth = barRect.width * fraction
        if filledWidth > 0 {
            let isRTL = controlView?.userInterfaceLayoutDirection == .rightToLeft
            let filledX = isRTL ? barRect.maxX - filledWidth : barRect.origin.x
            let filledRect = NSRect(x: filledX, y: barRect.origin.y, width: filledWidth, height: barRect.height)
            let filledPath = NSBezierPath(roundedRect: filledRect, xRadius: 1.5, yRadius: 1.5)
            filledColor.setFill()
            filledPath.fill()
        }
    }
    
    override func knobRect(flipped: Bool) -> NSRect {
        let bar = barRect(flipped: flipped)
        let halfKnob = knobSize / 2
        let trackX = bar.origin.x + halfKnob
        let trackWidth = bar.width - knobSize
        var fraction = CGFloat((doubleValue - minValue) / (maxValue - minValue))
        if controlView?.userInterfaceLayoutDirection == .rightToLeft { fraction = 1 - fraction }
        let knobCenterX = trackX + trackWidth * fraction
        return NSRect(
            x: knobCenterX - halfKnob,
            y: bar.midY - halfKnob,
            width: knobSize,
            height: knobSize
        )
    }

    override func drawKnob(_ knobRect: NSRect) {
        let path = NSBezierPath(ovalIn: knobRect)
        knobColor.setFill()
        path.fill()
    }
}

// MARK: - VideoPlayerControlsView

class VideoPlayerControlsView: NSView {
    
    weak var largeImageView: LargeImageView?
    
    private var skipBackwardButton: NSButton!
    private var playPauseButton: NSButton!
    private var skipForwardButton: NSButton!
    private var currentTimeLabel: NSTextField!
    private var durationLabel: NSTextField!
    private var losslessTrimButton: NSButton!
    private var progressBarBackground: NSView!
    private var progressBarFilled: NSView!
    private var progressBarBuffered: NSView!
    private var progressBarHandle: NSView!
    private var volumeButton: NSButton!
    private var volumeSlider: NSSlider!
    private var volumeSliderContainer: NSView!
    
    private var abMarkerA: NSView!
    private var abMarkerB: NSView!
    private var abMarkerAConstraint: NSLayoutConstraint!
    private var abMarkerBConstraint: NSLayoutConstraint!
    
    private var progressBarFilledWidthConstraint: NSLayoutConstraint!
    private var progressBarHandleLeadingConstraint: NSLayoutConstraint!
    
    private var hideTimer: Timer?
    private var isDraggingProgress = false
    private var isDraggingControlBar = false
    private var wasPlayingBeforeDrag = false
    private var controlBarDragStartInWindow: NSPoint = .zero
    private var controlBarDragStartCenterX: CGFloat = 0
    private var controlBarDragStartBottom: CGFloat = 0
    private var isMouseInsideControls = false
    private var trackingArea: NSTrackingArea?
    private var progressTrackingArea: NSTrackingArea?
    
    private var hoverTimeContainer: NSView!
    private var hoverTimeLabel: NSTextField!
    private var hoverTimeLabelLeadingConstraint: NSLayoutConstraint!
    
    private var loopModeButton: NSButton!
    private var fullscreenButton: NSButton!
    private var volumeBeforeMute: Float = 1.0
    
    private let progressBarHeight: CGFloat = 3
    private let handleWidth: CGFloat = 3
    private let handleHeight: CGFloat = 15
    
    private var handleWidthConstraint: NSLayoutConstraint!
    private var handleHeightConstraint: NSLayoutConstraint!
    
    private var effectView: NSVisualEffectView!
    private weak var floatingHostView: NSView?
    private weak var floatingCenterXConstraint: NSLayoutConstraint?
    private weak var floatingBottomConstraint: NSLayoutConstraint?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }
    
    private func setupUI() {
        wantsLayer = true
        
        effectView = PassiveVisualEffectView()
        effectView.appearance = NSAppearance(named: .vibrantDark)
        effectView.material = .hudWindow
        effectView.blendingMode = .withinWindow
        effectView.state = .active
        effectView.wantsLayer = true
        if #available(macOS 26.0, *) {
            effectView.layer?.cornerRadius = 10
        } else {
            effectView.layer?.cornerRadius = 6
        }
        effectView.layer?.masksToBounds = true
        effectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effectView)
        
        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        
        alphaValue = 0
        isHidden = true
        
        setupControls()
        setupHoverTimeLabel()
        setupTrackingAreas()
    }
    
    // MARK: - Controls (single-row compact layout)
    
    private func setupControls() {
        skipBackwardButton = NSButton(frame: .zero)
        skipBackwardButton.isBordered = false
        skipBackwardButton.bezelStyle = .regularSquare
        skipBackwardButton.image = NSImage(systemSymbolName: "gobackward.15", accessibilityDescription: nil)
        skipBackwardButton.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        skipBackwardButton.imageScaling = .scaleProportionallyUpOrDown
        skipBackwardButton.target = self
        skipBackwardButton.action = #selector(skipBackwardTapped)
        skipBackwardButton.translatesAutoresizingMaskIntoConstraints = false
        (skipBackwardButton.cell as? NSButtonCell)?.highlightsBy = []
        addSubview(skipBackwardButton)
        
        playPauseButton = NSButton(frame: .zero)
        playPauseButton.isBordered = false
        playPauseButton.bezelStyle = .regularSquare
        playPauseButton.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)
        playPauseButton.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        playPauseButton.imageScaling = .scaleProportionallyUpOrDown
        playPauseButton.target = self
        playPauseButton.action = #selector(playPauseTapped)
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        (playPauseButton.cell as? NSButtonCell)?.highlightsBy = []
        addSubview(playPauseButton)
        
        skipForwardButton = NSButton(frame: .zero)
        skipForwardButton.isBordered = false
        skipForwardButton.bezelStyle = .regularSquare
        skipForwardButton.image = NSImage(systemSymbolName: "goforward.15", accessibilityDescription: nil)
        skipForwardButton.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        skipForwardButton.imageScaling = .scaleProportionallyUpOrDown
        skipForwardButton.target = self
        skipForwardButton.action = #selector(skipForwardTapped)
        skipForwardButton.translatesAutoresizingMaskIntoConstraints = false
        (skipForwardButton.cell as? NSButtonCell)?.highlightsBy = []
        addSubview(skipForwardButton)
        
        currentTimeLabel = createTimeLabel("00:00")
        addSubview(currentTimeLabel)
        
        progressBarBackground = ProgressDecorationView()
        progressBarBackground.wantsLayer = true
        progressBarBackground.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        progressBarBackground.layer?.cornerRadius = 1.5
        progressBarBackground.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progressBarBackground)
        
        progressBarBuffered = ProgressDecorationView()
        progressBarBuffered.wantsLayer = true
        progressBarBuffered.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        progressBarBuffered.layer?.cornerRadius = 1.5
        progressBarBuffered.translatesAutoresizingMaskIntoConstraints = false
        progressBarBackground.addSubview(progressBarBuffered)
        
        progressBarFilled = ProgressDecorationView()
        progressBarFilled.wantsLayer = true
        progressBarFilled.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.6).cgColor
        progressBarFilled.layer?.cornerRadius = 1.5
        progressBarFilled.translatesAutoresizingMaskIntoConstraints = false
        progressBarBackground.addSubview(progressBarFilled)
        
        progressBarHandle = ProgressDecorationView()
        progressBarHandle.wantsLayer = true
        progressBarHandle.layer?.backgroundColor = hexToNSColor(hex: "#DDDDDD", alpha: 1.0).cgColor
        progressBarHandle.layer?.cornerRadius = 1.5
        progressBarHandle.shadow = NSShadow()
        progressBarHandle.layer?.shadowColor = hexToNSColor(hex: "#555555", alpha: 1.0).cgColor
        progressBarHandle.layer?.shadowOpacity = 1.0
        progressBarHandle.layer?.shadowOffset = .zero
        progressBarHandle.layer?.shadowRadius = 2
        progressBarHandle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progressBarHandle)
        
        abMarkerA = createABMarker()
        addSubview(abMarkerA)
        abMarkerB = createABMarker()
        addSubview(abMarkerB)
        
        durationLabel = createTimeLabel("00:00")
        addSubview(durationLabel)

        losslessTrimButton = NSButton(frame: .zero)
        losslessTrimButton.isBordered = false
        losslessTrimButton.bezelStyle = .regularSquare
        losslessTrimButton.image = NSImage(
            systemSymbolName: "scissors",
            accessibilityDescription: NSLocalizedString("Lossless Trim Segments...", comment: "无损分段裁剪...")
        )
        losslessTrimButton.contentTintColor = NSColor.white.withAlphaComponent(0.7)
        losslessTrimButton.imageScaling = .scaleProportionallyUpOrDown
        losslessTrimButton.target = self
        losslessTrimButton.action = #selector(losslessTrimTapped)
        losslessTrimButton.toolTip = NSLocalizedString("Lossless Trim Segments...", comment: "无损分段裁剪...")
        losslessTrimButton.setAccessibilityLabel(
            NSLocalizedString("Lossless Trim Segments...", comment: "无损分段裁剪...")
        )
        losslessTrimButton.translatesAutoresizingMaskIntoConstraints = false
        (losslessTrimButton.cell as? NSButtonCell)?.highlightsBy = []
        addSubview(losslessTrimButton)
        
        volumeButton = NSButton(frame: .zero)
        volumeButton.isBordered = false
        volumeButton.bezelStyle = .regularSquare
        volumeButton.image = NSImage(systemSymbolName: "speaker.2.fill", accessibilityDescription: nil)
        volumeButton.contentTintColor = NSColor.white.withAlphaComponent(0.6)
        volumeButton.imageScaling = .scaleProportionallyUpOrDown
        volumeButton.target = self
        volumeButton.action = #selector(volumeButtonTapped)
        volumeButton.translatesAutoresizingMaskIntoConstraints = false
        (volumeButton.cell as? NSButtonCell)?.highlightsBy = []
        addSubview(volumeButton)
        
        volumeSliderContainer = NSView()
        volumeSliderContainer.wantsLayer = true
        volumeSliderContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(volumeSliderContainer)
        
        volumeSlider = ClickableSlider(value: Double(globalVar.videoVolume), minValue: 0, maxValue: 1, target: self, action: #selector(volumeSliderChanged(_:)))
        volumeSlider.cell = CustomVolumeSliderCell()
        volumeSlider.minValue = 0
        volumeSlider.maxValue = 1
        volumeSlider.doubleValue = Double(globalVar.videoVolume)
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeSliderChanged(_:))
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        volumeSlider.controlSize = .small
        volumeSliderContainer.addSubview(volumeSlider)
        
        let loopSymbol = globalVar.videoPlaySequentialPlay ? "repeat" : "repeat.1"
        loopModeButton = NSButton(frame: .zero)
        loopModeButton.isBordered = false
        loopModeButton.bezelStyle = .regularSquare
        loopModeButton.image = NSImage(systemSymbolName: loopSymbol, accessibilityDescription: nil)
        loopModeButton.contentTintColor = NSColor.white.withAlphaComponent(0.6)
        loopModeButton.imageScaling = .scaleProportionallyUpOrDown
        loopModeButton.target = self
        loopModeButton.action = #selector(loopModeTapped)
        loopModeButton.translatesAutoresizingMaskIntoConstraints = false
        (loopModeButton.cell as? NSButtonCell)?.highlightsBy = []
        //addSubview(loopModeButton)
        
        fullscreenButton = NSButton(frame: .zero)
        fullscreenButton.isBordered = false
        fullscreenButton.bezelStyle = .regularSquare
        fullscreenButton.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil)
        fullscreenButton.contentTintColor = NSColor.white.withAlphaComponent(0.6)
        fullscreenButton.imageScaling = .scaleProportionallyUpOrDown
        fullscreenButton.target = self
        fullscreenButton.action = #selector(fullscreenTapped)
        fullscreenButton.translatesAutoresizingMaskIntoConstraints = false
        (fullscreenButton.cell as? NSButtonCell)?.highlightsBy = []
        addSubview(fullscreenButton)
        
        progressBarFilledWidthConstraint = progressBarFilled.widthAnchor.constraint(equalToConstant: 0)
        progressBarHandleLeadingConstraint = progressBarHandle.centerXAnchor.constraint(equalTo: progressBarBackground.leadingAnchor, constant: 0)
        handleWidthConstraint = progressBarHandle.widthAnchor.constraint(equalToConstant: handleWidth)
        handleHeightConstraint = progressBarHandle.heightAnchor.constraint(equalToConstant: handleHeight)
        abMarkerAConstraint = abMarkerA.centerXAnchor.constraint(equalTo: progressBarBackground.leadingAnchor, constant: 0)
        abMarkerBConstraint = abMarkerB.centerXAnchor.constraint(equalTo: progressBarBackground.leadingAnchor, constant: 0)
        
        NSLayoutConstraint.activate([
            playPauseButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            playPauseButton.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            playPauseButton.widthAnchor.constraint(equalToConstant: 18),
            playPauseButton.heightAnchor.constraint(equalToConstant: 18),

            skipBackwardButton.trailingAnchor.constraint(equalTo: playPauseButton.leadingAnchor, constant: -18),
            skipBackwardButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            skipBackwardButton.widthAnchor.constraint(equalToConstant: 16),
            skipBackwardButton.heightAnchor.constraint(equalToConstant: 16),

            skipForwardButton.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 18),
            skipForwardButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            skipForwardButton.widthAnchor.constraint(equalToConstant: 16),
            skipForwardButton.heightAnchor.constraint(equalToConstant: 16),

            volumeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            volumeButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            volumeButton.widthAnchor.constraint(equalToConstant: 18),
            volumeButton.heightAnchor.constraint(equalToConstant: 18),

            volumeSliderContainer.leadingAnchor.constraint(equalTo: volumeButton.trailingAnchor, constant: 8),
            volumeSliderContainer.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            volumeSliderContainer.widthAnchor.constraint(equalToConstant: 60),
            volumeSliderContainer.heightAnchor.constraint(equalToConstant: 20),

            volumeSlider.leadingAnchor.constraint(equalTo: volumeSliderContainer.leadingAnchor),
            volumeSlider.trailingAnchor.constraint(equalTo: volumeSliderContainer.trailingAnchor),
            volumeSlider.centerYAnchor.constraint(equalTo: volumeSliderContainer.centerYAnchor),

            fullscreenButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            fullscreenButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            fullscreenButton.widthAnchor.constraint(equalToConstant: 18),
            fullscreenButton.heightAnchor.constraint(equalToConstant: 18),

            losslessTrimButton.trailingAnchor.constraint(equalTo: fullscreenButton.leadingAnchor, constant: -14),
            losslessTrimButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            losslessTrimButton.widthAnchor.constraint(equalToConstant: 18),
            losslessTrimButton.heightAnchor.constraint(equalToConstant: 18),

            currentTimeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            currentTimeLabel.centerYAnchor.constraint(equalTo: progressBarBackground.centerYAnchor),

            progressBarBackground.leadingAnchor.constraint(equalTo: currentTimeLabel.trailingAnchor, constant: 10),
            progressBarBackground.trailingAnchor.constraint(equalTo: durationLabel.leadingAnchor, constant: -10),
            progressBarBackground.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -13),
            progressBarBackground.heightAnchor.constraint(equalToConstant: progressBarHeight),

            progressBarBuffered.leadingAnchor.constraint(equalTo: progressBarBackground.leadingAnchor),
            progressBarBuffered.topAnchor.constraint(equalTo: progressBarBackground.topAnchor),
            progressBarBuffered.bottomAnchor.constraint(equalTo: progressBarBackground.bottomAnchor),
            progressBarBuffered.widthAnchor.constraint(equalToConstant: 0),

            progressBarFilled.leadingAnchor.constraint(equalTo: progressBarBackground.leadingAnchor),
            progressBarFilled.topAnchor.constraint(equalTo: progressBarBackground.topAnchor),
            progressBarFilled.bottomAnchor.constraint(equalTo: progressBarBackground.bottomAnchor),
            progressBarFilledWidthConstraint,

            progressBarHandleLeadingConstraint,
            progressBarHandle.centerYAnchor.constraint(equalTo: progressBarBackground.centerYAnchor),
            handleWidthConstraint,
            handleHeightConstraint,

            abMarkerAConstraint,
            abMarkerA.centerYAnchor.constraint(equalTo: progressBarBackground.centerYAnchor),
            abMarkerA.widthAnchor.constraint(equalToConstant: 2),
            abMarkerA.heightAnchor.constraint(equalToConstant: 10),

            abMarkerBConstraint,
            abMarkerB.centerYAnchor.constraint(equalTo: progressBarBackground.centerYAnchor),
            abMarkerB.widthAnchor.constraint(equalToConstant: 2),
            abMarkerB.heightAnchor.constraint(equalToConstant: 10),

            durationLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            durationLabel.centerYAnchor.constraint(equalTo: progressBarBackground.centerYAnchor),
        ])
    }

    func configureFloatingPosition(
        in hostView: NSView,
        centerXConstraint: NSLayoutConstraint,
        bottomConstraint: NSLayoutConstraint
    ) {
        floatingHostView = hostView
        floatingCenterXConstraint = centerXConstraint
        floatingBottomConstraint = bottomConstraint
        constrainFloatingPosition()
    }

    func constrainFloatingPosition() {
        guard let host = floatingHostView,
              let centerXConstraint = floatingCenterXConstraint,
              let bottomConstraint = floatingBottomConstraint,
              host.bounds.width > 0,
              host.bounds.height > 0 else { return }

        let horizontalLimit = max(0, (host.bounds.width - bounds.width) / 2 - 10)
        centerXConstraint.constant = max(-horizontalLimit, min(horizontalLimit, centerXConstraint.constant))
        let verticalLimit = max(10, host.bounds.height - bounds.height - 25)
        bottomConstraint.constant = max(10, min(verticalLimit, bottomConstraint.constant))
    }
    
    private func setupHoverTimeLabel() {
        hoverTimeContainer = NSView()
        hoverTimeContainer.wantsLayer = true
        hoverTimeContainer.layer?.backgroundColor = hexToNSColor(hex: "#111111", alpha: 0.6).cgColor
        hoverTimeContainer.layer?.cornerRadius = 4
        hoverTimeContainer.translatesAutoresizingMaskIntoConstraints = false
        hoverTimeContainer.isHidden = true
        addSubview(hoverTimeContainer)
        
        hoverTimeLabel = NSTextField(labelWithString: "")
        hoverTimeLabel.textColor = hexToNSColor(hex: "#DDDDDD", alpha: 0.8)
        hoverTimeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        hoverTimeLabel.alignment = .center
        hoverTimeLabel.isBezeled = false
        hoverTimeLabel.drawsBackground = false
        hoverTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        hoverTimeContainer.addSubview(hoverTimeLabel)
        
        hoverTimeLabelLeadingConstraint = hoverTimeContainer.centerXAnchor.constraint(equalTo: progressBarBackground.leadingAnchor, constant: 0)
        
        NSLayoutConstraint.activate([
            hoverTimeLabelLeadingConstraint,
            hoverTimeContainer.bottomAnchor.constraint(equalTo: topAnchor, constant: -4),
            
            hoverTimeLabel.topAnchor.constraint(equalTo: hoverTimeContainer.topAnchor, constant: 4),
            hoverTimeLabel.bottomAnchor.constraint(equalTo: hoverTimeContainer.bottomAnchor, constant: -4),
            hoverTimeLabel.leadingAnchor.constraint(equalTo: hoverTimeContainer.leadingAnchor, constant: 8),
            hoverTimeLabel.trailingAnchor.constraint(equalTo: hoverTimeContainer.trailingAnchor, constant: -8),
        ])
    }
    
    private func createABMarker() -> NSView {
        let marker = NSView()
        marker.wantsLayer = true
        marker.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.9).cgColor
        marker.layer?.cornerRadius = 1
        marker.translatesAutoresizingMaskIntoConstraints = false
        marker.isHidden = true
        return marker
    }
    
    func updateABMarkers() {
        guard let largeImageView = largeImageView else {
            abMarkerA.isHidden = true
            abMarkerB.isHidden = true
            return
        }
        let total = largeImageView.videoDurationSeconds
        guard total.isFinite && total > 0 else { return }
        let progressWidth = progressBarBackground.bounds.width
        
        if let posA = largeImageView.abPlayPositionA {
            let fracA = CGFloat(CMTimeGetSeconds(posA) / total)
            abMarkerAConstraint.constant = progressWidth * max(0, min(1, fracA))
            abMarkerA.isHidden = false
        } else {
            abMarkerA.isHidden = true
        }
        
        if let posB = largeImageView.abPlayPositionB {
            let fracB = CGFloat(CMTimeGetSeconds(posB) / total)
            abMarkerBConstraint.constant = progressWidth * max(0, min(1, fracB))
            abMarkerB.isHidden = false
        } else {
            abMarkerB.isHidden = true
        }
    }
    
    private func createTimeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = NSColor.white.withAlphaComponent(0.7)
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
    
    // MARK: - Tracking Areas
    
    private func setupTrackingAreas() {}
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp],
            owner: self,
            userInfo: ["area": "controls"]
        )
        addTrackingArea(trackingArea!)
        
        if let existing = progressTrackingArea {
            removeTrackingArea(existing)
        }
        let progressRect = NSRect(
            x: progressBarBackground.frame.origin.x,
            y: progressBarBackground.frame.origin.y - 8,
            width: progressBarBackground.frame.width,
            height: progressBarBackground.frame.height + 16
        )
        progressTrackingArea = NSTrackingArea(
            rect: progressRect,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp],
            owner: self,
            userInfo: ["area": "progress"]
        )
        addTrackingArea(progressTrackingArea!)
    }
    
    // MARK: - Mouse Events
    
    override func mouseEntered(with event: NSEvent) {
        isMouseInsideControls = true
        cancelHideTimer()
        
        if let userInfo = event.trackingArea?.userInfo as? [String: String],
           userInfo["area"] == "progress" {
        }
    }
    
    override func mouseExited(with event: NSEvent) {
        if let userInfo = event.trackingArea?.userInfo as? [String: String],
           userInfo["area"] == "progress" {
            if !isDraggingProgress {
                hoverTimeContainer.isHidden = true
            }
        }
        
        if let userInfo = event.trackingArea?.userInfo as? [String: String],
           userInfo["area"] == "controls" {
            isMouseInsideControls = false
            if !isDraggingProgress {
                scheduleHide()
            }
        }
    }
    
    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let progressFrame = progressBarBackground.frame
        let expandedProgressFrame = NSRect(
            x: progressFrame.origin.x,
            y: progressFrame.origin.y - 8,
            width: progressFrame.width,
            height: progressFrame.height + 16
        )
        
        if expandedProgressFrame.contains(location) {
            updateHoverTime(at: location)
        } else {
            hoverTimeContainer.isHidden = true
        }
    }
    
    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let progressFrame = progressBarBackground.frame
        let expandedProgressFrame = NSRect(
            x: progressFrame.origin.x,
            y: progressFrame.origin.y - 10,
            width: progressFrame.width,
            height: progressFrame.height + 20
        )
        
        if expandedProgressFrame.contains(location) {
            isDraggingProgress = true
            wasPlayingBeforeDrag = largeImageView?.videoIsPlaying == true
            largeImageView?.setVideoPaused(true)
            seekToPosition(at: location)
            return
        }

        guard let centerXConstraint = floatingCenterXConstraint,
              let bottomConstraint = floatingBottomConstraint else { return }
        isDraggingControlBar = true
        controlBarDragStartInWindow = event.locationInWindow
        controlBarDragStartCenterX = centerXConstraint.constant
        controlBarDragStartBottom = bottomConstraint.constant
        cancelHideTimer()
        NSCursor.closedHand.push()
    }
    
    override func mouseDragged(with event: NSEvent) {
        if isDraggingProgress {
            let location = convert(event.locationInWindow, from: nil)
            seekToPosition(at: location)
            updateHoverTime(at: location)
        } else if isDraggingControlBar,
                  let centerXConstraint = floatingCenterXConstraint,
                  let bottomConstraint = floatingBottomConstraint {
            centerXConstraint.constant = controlBarDragStartCenterX + event.locationInWindow.x - controlBarDragStartInWindow.x
            bottomConstraint.constant = controlBarDragStartBottom + event.locationInWindow.y - controlBarDragStartInWindow.y
            constrainFloatingPosition()
        }
    }
    
    override func mouseUp(with event: NSEvent) {
        if isDraggingProgress {
            isDraggingProgress = false
            if wasPlayingBeforeDrag {
                largeImageView?.setVideoPaused(false)
            }
            updatePlayPauseIcon()
            
            let location = convert(event.locationInWindow, from: nil)
            let progressFrame = progressBarBackground.frame
            let expandedProgressFrame = NSRect(
                x: progressFrame.origin.x,
                y: progressFrame.origin.y - 8,
                width: progressFrame.width,
                height: progressFrame.height + 16
            )
            if !expandedProgressFrame.contains(location) {
                hoverTimeContainer.isHidden = true
            }
            
            if !isMouseInsideControls {
                scheduleHide()
            }
        } else if isDraggingControlBar {
            isDraggingControlBar = false
            NSCursor.pop()
            saveFloatingPosition()
            if !isMouseInsideControls {
                scheduleHide()
            }
        }
    }

    private func saveFloatingPosition() {
        guard let host = floatingHostView,
              let centerXConstraint = floatingCenterXConstraint,
              let bottomConstraint = floatingBottomConstraint,
              host.bounds.width > 0,
              host.bounds.height > 0 else { return }
        let horizontal = (centerXConstraint.constant + host.bounds.width / 2) / host.bounds.width
        let vertical = bottomConstraint.constant / host.bounds.height
        UserDefaults.standard.set(horizontal, forKey: "videoControlBarHorizontalPosition")
        UserDefaults.standard.set(vertical, forKey: "videoControlBarVerticalPosition")
        UserDefaults.standard.set(2, forKey: "videoControlBarPositionCoordinateVersion")
    }
    
    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        
        if !isHidden && alphaValue > 0 && bounds.contains(localPoint) {
            return super.hitTest(point)
        }
        return nil
    }
    
    // MARK: - Progress Bar Interaction
    
    private func seekToPosition(at location: NSPoint) {
        guard let largeImageView = largeImageView else { return }
        
        let progressFrame = progressBarBackground.frame
        let relativeX = max(0, min(location.x - progressFrame.origin.x, progressFrame.width))
        let fraction = relativeX / progressFrame.width
        
        let totalDuration = largeImageView.videoDurationSeconds
        guard totalDuration.isFinite && totalDuration > 0 else { return }
        var targetSeconds = totalDuration * Double(fraction)
        
        if let posA = largeImageView.abPlayPositionA, let posB = largeImageView.abPlayPositionB,
           CMTimeGetSeconds(posA) < CMTimeGetSeconds(posB) {
            targetSeconds = max(CMTimeGetSeconds(posA), min(CMTimeGetSeconds(posB), targetSeconds))
        }
        
        let clampedFraction = CGFloat(targetSeconds / totalDuration)
        largeImageView.seekVideo(to: targetSeconds)
        
        updateProgress(fraction: clampedFraction)
    }
    
    private func updateHoverTime(at location: NSPoint) {
        guard let largeImageView = largeImageView else { return }
        
        let progressFrame = progressBarBackground.frame
        let relativeX = max(0, min(location.x - progressFrame.origin.x, progressFrame.width))
        let fraction = relativeX / progressFrame.width
        
        let totalDuration = largeImageView.videoDurationSeconds
        guard totalDuration.isFinite && totalDuration > 0 else { return }
        let hoverSeconds = totalDuration * Double(fraction)
        hoverTimeLabel.stringValue = formatTime(hoverSeconds)
        hoverTimeContainer.isHidden = false
        
        let clampedX = max(20, min(relativeX, progressFrame.width - 20))
        hoverTimeLabelLeadingConstraint.constant = clampedX
    }
    
    
    // MARK: - Actions
    
    @objc private func skipBackwardTapped() {
        guard let largeImageView = largeImageView else { return }
        let current = largeImageView.videoCurrentTimeSeconds
        var minBound = 0.0
        if let posA = largeImageView.abPlayPositionA, let posB = largeImageView.abPlayPositionB,
           CMTimeGetSeconds(posA) < CMTimeGetSeconds(posB) {
            minBound = CMTimeGetSeconds(posA)
        }
        let target = max(minBound, current - 15)
        largeImageView.seekVideo(to: target)
    }
    
    @objc private func skipForwardTapped() {
        guard let largeImageView = largeImageView else { return }
        let current = largeImageView.videoCurrentTimeSeconds
        var maxBound = largeImageView.videoDurationSeconds
        guard maxBound.isFinite && maxBound > 0 else { return }
        if let posA = largeImageView.abPlayPositionA, let posB = largeImageView.abPlayPositionB,
           CMTimeGetSeconds(posA) < CMTimeGetSeconds(posB) {
            maxBound = CMTimeGetSeconds(posB)
        }
        let target = min(maxBound, current + 15)
        largeImageView.seekVideo(to: target)
    }
    
    @objc private func playPauseTapped() {
        largeImageView?.pauseOrResumeVideo()
        updatePlayPauseIcon()
    }
    
    @objc private func volumeButtonTapped() {
        guard let largeImageView = largeImageView else { return }
        
        if largeImageView.videoVolume > 0 {
            volumeBeforeMute = largeImageView.videoVolume
            largeImageView.videoVolume = 0
        } else {
            largeImageView.videoVolume = volumeBeforeMute > 0 ? volumeBeforeMute : 1.0
        }
        updateVolumeUI()
    }
    
    @objc private func volumeSliderChanged(_ sender: NSSlider) {
        largeImageView?.videoVolume = Float(sender.doubleValue)
        updateVolumeIcon()
    }

    @objc private func losslessTrimTapped() {
        largeImageView?.actLosslessTrimSegments()
    }
    
    @objc private func loopModeTapped() {
        largeImageView?.actSequentialPlay()
    }
    
    @objc private func fullscreenTapped() {
        largeImageView?.window?.toggleFullScreen(nil)
    }
    
    // MARK: - Update UI
    
    func updateProgress(currentTime: CMTime, duration: CMTime) {
        guard !isDraggingProgress else { return }
        
        let current = CMTimeGetSeconds(currentTime)
        let total = CMTimeGetSeconds(duration)
        guard total.isFinite && total > 0 else { return }
        
        let fraction = CGFloat(current / total)
        updateProgress(fraction: fraction)
        
        currentTimeLabel.stringValue = formatTime(current)
        durationLabel.stringValue = formatTime(total)
        updateABMarkers()
    }
    
    private func updateProgress(fraction: CGFloat) {
        let clampedFraction = max(0, min(1, fraction))
        let progressWidth = progressBarBackground.bounds.width
        progressBarFilledWidthConstraint.constant = progressWidth * clampedFraction
        progressBarHandleLeadingConstraint.constant = progressWidth * clampedFraction
    }
    
    func updatePlayPauseIcon() {
        let symbolName = largeImageView?.videoIsPlaying == true ? "pause.fill" : "play.fill"
        playPauseButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    }
    
    func updateVolumeUI() {
        guard let largeImageView = largeImageView else { return }
        volumeSlider.doubleValue = Double(largeImageView.videoVolume)
        updateVolumeIcon()
    }
    
    private func updateVolumeIcon() {
        let symbolName = largeImageView?.videoVolume ?? 0 <= 0 ? "speaker.slash.fill" : "speaker.2.fill"
        volumeButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    }
    
    func updateLoopModeIcon() {
        let symbolName = globalVar.videoPlaySequentialPlay ? "repeat" : "repeat.1"
        loopModeButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    }
    
    // MARK: - Show / Hide
    
    func showControls(autoHide: Bool = true) {
        if isHidden || alphaValue < 1 {
            isHidden = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                self.animator().alphaValue = 1.0
            }
            if !isDraggingProgress {
                updatePlayPauseIcon()
            }
            updateVolumeUI()
        }
        
        if autoHide && !globalVar.videoControlsAlwaysVisible && !isDraggingProgress {
            scheduleHide()
        } else if globalVar.videoControlsAlwaysVisible {
            cancelHideTimer()
        }
    }
    
    func hideControls() {
        guard !globalVar.videoControlsAlwaysVisible,
              !isMouseInsideControls,
              !isDraggingProgress,
              !isDraggingControlBar else { return }
        
        cancelHideTimer()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            self.animator().alphaValue = 0.0
        }) {
            if self.alphaValue == 0 {
                self.isHidden = true
            }
        }
    }
    
    func hideControlsImmediately() {
        cancelHideTimer()
        alphaValue = 0
        isHidden = true
    }
    
    func scheduleHide(delay: TimeInterval = 3.0) {
        cancelHideTimer()
        guard !globalVar.videoControlsAlwaysVisible else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.hideControls()
        }
    }

    func applyVisibilityPreference() {
        if globalVar.videoControlsAlwaysVisible {
            showControls(autoHide: false)
        } else {
            scheduleHide()
        }
    }
    
    private func cancelHideTimer() {
        hideTimer?.invalidate()
        hideTimer = nil
    }
    
    // MARK: - Helpers
    
    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
    
    deinit {
        cancelHideTimer()
    }
}
