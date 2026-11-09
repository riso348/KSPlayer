//
//  MetalPlayView.swift
//  KSPlayer
//
//  Created by kintan on 2018/3/11.
//

import AVFoundation
import Combine
import CoreMedia
#if canImport(MetalKit)
import MetalKit
#endif
public protocol DisplayLayerDelegate: NSObjectProtocol {
    func change(displayLayer: AVSampleBufferDisplayLayer)
}

public protocol VideoOutput: FrameOutput {
    var displayLayerDelegate: DisplayLayerDelegate? { get set }
    var options: KSOptions { get set }
    var displayLayer: AVSampleBufferDisplayLayer { get }
    var pixelBuffer: PixelBufferProtocol? { get }
    init(options: KSOptions)
    func invalidate()
    func readNextFrame()
}

public final class MetalPlayView: UIView, VideoOutput {
    public var displayLayer: AVSampleBufferDisplayLayer {
        displayView.displayLayer
    }

    private var isDovi: Bool = false
    private var formatDescription: CMFormatDescription? {
        didSet {
            options.updateVideo(refreshRate: fps, isDovi: isDovi, formatDescription: formatDescription)
        }
    }

    private var fps = Float(60) {
        didSet {
            if fps != oldValue {
                if KSOptions.preferredFrame {
                    let preferredFramesPerSecond = ceil(fps)
                    if #available(iOS 15.0, tvOS 15.0, macOS 14.0, *) {
                        displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: preferredFramesPerSecond, maximum: 2 * preferredFramesPerSecond, __preferred: preferredFramesPerSecond)
                    } else {
                        displayLink.preferredFramesPerSecond = Int(preferredFramesPerSecond) << 1
                    }
                }
                options.updateVideo(refreshRate: fps, isDovi: isDovi, formatDescription: formatDescription)
            }
        }
    }

    public private(set) var pixelBuffer: PixelBufferProtocol?
    /// 用displayLink会导致锁屏无法draw，
    /// 用DispatchSourceTimer的话，在播放4k视频的时候repeat的时间会变长,
    /// 用MTKView的draw(in:)也是不行，会卡顿
    private var displayLink: CADisplayLink!
