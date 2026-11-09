//
//  TrueHDAtmosDecode.swift
//  KSPlayer (RMDB fork)
//
//  TrueHD Atmos with its height channels. Apple TV can't bitstream TrueHD,
//  and FFmpeg decodes only its 7.1 downmix presentation, which folds the
//  heights into the floor. Here the Atmos presentation itself is decoded
//  (Vendor/rmdb_truehd, Rust `truehd` crate: beds + objects + their
//  positions), AtmosObjectRenderer renders it to 7.1.4, and the 12-channel
//  PCM goes to AVSampleBufferAudioRenderer; tvOS carries it to the receiver
//  over Dolby MAT. Lossless up to the render — no re-compression.
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
    /// No decoded access unit for this many packets (~3 s): give up on Atmos.
    private static let packetsBeforeFallback = 3600

    private let assetTrack: FFmpegAssetTrack
    private let options: KSOptions
    private let decoder: OpaquePointer
    private let renderer = AtmosObjectRenderer()
    private let frame = UnsafeMutablePointer<ThdFrame>.allocate(capacity: 1)
    private let audioFormat: AVAudioFormat
    private var output = [Float]()
    private var fallback: FFmpegDecode?
    private var packetsWithoutOutput = 0
    private var hasOutput = false
    /// Next sample position (1/48000 s), continuous across packets.
    private var nextSample: Int64?
    private var reportedElements = 0

    init?(assetTrack: FFmpegAssetTrack, options: KSOptions) {
        guard let decoder = thd_decoder_new(),
              let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Atmos_7_1_4)
        else { return nil }
        self.assetTrack = assetTrack
        self.options = options
        self.decoder = decoder
        audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Self.sampleRate), interleaved: true, channelLayout: layout)
        frame.initialize(to: ThdFrame())
        #if os(tvOS) || os(iOS)
        // More than 8 channels only reach the route with this on.
        try? AVAudioSession.sharedInstance().setSupportsMultichannelContent(true)
        #endif
        assetTrack.passthroughInfo = "TrueHD Atmos → 7.1.4 PCM"
    }

    deinit {
        thd_decoder_free(decoder)
        frame.deallocate()
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
        output.removeAll(keepingCapacity: true)
        var samples = 0
        var elements = 0
        while thd_decoder_next(decoder, frame) == 1 {
            let count = Int(frame.pointee.sample_count)
            elements = Int(frame.pointee.element_count)
            guard count > 0, elements > 0 else { continue }
            let start = output.count
            output.append(contentsOf: repeatElement(0, count: count * AtmosObjectRenderer.outputCount))
            let updates = Self.updates(frame)
            let pcm = UnsafeRawPointer(frame).advanced(by: MemoryLayout<ThdFrame>.offset(of: \ThdFrame.pcm)!).assumingMemoryBound(to: Float.self)
            output.withUnsafeMutableBufferPointer { buffer in
                renderer.render(input: pcm, elements: elements, samples: count, updates: updates, output: buffer.baseAddress! + start)
            }
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
        if pts != Int64.min {
            let packetStart = pts * Int64(timebase.num) * Self.sampleRate / Int64(timebase.den)
            let packetSamples = corePacket.duration > 0 ? corePacket.duration * Int64(timebase.num) * Self.sampleRate / Int64(timebase.den) : Int64(samples)
            // Access units lost to a resync are the packet's first ones.
            let expected = packetStart + max(0, packetSamples - Int64(samples))
            if let nextSample, abs(nextSample - expected) <= Self.sampleRate / 20 {
                // In step.
            } else {
                nextSample = expected
            }
        }
        let timestamp = nextSample ?? 0
        nextSample = timestamp + Int64(samples)

        let audioFrame = AudioFrame(dataSize: output.count * MemoryLayout<Float>.size, audioFormat: audioFormat)
        output.withUnsafeBytes { bytes in
            audioFrame.data[0]?.update(from: bytes.bindMemory(to: UInt8.self).baseAddress!, count: bytes.count)
        }
        audioFrame.numberOfSamples = UInt32(samples)
        audioFrame.timebase = Timebase(num: 1, den: Int32(Self.sampleRate))
        audioFrame.timestamp = timestamp
        audioFrame.duration = Int64(samples)
        audioFrame.position = corePacket.pos
        audioFrame.size = corePacket.size
        completionHandler(.success(audioFrame))
    }

    func doFlushCodec() {
        thd_decoder_reset(decoder)
        renderer.reset()
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
        guard elements != reportedElements else { return }
        reportedElements = elements
        let info = "TrueHD Atmos → 7.1.4 PCM · \(elements) elements"
        KSLog("[atmos] \(info)")
        let assetTrack = assetTrack
        DispatchQueue.main.async {
            assetTrack.passthroughInfo = info
        }
    }

    private static func updates(_ frame: UnsafeMutablePointer<ThdFrame>) -> [AtmosObjectRenderer.Update] {
        let count = Int(frame.pointee.update_count)
        guard count > 0 else { return [] }
        let base = UnsafeRawPointer(frame).advanced(by: MemoryLayout<ThdFrame>.offset(of: \ThdFrame.updates)!)
            .assumingMemoryBound(to: ThdUpdate.self)
        let elementsOffset = MemoryLayout<ThdUpdate>.offset(of: \ThdUpdate.elements)!
        return (0 ..< min(count, Int(THD_MAX_UPDATES))).map { index in
            let update = base + index
            let elements = UnsafeRawPointer(update).advanced(by: elementsOffset).assumingMemoryBound(to: ThdElement.self)
            let elementCount = min(Int(update.pointee.element_count), Int(THD_MAX_ELEMENTS))
            return AtmosObjectRenderer.Update(
                sampleOffset: Int(update.pointee.sample_offset),
                ramp: Int(update.pointee.ramp),
                elements: (0 ..< elementCount).map { i in
                    let e = elements[i]
                    return AtmosObjectRenderer.Element(
                        isBed: e.is_bed == 1, speaker: Int(e.speaker), active: e.active == 1,
                        snap: e.snap == 1, elevation: e.elevation == 1, zones: Int(e.zones),
                        x: e.x, y: e.y, z: e.z, size: e.size, gain: e.gain
                    )
                }
            )
        }
    }
}
#endif
