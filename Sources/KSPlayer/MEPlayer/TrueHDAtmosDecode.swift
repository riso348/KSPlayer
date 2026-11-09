//
//  TrueHDAtmosDecode.swift
//  KSPlayer (RMDB fork)
//
//  TrueHD Atmos with its height channels. Apple TV can't bitstream TrueHD,
//  and FFmpeg decodes only its 7.1 downmix presentation, which folds the
//  heights into the floor. Here the Atmos presentation itself is decoded
//  and rendered to 7.1.4 (Vendor/rmdb_truehd: Rust `truehd` crate for beds,
//  objects and their positions, plus our renderer — in Rust so it is
//  optimized in every build), and the 12-channel PCM goes to
//  AVSampleBufferAudioRenderer; tvOS carries it to the receiver over Dolby
//  MAT. Lossless up to the render — no re-compression.
//
//  Only for TrueHD that FFmpeg marks as Atmos, at 48 kHz, with
//  AudioRendererPlayer. Falls back to FFmpeg (7.1) if no Atmos presentation
//  turns up.
//

#if canImport(RMDBTrueHD)
import AVFoundation
import FFmpegKit
import Libavcodec
import RMDBTrueHD

final class TrueHDAtmosDecode: DecodeProtocol {
    private static let sampleRate: Int64 = 48000
    /// TrueHD packets hold ~1 ms. The audio frame queue holds 255 frames,
    /// so frames of that size buffered 0.2 s; 40 ms frames buffer 10 s.
    private static let frameSamples = 1920
    /// No decoded access unit for this many packets (~3 s): give up on Atmos.
    private static let packetsBeforeFallback = 3600

    private let assetTrack: FFmpegAssetTrack
    private let options: KSOptions
    private let decoder: OpaquePointer
    private let rendered = UnsafeMutablePointer<ThdRendered>.allocate(capacity: 1)
    private let audioFormat: AVAudioFormat
    /// Rendered samples not yet handed out, starting at `pendingStart`.
    private var output = [Float]()
    private var pendingStart: Int64 = 0
    private var pendingPosition: Int64 = 0
    private var pendingSize: Int32 = 0
    private var fallback: FFmpegDecode?
    private var packetsWithoutOutput = 0
    private var hasOutput = false
    /// Next sample position (1/48000 s), continuous across packets.
    private var nextSample: Int64?
    private var reportedElements = 0
    // Diagnostics (overlay "native" row), reported once a second.
    private var jumps = 0
    private var peak: Float = 0
    private var clipped = 0
    private var lastReport = CACurrentMediaTime()