//    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
    public var options: KSOptions
    public weak var renderSource: OutputRenderSourceDelegate?
    // AVSampleBufferAudioRenderer AVSampleBufferRenderSynchronizer AVSampleBufferDisplayLayer
    var displayView = AVSampleBufferDisplayView() {
        didSet {
            displayLayerDelegate?.change(displayLayer: displayView.displayLayer)
        }
    }

    private let metalView = MetalView()
    public weak var displayLayerDelegate: DisplayLayerDelegate?

    // MARK: Passthrough (RMDB fork)

    /// Layer the system decodes compressed Dolby Vision into, timed by
    /// AudioRendererPlayer's synchronizer (no control timebase of its own).
    private var passthroughView: AVSampleBufferDisplayView?
    private weak var passthroughSynchronizer: AVSampleBufferRenderSynchronizer?
    private let passthroughQueue = DispatchQueue(label: "ks.player.passthrough.video", qos: .userInteractive)
    private var passthroughNeedsKeyFrame = false
    private var passthroughRetryScheduled = false
    /// After a seek: frames still decoded from the old position are dropped
    /// until the first one from the new position (`isDiscontinuity`).
    private var passthroughAwaitingSeek = false
    private var passthroughSeekStarted: CFTimeInterval = 0
    private var passthroughCriteriaSent = false
    public var passthroughLayer: AVSampleBufferDisplayLayer? { passthroughView?.displayLayer }

    /// Passthrough feed health for diagnostics: how far ahead of the
    /// synchronizer clock frames reach the layer. A frame enqueued after its
    /// presentation time is shown late or skipped — judder.
    public struct PassthroughFeedStats {
        public var enqueued = 0
        public var late = 0
        public var minLeadMs = Double.infinity
        public var maxLeadMs = -Double.infinity
    }

    private let passthroughStatsLock = NSLock()
    private var passthroughStats = PassthroughFeedStats()

    /// What the layer itself reports about showing frames (cumulative).
    public struct PassthroughDisplayMetrics {
        public var frames = 0
        public var dropped = 0
        public var corrupted = 0
        /// Shown on the direct-to-display path (no compositing pass).
        public var optimized = 0
        public var delay: TimeInterval = 0
    }

    /// Latest metrics; `refreshPassthroughDisplayMetrics()` updates them.
    public private(set) var passthroughDisplayMetrics: PassthroughDisplayMetrics?

    public func refreshPassthroughDisplayMetrics() {
        guard let layer = passthroughView?.displayLayer else {
            passthroughDisplayMetrics = nil
            return
        }
        if #available(tvOS 17.4, iOS 17.4, macOS 14.4, *) {
            layer.sampleBufferRenderer.loadVideoPerformanceMetrics { [weak self] metrics in
                guard let metrics else { return }
                let value = PassthroughDisplayMetrics(
                    frames: metrics.totalNumberOfFrames,
                    dropped: metrics.numberOfDroppedFrames,
                    corrupted: metrics.numberOfCorruptedFrames,
                    optimized: metrics.numberOfFramesDisplayedUsingOptimizedCompositing,
                    delay: metrics.totalAccumulatedFrameDelay
                )
                DispatchQueue.main.async {
                    self?.passthroughDisplayMetrics = value
                }
            }
        }
    }

    /// Stats since the last call.
    public func readPassthroughStats() -> PassthroughFeedStats {
        passthroughStatsLock.lock()
        defer {
            passthroughStats = PassthroughFeedStats()
            passthroughStatsLock.unlock()
        }
        return passthroughStats
    }
    public init(options: KSOptions) {
        self.options = options
        super.init(frame: .zero)
        addSubview(displayView)
        addSubview(metalView)
        metalView.isHidden = true
        //        displayLink = CADisplayLink(block: renderFrame)
        displayLink = CADisplayLink(target: self, selector: #selector(renderFrame))
        // 一定要用common。不然在视频上面操作view的话，那就会卡顿了。
        displayLink.add(to: .main, forMode: .common)
        pause()
    }

    public func play() {
        // Passthrough: the synchronizer presents the frames, not the display link.
        displayLink.isPaused = passthroughView != nil
    }

    public func pause() {
        displayLink.isPaused = true
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        subview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            subview.leftAnchor.constraint(equalTo: leftAnchor),
            subview.topAnchor.constraint(equalTo: topAnchor),
            subview.bottomAnchor.constraint(equalTo: bottomAnchor),
            subview.rightAnchor.constraint(equalTo: rightAnchor),
        ])
    }

    override public var contentMode: UIViewContentMode {
        didSet {
            metalView.contentMode = contentMode
            switch contentMode {
            case .scaleToFill:
                displayView.displayLayer.videoGravity = .resize
            case .scaleAspectFit, .center:
                displayView.displayLayer.videoGravity = .resizeAspect
            case .scaleAspectFill:
                displayView.displayLayer.videoGravity = .resizeAspectFill
            default:
                break
            }
            passthroughView?.displayLayer.videoGravity = displayView.displayLayer.videoGravity
        }
    }

    #if canImport(UIKit)
    override public func touchesMoved(_ touches: Set<UITouch>, with: UIEvent?) {
        if options.display == .plane {
            super.touchesMoved(touches, with: with)
        } else {
            options.display.touchesMoved(touch: touches.first!)
        }
    }
    #else
    override public func touchesMoved(with event: NSEvent) {
        if options.display == .plane {
            super.touchesMoved(with: event)
        } else {
            options.display.touchesMoved(touch: event.allTouches().first!)
        }
    }
    #endif

    public func flush() {
        pixelBuffer = nil
        if let passthroughView {
            let layer = passthroughView.displayLayer
            passthroughQueue.async { [weak self] in
                layer.flushAndRemoveImage()
                self?.passthroughNeedsKeyFrame = true
            }
            return
        }
        if displayView.isHidden {
            metalView.clear()
        } else {
            displayView.displayLayer.flushAndRemoveImage()
        }
    }

    public func invalidate() {
        disablePassthrough()
        displayLink.invalidate()
    }

    public func readNextFrame() {
        draw(force: true)
    }

    /// Switches this view to the passthrough layer: compressed frames are
    /// pulled in decode order as fast as the layer takes them, and the
    /// synchronizer (driven by the audio renderer) decides when each is shown.
    public func enablePassthrough(synchronizer: AVSampleBufferRenderSynchronizer) {
        guard passthroughView == nil else { return }
        let view = AVSampleBufferDisplayView(frame: bounds, controlTimebase: false)
        view.displayLayer.videoGravity = displayView.displayLayer.videoGravity
        addSubview(view)
        displayView.isHidden = true
        metalView.isHidden = true
        displayLink.isPaused = true
        passthroughView = view
        passthroughSynchronizer = synchronizer
        passthroughNeedsKeyFrame = true
        passthroughCriteriaSent = false
        synchronizer.addRenderer(view.displayLayer)
        displayLayerDelegate?.change(displayLayer: view.displayLayer)
        let layer = view.displayLayer
        layer.requestMediaDataWhenReady(on: passthroughQueue) { [weak self] in
            self?.feedPassthrough(layer: layer)
        }
        KSLog("[passthrough] display layer attached to the audio synchronizer")
    }

    /// Seek started: empty the layer and drop old frames (see KSMEPlayer.seek).
    public func passthroughSeek() {
        guard let passthroughView else { return }
        let layer = passthroughView.displayLayer
        passthroughQueue.async { [weak self] in
            guard let self else { return }
            self.passthroughAwaitingSeek = true
            self.passthroughSeekStarted = CACurrentMediaTime()
            self.passthroughNeedsKeyFrame = true
            layer.flush()
        }
    }

    public func disablePassthrough() {
        guard let passthroughView else { return }
        let layer = passthroughView.displayLayer
        layer.stopRequestingMediaData()
        passthroughSynchronizer?.removeRenderer(layer, at: .zero, completionHandler: nil)
        passthroughSynchronizer = nil
        self.passthroughView = nil
        runOnMainThread { [weak self] in
            passthroughView.removeFromSuperview()
            guard let self else { return }
            // draw() picks Metal or the display layer again on the next frame.
            self.metalView.isHidden = false
            self.displayLayerDelegate?.change(displayLayer: self.displayView.displayLayer)
        }
    }

    private func feedPassthrough(layer: AVSampleBufferDisplayLayer) {
        guard passthroughView?.displayLayer === layer else { return }
        while layer.isReadyForMoreMediaData {
            if layer.status == .failed {
                KSLog("[passthrough] display layer failed: \(String(describing: layer.error)) — flushing")
                layer.flush()
                passthroughNeedsKeyFrame = true
            } else if #available(macOS 11.0, iOS 14, tvOS 14, *), layer.requiresFlushToResumeDecoding {
                layer.flush()
                passthroughNeedsKeyFrame = true
            }
            guard let frame = renderSource?.getVideoOutputRender(force: true) else {
                // Nothing decoded yet. The layer doesn't call back while it
                // stays ready, so look again shortly.
                if !passthroughRetryScheduled {
                    passthroughRetryScheduled = true
                    passthroughQueue.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                        self?.passthroughRetryScheduled = false
                        self?.feedPassthrough(layer: layer)
                    }
                }
                return
            }
            guard let sampleBuffer = frame.sampleBuffer else { continue }
            if passthroughAwaitingSeek {
                // Should the marker frame ever be missed, any key frame
                // will do after 3 s.
                let timedOut = CACurrentMediaTime() - passthroughSeekStarted > 3
                guard frame.isDiscontinuity || (timedOut && !sampleBuffer.isNotSync) else {
                    continue
                }
                passthroughAwaitingSeek = false
            }
            if frame.isDiscontinuity {
                // First frame after a seek: drop what the layer still holds.
                layer.flush()
                passthroughNeedsKeyFrame = false
            } else if passthroughNeedsKeyFrame {
                if sampleBuffer.isNotSync { continue }
                passthroughNeedsKeyFrame = false
            }
            layer.enqueue(sampleBuffer)
            if let synchronizer = passthroughSynchronizer, synchronizer.rate > 0, !sampleBuffer.isDoNotDisplay {
                let lead = (sampleBuffer.presentationTimeStamp - synchronizer.currentTime()).seconds * 1000
                passthroughStatsLock.lock()
                passthroughStats.enqueued += 1
                if lead < 0 { passthroughStats.late += 1 }
                passthroughStats.minLeadMs = min(passthroughStats.minLeadMs, lead)
                passthroughStats.maxLeadMs = max(passthroughStats.maxLeadMs, lead)
                passthroughStatsLock.unlock()
            }
            let time = frame.cmtime
            let position = frame.position
            let fps = frame.fps
            let sendCriteria = !passthroughCriteriaSent
            passthroughCriteriaSent = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.renderSource?.setVideo(time: time, position: position)
                if sendCriteria {
                    // TV mode (Dolby Vision, frame rate) from the format
                    // description the layer decodes, not from a pixel buffer.
                    // Dolby Vision unless the stream was reduced to its
                    // HDR10 base layer (profile 7 FEL, see KSOptions).
                    let atoms = sampleBuffer.formatDescription.flatMap {
                        CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? NSDictionary
                    }
                    let isDovi = atoms.map { $0["dvcC"] != nil || $0["dvvC"] != nil || $0["dvwC"] != nil } ?? true
                    self.options.updateVideo(refreshRate: fps, isDovi: isDovi, formatDescription: sampleBuffer.formatDescription)
                }
            }
        }
    }

