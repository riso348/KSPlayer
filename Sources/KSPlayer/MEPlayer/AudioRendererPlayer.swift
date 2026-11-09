//
//  AudioRendererPlayer.swift
//  KSPlayer
//
//  Created by kintan on 2022/12/2.
//

import AVFoundation
import Foundation

public class AudioRendererPlayer: AudioOutput {
    public var playbackRate: Float = 1 {
        didSet {
            if !isPaused {
                synchronizer.rate = playbackRate
            }
        }
    }

    public var volume: Float {
        get {
            renderer.volume
        }
        set {
            renderer.volume = newValue
        }
    }

    public var isMuted: Bool {
        get {
            renderer.isMuted
        }
        set {
            renderer.isMuted = newValue
        }
    }

    public weak var renderSource: OutputRenderSourceDelegate?
    private var periodicTimeObserver: Any?
    private let renderer = AVSampleBufferAudioRenderer()
    /// RMDB fork: public so the passthrough display layer can join it — then
    /// the system keeps picture and sound in sync (and owns the clock).
    public let synchronizer = AVSampleBufferRenderSynchronizer()
    private let serializationQueue = DispatchQueue(label: "ks.player.serialization.queue")
    /// Frame `play()` had to read for its start time — enqueued first, not lost.
    private var pendingRender: AudioFrame?

    /// RMDB fork, diagnostics: renderer state and how far ahead of the clock
    /// audio is queued. The synchronizer's clock follows the audio renderer,
    /// so audio running dry stalls the picture too.
    public struct FeedStats {
        public var status = "unknown"
        public var errorCode = 0
        public var channels = 0
        public var minLeadMs = Double.infinity
        /// Requests for more audio that found nothing decoded.
        public var underruns = 0
    }

    /// Set while a re-arm of requestMediaDataWhenReady is scheduled.
    private var rearmScheduled = false
    private let statsLock = NSLock()
    private var stats = FeedStats()

    /// Stats since the last call (status, error and channels are current).
    public func readFeedStats() -> FeedStats {
        statsLock.lock()
        defer {
            stats.minLeadMs = .infinity
            stats.underruns = 0
            statsLock.unlock()
        }
        var out = stats
        switch renderer.status {
        case .rendering: out.status = "rendering"
        case .failed: out.status = "FAILED"
        default: out.status = "waiting"
        }
        out.errorCode = (renderer.error as NSError?)?.code ?? 0
        return out
    }

    private func recordEnqueue(_ sampleBuffer: CMSampleBuffer, channels: Int) {
        // PCM buffers carry no duration (see AudioFrame.toCMSampleBuffer): use the sample count.
        var duration = sampleBuffer.duration
        if !duration.isValid, let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription, asbd.mSampleRate > 0 {
            duration = CMTime(value: CMTimeValue(sampleBuffer.numSamples) * CMTimeValue(max(asbd.mFramesPerPacket, 1)), timescale: CMTimeScale(asbd.mSampleRate))
        }
        let end = sampleBuffer.presentationTimeStamp + duration
        let lead = end.isValid ? (end - synchronizer.currentTime()).seconds * 1000 : .infinity
        statsLock.lock()
        stats.channels = channels
        stats.minLeadMs = min(stats.minLeadMs, lead)
        statsLock.unlock()
    }
    var isPaused: Bool {
        synchronizer.rate == 0
    }

