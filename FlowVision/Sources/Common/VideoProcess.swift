//
//  VideoProcess.swift
//  FlowVision
//

import Foundation
import Cocoa
import AVFoundation
import AVKit

/// Coordinates bounded, cancellable media preheating for one browser window.
/// Image work fills FlowVision's decoded-image cache. Video work reads the
/// first few seconds of compressed samples so SMB data lands in the macOS file
/// cache, and retains the parsed asset for AVPlayer fallback.
final class MediaPreheatManager {
    private let imageQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "FlowVision.MediaPreheat.Images"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    private let videoQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "FlowVision.MediaPreheat.Videos"
        queue.qualityOfService = .utility
        // Serial reads avoid turning SMB preheating into competing random I/O.
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private let stateQueue = DispatchQueue(label: "FlowVision.MediaPreheat.State")
    private var generation = 0
    private var assets: [URL: AVURLAsset] = [:]

    deinit {
        imageQueue.cancelAllOperations()
        videoQueue.cancelAllOperations()
    }

    /// Starts a new ±5 media window and invalidates work from the old position.
    @discardableResult
    func beginWindow(retaining urls: [URL]) -> Int {
        imageQueue.cancelAllOperations()
        videoQueue.cancelAllOperations()
        let retainedURLs = Set(urls)
        return stateQueue.sync {
            generation += 1
            assets = assets.filter { retainedURLs.contains($0.key) }
            return generation
        }
    }

    func scheduleImage(generation: Int, distance: Int, work: @escaping () -> Void) {
        let operation = BlockOperation { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            autoreleasepool(invoking: work)
        }
        operation.queuePriority = queuePriority(for: distance)
        imageQueue.addOperation(operation)
    }

    func scheduleVideo(url: URL, generation: Int, distance: Int, seconds: Double = 5) {
        guard preheatedAsset(for: url) == nil else { return }
        let operation = BlockOperation { [weak self] in
            self?.preheatVideo(url: url, generation: generation, seconds: seconds)
        }
        operation.queuePriority = queuePriority(for: distance)
        videoQueue.addOperation(operation)
    }

    func preheatedAsset(for url: URL) -> AVURLAsset? {
        stateQueue.sync { assets[url] }
    }

    private func isCurrent(_ value: Int) -> Bool {
        stateQueue.sync { generation == value }
    }

    private func queuePriority(for distance: Int) -> Operation.QueuePriority {
        switch abs(distance) {
        case 0...1: return .veryHigh
        case 2: return .high
        case 3: return .normal
        default: return .low
        }
    }

    private func preheatVideo(url: URL, generation: Int, seconds: Double) {
        guard isCurrent(generation) else { return }

        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        guard let videoTrack = asset.tracks(withMediaType: .video).first,
              isCurrent(generation)
        else { return }

        stateQueue.sync {
            if self.generation == generation {
                self.assets[url] = asset
            }
        }

        do {
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(
                start: .zero,
                duration: CMTime(seconds: max(1, seconds), preferredTimescale: 600)
            )
            let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return }
            reader.add(output)
            guard reader.startReading() else { return }

            while isCurrent(generation), output.copyNextSampleBuffer() != nil {
                // Reading compressed samples intentionally warms the unified
                // file cache; AVPlayer/mpv will decode them when playback starts.
            }
            if !isCurrent(generation) {
                reader.cancelReading()
            }
        } catch {
            log("Video preheat failed: \(url.lastPathComponent): \(error.localizedDescription)", level: .warn)
        }
    }
}

class NoHitAVPlayerView: AVPlayerView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        return superview?.hitTest(convert(point, to: superview))
    }
}

class LargeAVPlayerView: AVPlayerView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    override func scrollWheel(with event: NSEvent) {
        // 不响应滚动事件，直接传递给下一个
        // Don't respond to scroll events, pass directly to next responder
        self.nextResponder?.scrollWheel(with: event)
    }
}


func createLoopingComposition(url: URL) -> AVMutableComposition? {
    let asset = AVAsset(url: url)
    guard let videoTrack = asset.tracks(withMediaType: .video).first,
        let audioTrack = asset.tracks(withMediaType: .audio).first else {
        return nil
    }

    // 打印视频轨道信息
    // Print video track information
    // let asset = AVAsset(url: url)
    // for track in asset.tracks {
    //     print("媒体类型:", track.mediaType)
    //     print("时长范围:", track.timeRange)
    // }

    // 计算音视频轨道的共同时间范围
    // Calculate common time range of audio and video tracks
    let timeRange = CMTimeRangeGetIntersection(videoTrack.timeRange, otherRange: audioTrack.timeRange)

    // 创建一个新的可变组合
    // Create a new mutable composition
    let composition = AVMutableComposition()

    do {
        // 将共同时间范围内的音视频轨道插入到新的组合中
        // Insert audio and video tracks within common time range into new composition
        try composition.insertTimeRange(timeRange, of: asset, at: .zero)
    } catch {
        print("Error inserting time range into composition: \(error)")
        return nil
    }

    // 保持视频轨道的方向
    // Preserve video track orientation
    if let compositionVideoTrack = composition.tracks(withMediaType: .video).first {
        compositionVideoTrack.preferredTransform = videoTrack.preferredTransform
    }

    return composition
}

func getCommonTimeRange(url: URL) -> CMTimeRange? {
    getCommonTimeRange(asset: AVAsset(url: url))
}

func getCommonTimeRange(asset: AVAsset) -> CMTimeRange? {
    guard let videoTrack = asset.tracks(withMediaType: .video).first else {
        return nil
    }

    // 如果有音频轨道，计算音视频轨道的共同时间范围
    // If audio track exists, calculate common time range of audio and video tracks
    if let audioTrack = asset.tracks(withMediaType: .audio).first {
        return CMTimeRangeGetIntersection(videoTrack.timeRange, otherRange: audioTrack.timeRange)
    }

    // 如果没有音频轨道，直接使用视频轨道的时间范围
    // If no audio track, use video track's time range directly
    return videoTrack.timeRange
}