//    deinit {
//        print()
//    }
}

extension MetalPlayView {
    @objc private func renderFrame() {
        draw(force: false)
    }

    private func draw(force: Bool) {
        // Passthrough frames go to the layer in feedPassthrough; popping one
        // here would lose a reference frame.
        if options.isVideoPassthroughActive || passthroughView != nil {
            return
        }
        autoreleasepool {
            guard let frame = renderSource?.getVideoOutputRender(force: force) else {
                return
            }
            pixelBuffer = frame.corePixelBuffer
            guard let pixelBuffer else {
                return
            }
            isDovi = frame.isDovi
            fps = frame.fps
            let cmtime = frame.cmtime
            let par = pixelBuffer.size
            let sar = pixelBuffer.aspectRatio
            if let pixelBuffer = pixelBuffer.cvPixelBuffer, options.isUseDisplayLayer() {
                if displayView.isHidden {
                    displayView.isHidden = false
                    metalView.isHidden = true
                    metalView.clear()
                }
                if let dar = options.customizeDar(sar: sar, par: par) {
                    pixelBuffer.aspectRatio = CGSize(width: dar.width, height: dar.height * par.width / par.height)
                }
                checkFormatDescription(pixelBuffer: pixelBuffer)
                set(pixelBuffer: pixelBuffer, time: cmtime)
            } else {
                if !displayView.isHidden {
                    displayView.isHidden = true
                    metalView.isHidden = false
                    displayView.displayLayer.flushAndRemoveImage()
                }
                let size: CGSize
                if options.display == .plane {
                    if let dar = options.customizeDar(sar: sar, par: par) {
                        size = CGSize(width: par.width, height: par.width * dar.height / dar.width)
                    } else {
                        size = CGSize(width: par.width, height: par.height * sar.height / sar.width)
                    }
                } else {
                    size = KSOptions.sceneSize
                }
                checkFormatDescription(pixelBuffer: pixelBuffer)
                #if !os(tvOS)
                if #available(iOS 16, *) {
                    metalView.metalLayer.edrMetadata = frame.edrMetadata
                }
                #endif
                metalView.draw(pixelBuffer: pixelBuffer, display: options.display, size: size)
            }
            renderSource?.setVideo(time: cmtime, position: frame.position)
        }
    }

    private func checkFormatDescription(pixelBuffer: PixelBufferProtocol) {
        if formatDescription == nil || !pixelBuffer.matche(formatDescription: formatDescription!) {
            if formatDescription != nil {
                displayView.removeFromSuperview()
                displayView = AVSampleBufferDisplayView()
                displayView.frame = frame
                addSubview(displayView)
            }
            formatDescription = pixelBuffer.formatDescription
        }
    }

    private func set(pixelBuffer: CVPixelBuffer, time: CMTime) {
        guard let formatDescription else { return }
        displayView.enqueue(imageBuffer: pixelBuffer, formatDescription: formatDescription, time: time)
    }
}