    init?(assetTrack: FFmpegAssetTrack, options: KSOptions) {
        guard let decoder = thd_decoder_new(),
              let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Atmos_7_1_4)
        else { return nil }
        self.assetTrack = assetTrack
        self.options = options
        self.decoder = decoder
        audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Self.sampleRate), interleaved: true, channelLayout: layout)
        rendered.initialize(to: ThdRendered())
        #if os(tvOS) || os(iOS)
        // More than 8 channels only reach the route with this on.
        try? AVAudioSession.sharedInstance().setSupportsMultichannelContent(true)
        #endif
        assetTrack.passthroughInfo = "TrueHD Atmos → 7.1.4 PCM"
    }

    deinit {
        thd_decoder_free(decoder)
        rendered.deallocate()
    }

    func decodeFrame(from packet: Packet, completionHandler: @escaping (Result<MEFrame, Error>) -> Void) {
        if let fallback {
            fallback.decodeFrame(from: packet, completionHandler: completionHandler)
            return
        }
        guard let corePacket = packet.corePacket?.pointee, let data = corePacket.data, corePacket.size > 0 else {
            return
        }
        thd_decoder_push(decoder, data, Int(corePacket.size))
        let renderedStart = output.count
        var samples = 0
        var elements = 0
        while thd_decoder_next_rendered(decoder, rendered) == 1 {
            let count = Int(rendered.pointee.sample_count)
            guard count > 0 else { continue }
            elements = Int(rendered.pointee.element_count)
            let pcm = UnsafeRawPointer(rendered).advanced(by: MemoryLayout<ThdRendered>.offset(of: \ThdRendered.pcm)!).assumingMemoryBound(to: Float.self)
            let values = UnsafeBufferPointer(start: pcm, count: count * AtmosOutput.channels)
            for value in values where abs(value) > 0.98 {
                peak = max(peak, abs(value))
                if abs(value) > 1 { clipped += 1 }
            }
            output.append(contentsOf: values)
            samples += count
        }
        guard samples > 0 else {
            packetsWithoutOutput += 1
            if !hasOutput, packetsWithoutOutput > Self.packetsBeforeFallback {
                startFallback()
            }
            return
        }
        hasOutput = true
        packetsWithoutOutput = 0
        report(elements: elements)

        // Timestamps in samples so consecutive buffers butt exactly; the
        // container's are milliseconds. Re-anchored to the packet when they
        // drift apart (a gap in the stream, a resync).
        let timebase = assetTrack.timebase
        let pts = corePacket.pts != Int64.min ? corePacket.pts : corePacket.dts
        var start = nextSample ?? 0
        if pts != Int64.min {
            let packetStart = pts * Int64(timebase.num) * Self.sampleRate / Int64(timebase.den)
            let packetSamples = corePacket.duration > 0 ? corePacket.duration * Int64(timebase.num) * Self.sampleRate / Int64(timebase.den) : Int64(samples)
            // Access units lost to a resync are the packet's first ones.
            let expected = packetStart + max(0, packetSamples - Int64(samples))
            if nextSample == nil || abs(start - expected) > Self.sampleRate / 20 {
                if nextSample != nil {
                    jumps += 1
                }
                if renderedStart > 0 {
                    // A jump: hand out what came before it on its own.
                    let jumped = Array(output[renderedStart...])
                    output.removeSubrange(renderedStart...)
                    emit(completionHandler)
                    output = jumped
                }
                start = expected
            }
        }
        if renderedStart == 0 || output.count == samples * AtmosOutput.channels {
            pendingStart = start
            pendingPosition = corePacket.pos
            pendingSize = 0
        }
        pendingSize += corePacket.size
        nextSample = start + Int64(samples)
        if output.count >= Self.frameSamples * AtmosOutput.channels {
            emit(completionHandler)
        }
    }

    /// Hands the pending samples out as one audio frame.
    private func emit(_ completionHandler: @escaping (Result<MEFrame, Error>) -> Void) {
        let samples = output.count / AtmosOutput.channels
        guard samples > 0 else { return }
        let audioFrame = AudioFrame(dataSize: output.count * MemoryLayout<Float>.size, audioFormat: audioFormat)
        output.withUnsafeBytes { bytes in
            audioFrame.data[0]?.update(from: bytes.bindMemory(to: UInt8.self).baseAddress!, count: bytes.count)
        }
        audioFrame.numberOfSamples = UInt32(samples)
        audioFrame.timebase = Timebase(num: 1, den: Int32(Self.sampleRate))
        audioFrame.timestamp = pendingStart
        audioFrame.duration = Int64(samples)
        audioFrame.position = pendingPosition
        audioFrame.size = pendingSize
        output.removeAll(keepingCapacity: true)
        completionHandler(.success(audioFrame))
    }

    func doFlushCodec() {
        thd_decoder_reset(decoder)
        output.removeAll(keepingCapacity: true)
        nextSample = nil
        fallback?.doFlushCodec()
    }

    func shutdown() {
        fallback?.shutdown()
    }

    func decode() {
        fallback?.decode()
    }

    // MARK: -

    private func startFallback() {
        KSLog("[atmos] no TrueHD Atmos presentation decoded (\(thd_decoder_error_count(decoder)) errors) — falling back to FFmpeg 7.1")
        let ffmpeg = FFmpegDecode(assetTrack: assetTrack, options: options)
        ffmpeg.decode()
        fallback = ffmpeg
        let assetTrack = assetTrack
        DispatchQueue.main.async {
            assetTrack.passthroughInfo = "TrueHD Atmos failed → FFmpeg 7.1"
        }
    }

    private func report(elements: Int) {
        let now = CACurrentMediaTime()
        guard elements != reportedElements || now - lastReport > 1 else { return }
        if elements != reportedElements {
            KSLog("[atmos] TrueHD Atmos → 7.1.4 PCM · \(elements) elements")
        }
        reportedElements = elements
        lastReport = now
        var info = "TrueHD Atmos → 7.1.4 PCM · \(elements) elements · \(thd_decoder_error_count(decoder)) err · \(jumps) jumps"
        if peak > 0 {
            info += String(format: " · peak %.2f", peak)
        }
        if clipped > 0 {
            info += " · \(clipped) CLIPPED"
        }
        peak = 0
        let assetTrack = assetTrack
        DispatchQueue.main.async {
            assetTrack.passthroughInfo = info
        }
    }
}

private enum AtmosOutput {
    /// 7.1.4
    static let channels = 12
}
#endif