    public required init() {
        synchronizer.addRenderer(renderer)
        if #available(macOS 11.3, iOS 14.5, tvOS 14.5, *) {
            synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        }
        if #available(tvOS 15.0, iOS 15.0, macOS 12.0, *) {
            renderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        }
    }

    public func prepare(audioFormat: AVAudioFormat) {
        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setPreferredOutputNumberOfChannels(Int(audioFormat.channelCount))
        KSLog("[audio] set preferredOutputNumberOfChannels: \(audioFormat.channelCount)")
        #endif
    }

    public func play() {
        let time: CMTime
        if #available(macOS 11.3, iOS 14.5, tvOS 14.5, *) {
            // 判断是否有足够的缓存，有的话就用当前的时间。seek的话，需要清空缓存，这样才能取到最新的时间。
            if renderer.hasSufficientMediaDataForReliablePlaybackStart {
                time = synchronizer.currentTime()
            } else {
                if let currentRender = pendingRender ?? renderSource?.getAudioOutputRender() {
                    pendingRender = currentRender
                    time = currentRender.cmtime
                } else {
                    time = .zero
                }
            }
        } else {
            if let currentRender = pendingRender ?? renderSource?.getAudioOutputRender() {
                pendingRender = currentRender
                time = currentRender.cmtime
            } else {
                time = .zero
            }
        }
        synchronizer.setRate(playbackRate, time: time)
        // 要手动的调用下，这样才能及时的更新音频的时间
        renderSource?.setAudio(time: time, position: -1)
        renderer.requestMediaDataWhenReady(on: serializationQueue) { [weak self] in
            guard let self else {
                return
            }
            self.request()
        }
        periodicTimeObserver = synchronizer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.01), queue: .main) { [weak self] time in
            guard let self else {
                return
            }
            self.renderSource?.setAudio(time: time, position: -1)
        }
    }

    public func pause() {
        synchronizer.rate = 0
        renderer.stopRequestingMediaData()
        if let periodicTimeObserver {
            synchronizer.removeTimeObserver(periodicTimeObserver)
            self.periodicTimeObserver = nil
        }
    }

    public func flush() {
        pendingRender = nil
        renderer.flush()
    }

    private func nextRender() -> AudioFrame? {
        if let pendingRender {
            self.pendingRender = nil
            return pendingRender
        }
        return renderSource?.getAudioOutputRender()
    }

    private func request() {
        while renderer.isReadyForMoreMediaData, !isPaused {
            guard var render = nextRender() else {
                statsLock.lock()
                stats.underruns += 1
                statsLock.unlock()
                // Nothing decoded yet. Returning while the renderer is still
                // ready makes it call straight back — a busy loop (thousands
                // a second) that takes the CPU the decoder needs. Look again
                // in 10 ms instead.
                renderer.stopRequestingMediaData()
                if !rearmScheduled {
                    rearmScheduled = true
                    serializationQueue.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                        guard let self else { return }
                        self.rearmScheduled = false
                        guard !self.isPaused else { return }
                        self.renderer.requestMediaDataWhenReady(on: self.serializationQueue) { [weak self] in
                            self?.request()
                        }
                    }
                }
                break
            }
            if let sampleBuffer = render.compressedSampleBuffer {
                // Passthrough E-AC-3: one packet per buffer, no merging.
                renderer.enqueue(sampleBuffer)
                recordEnqueue(sampleBuffer, channels: Int(render.audioFormat.channelCount))
                #if !os(macOS)
                let channelCount = Int(render.audioFormat.channelCount)
                if AVAudioSession.sharedInstance().preferredOutputNumberOfChannels != channelCount {
                    try? AVAudioSession.sharedInstance().setPreferredOutputNumberOfChannels(channelCount)
                }
                #endif
                continue
            }
            var array = [render]
            let loopCount = Int32(render.audioFormat.sampleRate) / 20 / Int32(render.numberOfSamples) - 2
            if loopCount > 0 {
                for _ in 0 ..< loopCount {
                    if let render = renderSource?.getAudioOutputRender() {
                        array.append(render)
                    }
                }
            }
            if array.count > 1 {
                render = AudioFrame(array: array)
            }
            if let sampleBuffer = render.toCMSampleBuffer() {
                let channelCount = render.audioFormat.channelCount
                renderer.audioTimePitchAlgorithm = channelCount > 2 ? .spectral : .timeDomain
                renderer.enqueue(sampleBuffer)
                recordEnqueue(sampleBuffer, channels: Int(channelCount))
                #if !os(macOS)
                if AVAudioSession.sharedInstance().preferredOutputNumberOfChannels != channelCount {
                    try? AVAudioSession.sharedInstance().setPreferredOutputNumberOfChannels(Int(channelCount))
                }
                #endif
            }
        }
    }
}