class MetalView: UIView {
    private let render = MetalRender()
    #if canImport(UIKit)
    override public class var layerClass: AnyClass { CAMetalLayer.self }
    #endif
    var metalLayer: CAMetalLayer {
        // swiftlint:disable force_cast
        layer as! CAMetalLayer
        // swiftlint:enable force_cast
    }

    init() {
        super.init(frame: .zero)
        #if !canImport(UIKit)
        layer = CAMetalLayer()
        #endif
        metalLayer.device = MetalRender.device
        metalLayer.framebufferOnly = true
//        metalLayer.displaySyncEnabled = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func clear() {
        if let drawable = metalLayer.nextDrawable() {
            render.clear(drawable: drawable)
        }
    }

    func draw(pixelBuffer: PixelBufferProtocol, display: DisplayEnum, size: CGSize) {
        metalLayer.drawableSize = size
        metalLayer.pixelFormat = KSOptions.colorPixelFormat(bitDepth: pixelBuffer.bitDepth)
        let colorspace = pixelBuffer.colorspace
        if colorspace != nil, metalLayer.colorspace != colorspace {
            metalLayer.colorspace = colorspace
            KSLog("[video] CAMetalLayer colorspace \(String(describing: colorspace))")
            #if !os(tvOS)
            if #available(iOS 16.0, *) {
                if let name = colorspace?.name, name != CGColorSpace.sRGB {
                    #if os(macOS)
                    metalLayer.wantsExtendedDynamicRangeContent = window?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0 > 1.0
                    #else
                    metalLayer.wantsExtendedDynamicRangeContent = true
                    #endif
                } else {
                    metalLayer.wantsExtendedDynamicRangeContent = false
                }
                KSLog("[video] CAMetalLayer wantsExtendedDynamicRangeContent \(metalLayer.wantsExtendedDynamicRangeContent)")
            }
            #endif
        }
        guard let drawable = metalLayer.nextDrawable() else {
            KSLog("[video] CAMetalLayer not readyForMoreMediaData")
            return
        }
        render.draw(pixelBuffer: pixelBuffer, display: display, drawable: drawable)
    }
}

class AVSampleBufferDisplayView: UIView {
    #if canImport(UIKit)
    override public class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    #endif
    var displayLayer: AVSampleBufferDisplayLayer {
        // swiftlint:disable force_cast
        layer as! AVSampleBufferDisplayLayer
        // swiftlint:enable force_cast
    }

    override convenience init(frame: CGRect) {
        self.init(frame: frame, controlTimebase: true)
    }

    /// `controlTimebase: false` for a layer that joins an
    /// AVSampleBufferRenderSynchronizer (which then owns its timebase).
    init(frame: CGRect, controlTimebase useControlTimebase: Bool) {
        super.init(frame: frame)
        #if !canImport(UIKit)
        layer = AVSampleBufferDisplayLayer()
        #endif
        guard useControlTimebase else { return }
        var controlTimebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &controlTimebase)
        if let controlTimebase {
            displayLayer.controlTimebase = controlTimebase
            CMTimebaseSetTime(controlTimebase, time: .zero)
            CMTimebaseSetRate(controlTimebase, rate: 1.0)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func enqueue(imageBuffer: CVPixelBuffer, formatDescription: CMVideoFormatDescription, time: CMTime) {
        let timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        //        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: imageBuffer, formatDescription: formatDescription, sampleTiming: [timing], sampleBufferOut: &sampleBuffer)
        if let sampleBuffer {
            if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [NSMutableDictionary], let dic = attachmentsArray.first {
                dic[kCMSampleAttachmentKey_DisplayImmediately] = true
            }
            if displayLayer.isReadyForMoreMediaData {
                displayLayer.enqueue(sampleBuffer)
            } else {
                KSLog("[video] AVSampleBufferDisplayLayer not readyForMoreMediaData. video time \(time), controlTime \(displayLayer.timebase.time) ")
                displayLayer.enqueue(sampleBuffer)
            }
            if #available(macOS 11.0, iOS 14, tvOS 14, *) {
                if displayLayer.requiresFlushToResumeDecoding {
                    KSLog("[video] AVSampleBufferDisplayLayer requiresFlushToResumeDecoding so flush")
                    displayLayer.flush()
                }
            }
            if displayLayer.status == .failed {
                KSLog("[video] AVSampleBufferDisplayLayer status failed so flush")
                displayLayer.flush()
                //                    if let error = displayLayer.error as NSError?, error.code == -11847 {
                //                        displayLayer.stopRequestingMediaData()
                //                    }
            }
        }
    }
}

#if os(macOS)
import CoreVideo

class CADisplayLink {
    private let displayLink: CVDisplayLink
    private var runloop: RunLoop?
    private var mode = RunLoop.Mode.default
    public var preferredFramesPerSecond = 60
    @available(macOS 12.0, *)
    public var preferredFrameRateRange: CAFrameRateRange {
        get {
            CAFrameRateRange()
        }
        set {}
    }

    public var timestamp: TimeInterval {
        var timeStamp = CVTimeStamp()
        if CVDisplayLinkGetCurrentTime(displayLink, &timeStamp) == kCVReturnSuccess, (timeStamp.flags & CVTimeStampFlags.hostTimeValid.rawValue) != 0 {
            return TimeInterval(timeStamp.hostTime / NSEC_PER_SEC)
        }
        return 0
    }

    public var duration: TimeInterval {
        CVDisplayLinkGetActualOutputVideoRefreshPeriod(displayLink)
    }

    public var targetTimestamp: TimeInterval {
        duration + timestamp
    }

    public var isPaused: Bool {
        get {
            !CVDisplayLinkIsRunning(displayLink)
        }
        set {
            if newValue {
                CVDisplayLinkStop(displayLink)
            } else {
                CVDisplayLinkStart(displayLink)
            }
        }
    }

    public init(target: NSObject, selector: Selector) {
        var displayLink: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        self.displayLink = displayLink!
        CVDisplayLinkSetOutputHandler(self.displayLink) { [weak self] _, _, _, _, _ in
            guard let self else { return kCVReturnSuccess }
            self.runloop?.perform(selector, target: target, argument: self, order: 0, modes: [self.mode])
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(self.displayLink)
    }

    public init(block: @escaping (() -> Void)) {
        var displayLink: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        self.displayLink = displayLink!
        CVDisplayLinkSetOutputHandler(self.displayLink) { _, _, _, _, _ in
            block()
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(self.displayLink)
    }

    open func add(to runloop: RunLoop, forMode mode: RunLoop.Mode) {
        self.runloop = runloop
        self.mode = mode
    }

    public func invalidate() {
        isPaused = true
        runloop = nil
        CVDisplayLinkSetOutputHandler(displayLink) { _, _, _, _, _ in
            kCVReturnError
        }
    }
}
#endif
