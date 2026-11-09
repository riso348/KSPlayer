//
//  PassthroughDecode.swift
//  KSPlayer (RMDB fork)
//
//  "Decoders" that don't decode: they wrap demuxed packets into compressed
//  CMSampleBuffers for the system renderers. Our own decode path drops what
//  only Apple's pipeline can deliver on Apple TV:
//  - Dolby Vision: VideoToolbox + Metal shows the HDR10 base layer; the
//    per-scene RPU is applied only when AVSampleBufferDisplayLayer decodes a
//    Dolby Vision sample itself.
//  - Dolby Atmos: FFmpeg decodes E-AC-3 JOC to channel PCM (objects gone);
//    AVSampleBufferAudioRenderer given the E-AC-3 packets outputs Atmos.
//  Both renderers sit on AudioRendererPlayer's AVSampleBufferRenderSynchronizer.
//

import AVFoundation
import CoreMedia
import FFmpegKit
import Libavcodec

// MARK: - Video

final class PassthroughVideoDecode: DecodeProtocol {
    private let assetTrack: FFmpegAssetTrack
    private let formatDescription: CMFormatDescription
    /// After a flush the layer can only resume from a key frame.
    private var waitingForKeyFrame = true
    /// Profile 7 → 8.1, nil for single-layer profiles.
    private let profile7: DolbyVisionProfile7Converter?
    private let nalLengthSize: Int
    private let codecTag: String
    private var reportedEnhancementLayer: DolbyVisionProfile7Converter.EnhancementLayer?

    init?(assetTrack: FFmpegAssetTrack, options: KSOptions) {
        guard let formatDescription = assetTrack.dolbyVisionFormatDescription(codecType: options.dolbyVisionCodecType) else {
            return nil
        }
        self.assetTrack = assetTrack
        self.formatDescription = formatDescription
        profile7 = assetTrack.isDolbyVisionProfile7 ? DolbyVisionProfile7Converter() : nil
        nalLengthSize = assetTrack.nalLengthSize
        codecTag = options.dolbyVisionCodecType == kCMVideoCodecType_DolbyVisionHEVC ? "dvh1" : "hvc1"
        if let dovi = assetTrack.dovi {
            let profile = profile7 != nil ? "P7.\(dovi.dv_bl_signal_compatibility_id) → 8.1" : "P\(dovi.dv_profile).\(dovi.dv_bl_signal_compatibility_id)"
            assetTrack.passthroughInfo = "Dolby Vision \(profile) · \(codecTag)"
        }
    }

    /// The diagnostics line learns MEL / FEL from the first converted RPU.
    private func reportProfile7() {
        guard let profile7, let layer = profile7.enhancementLayer, layer != reportedEnhancementLayer else { return }
        reportedEnhancementLayer = layer
        let info = "Dolby Vision P7 \(layer.rawValue) → 8.1 · \(codecTag)"
        KSLog("[passthrough] \(info), RPUs converted \(profile7.convertedCount), kept \(profile7.failedCount)")
        let assetTrack = assetTrack
        DispatchQueue.main.async {
            assetTrack.passthroughInfo = info
        }
    }

    func decodeFrame(from packet: Packet, completionHandler: @escaping (Result<MEFrame, Error>) -> Void) {
        guard let corePacket = packet.corePacket?.pointee, let data = corePacket.data, corePacket.size > 0 else {
            return
        }
        let isKeyFrame = packet.isKeyFrame
        var isDiscontinuity = false
        if waitingForKeyFrame {
            guard isKeyFrame else { return }
            waitingForKeyFrame = false
            isDiscontinuity = true
        }
        let timebase = assetTrack.timebase
        let pts = corePacket.pts != Int64.min ? corePacket.pts : corePacket.dts
        guard pts != Int64.min else { return }
        // Matroska carries no DTS; enqueue order is decode order, which is
        // all the layer needs.
        let dts = corePacket.dts != Int64.min ? timebase.cmtime(for: corePacket.dts) : CMTime.invalid
        let duration = corePacket.duration > 0 ? timebase.cmtime(for: corePacket.duration) : CMTime.invalid
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: timebase.cmtime(for: pts), decodeTimeStamp: dts)
        let made: CMSampleBuffer?
        if let profile7 {
            guard var converted = profile7.convertSample(data, size: Int(corePacket.size), nalLengthSize: nalLengthSize) else {
                KSLog("[passthrough] malformed profile 7 sample at pts \(pts), dropped")
                // Later frames may reference it: resume at the next key frame.
                waitingForKeyFrame = true
                return
            }
            made = converted.withUnsafeMutableBufferPointer {
                makeCompressedSampleBuffer(data: $0.baseAddress!, size: $0.count, formatDescription: formatDescription, timing: &timing)
            }
            reportProfile7()
        } else {
            made = makeCompressedSampleBuffer(data: data, size: Int(corePacket.size), formatDescription: formatDescription, timing: &timing)
        }
        guard let sampleBuffer = made else {
            return
        }
        if !isKeyFrame || corePacket.flags & AV_PKT_FLAG_DISCARD != 0 {
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [NSMutableDictionary], let dic = attachments.first {
                if !isKeyFrame {
                    dic[kCMSampleAttachmentKey_NotSync] = true
                    dic[kCMSampleAttachmentKey_DependsOnOthers] = true
                }
                if corePacket.flags & AV_PKT_FLAG_DISCARD != 0 {
                    dic[kCMSampleAttachmentKey_DoNotDisplay] = true
                }
            }
        }
        let frame = VideoVTBFrame(fps: assetTrack.nominalFrameRate, isDovi: true)
        frame.sampleBuffer = sampleBuffer
        frame.isDiscontinuity = isDiscontinuity
        frame.timebase = timebase
        frame.timestamp = pts
        frame.duration = corePacket.duration
        frame.position = corePacket.pos
        frame.size = corePacket.size
        completionHandler(.success(frame))
    }

    func doFlushCodec() {
        waitingForKeyFrame = true
    }

    func shutdown() {}

    func decode() {}
}

extension CMSampleBuffer {
    var isNotSync: Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false) as? [NSDictionary],
              let first = attachments.first
        else { return false }
        return first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
    }
}

extension VideoVTBFrame {
    /// Passthrough: decode the sample (later frames reference it) but don't show it.
    func markDoNotDisplay() {
        guard let sampleBuffer,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [NSMutableDictionary],
              let dic = attachments.first
        else { return }
        dic[kCMSampleAttachmentKey_DoNotDisplay] = true
    }
}

// MARK: - Audio

final class PassthroughAudioDecode: DecodeProtocol {
    private let assetTrack: FFmpegAssetTrack
    private let options: KSOptions
    private var formatDescription: CMAudioFormatDescription?
    /// The stream turned out not to be passthrough-able (checked on the first
    /// packet): decode it like any other track.
    private var fallback: FFmpegDecode?

    init(assetTrack: FFmpegAssetTrack, options: KSOptions) {
        self.assetTrack = assetTrack
        self.options = options
    }

    func decodeFrame(from packet: Packet, completionHandler: @escaping (Result<MEFrame, Error>) -> Void) {
        if let fallback {
            fallback.decodeFrame(from: packet, completionHandler: completionHandler)
            return
        }
        guard let corePacket = packet.corePacket?.pointee, let data = corePacket.data, corePacket.size > 0 else {
            return
        }
        let size = Int(corePacket.size)
        if formatDescription == nil {
            let bytes = [UInt8](UnsafeBufferPointer(start: data, count: size))
            switch EAC3Passthrough.formatDescription(packet: bytes, channelCount: assetTrack.codecpar.ch_layout.nb_channels) {
            case let .success((formatDescription, info)):
                self.formatDescription = formatDescription
                assetTrack.passthroughInfo = info
                KSLog("[passthrough] audio: \(info)")
            case let .failure(reason):
                assetTrack.passthroughInfo = "decoded (\(reason.message))"
                KSLog("[passthrough] audio falls back to decoding: \(reason.message)")
                let decoder = FFmpegDecode(assetTrack: assetTrack, options: options)
                decoder.decode()
                fallback = decoder
                decoder.decodeFrame(from: packet, completionHandler: completionHandler)
                return
            }
        }
        guard let formatDescription, let audioFormat = assetTrack.audioDescriptor?.audioFormat else {
            return
        }
        let timebase = assetTrack.timebase
        let pts = corePacket.pts != Int64.min ? corePacket.pts : corePacket.dts
        guard pts != Int64.min else { return }
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: size, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: size, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &blockBuffer) == noErr,
              let blockBuffer,
              CMBlockBufferReplaceDataBytes(with: data, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: size) == noErr
        else { return }
        var packetDescription = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(size))
        var sampleBuffer: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: formatDescription, sampleCount: 1, presentationTimeStamp: timebase.cmtime(for: pts), packetDescriptions: &packetDescription, sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else {
            KSLog("[passthrough] audio sample buffer failed: \(status)")
            return
        }
        let frame = AudioFrame(dataSize: 0, audioFormat: audioFormat)
        frame.compressedSampleBuffer = sampleBuffer
        frame.timebase = timebase
        frame.timestamp = pts
        frame.duration = corePacket.duration
        frame.position = corePacket.pos
        frame.size = corePacket.size
        frame.numberOfSamples = EAC3Passthrough.samplesPerPacket
        completionHandler(.success(frame))
    }

    func doFlushCodec() {
        fallback?.doFlushCodec()
    }

    func shutdown() {
        fallback?.shutdown()
    }

    func decode() {
        fallback?.decode()
    }
}

func makeCompressedSampleBuffer(data: UnsafeMutablePointer<UInt8>, size: Int, formatDescription: CMFormatDescription, timing: inout CMSampleTimingInfo) -> CMSampleBuffer? {
    // Copied: the packet is freed as soon as this returns, the sample lives
    // on in the layer's queue.
    var blockBuffer: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: size, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: size, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &blockBuffer) == noErr,
          let blockBuffer,
          CMBlockBufferReplaceDataBytes(with: data, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: size) == noErr
    else { return nil }
    var sampleSize = size
    var sampleBuffer: CMSampleBuffer?
    let status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: formatDescription, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer)
    return status == noErr ? sampleBuffer : nil
}

// MARK: - E-AC-3 bitstream

/// Builds the format description AVFoundation uses for an E-AC-3 MP4 track
/// ('ec-3', magic cookie = the whole "dec3" box), parsed from the frame
/// headers of the first packet. The "dec3" JOC extension is what tells the
/// system the stream carries Atmos.
enum EAC3Passthrough {
    static let samplesPerPacket: UInt32 = 1536

    struct Failure: Error {
        let message: String
    }

    struct SyncFrame {
        /// 0 independent, 1 dependent, 2 converted from AC-3
        var streamType = 0
        var substreamID = 0
        var frameSize = 0
        var sampleRateCode = 0
        var blocks = 6
        var channelMode = 0
        var lfe = 0
        var bitstreamID = 0
        var bitstreamMode = 0
        var channelMap: Int?
        var isAtmos = false
        var atmosComplexity = 0
    }

    static func formatDescription(packet: [UInt8], channelCount: Int32) -> Result<(CMAudioFormatDescription, String), Failure> {
        var frames = [SyncFrame]()
        var offset = 0
        while offset + 6 <= packet.count {
            guard let frame = parse(Array(packet[offset ..< min(packet.count, offset + 128)])) else {
                break
            }
            frames.append(frame)
            offset += frame.frameSize
        }
        guard let main = frames.first(where: { $0.streamType != 1 && $0.substreamID == 0 }) else {
            return .failure(Failure(message: "no E-AC-3 frame header"))
        }
        let independent = frames.filter { $0.streamType != 1 && $0.substreamID == 0 }
        let samples = independent.reduce(0) { $0 + $1.blocks * 256 }
        guard samples == Int(samplesPerPacket) else {
            return .failure(Failure(message: "\(samples) samples per packet"))
        }
        guard main.sampleRateCode < 3 else {
            return .failure(Failure(message: "reduced sample rate"))
        }
        let sampleRate = [48000, 44100, 32000][main.sampleRateCode]
        let dependent = frames.filter { $0.streamType == 1 }
        let totalBytes = frames.reduce(0) { $0 + $1.frameSize }
        let dataRate = totalBytes * 8 * sampleRate / Int(samplesPerPacket) / 1000

        // "dec3" (ETSI TS 102 366 Annex F), same fields FFmpeg's mp4 muxer writes.
        var writer = BitWriter()
        writer.write(dataRate, bits: 13)
        writer.write(0, bits: 3) // num_ind_sub - 1: only the first independent substream
        writer.write(main.sampleRateCode, bits: 2)
        writer.write(main.bitstreamID, bits: 5)
        writer.write(0, bits: 1) // reserved
        writer.write(0, bits: 1) // asvc
        writer.write(main.bitstreamMode, bits: 3)
        writer.write(main.channelMode, bits: 3)
        writer.write(main.lfe, bits: 1)
        writer.write(0, bits: 3) // reserved
        writer.write(dependent.count, bits: 4)
        if dependent.isEmpty {
            writer.write(0, bits: 1)
        } else {
            var location = 0
            for frame in dependent {
                if let map = frame.channelMap {
                    location |= (map >> 5) & 0x1F
                } else {
                    location |= frame.channelMode
                }
            }
            writer.write(location, bits: 9)
        }
        if main.isAtmos {
            writer.write(0, bits: 7)
            writer.write(1, bits: 1) // flag_ec3_extension_type_a
            writer.write(main.atmosComplexity, bits: 8)
        }
        let payload = writer.bytes
        var cookie = Data()
        let boxSize = UInt32(8 + payload.count).bigEndian
        withUnsafeBytes(of: boxSize) { cookie.append(contentsOf: $0) }
        cookie.append(contentsOf: Array("dec3".utf8))
        cookie.append(contentsOf: payload)

        let channels = max(UInt32(channelCount), 2)
        var asbd = AudioStreamBasicDescription(mSampleRate: Float64(sampleRate), mFormatID: kAudioFormatEnhancedAC3, mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: samplesPerPacket, mBytesPerFrame: 0, mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
        var formatDescription: CMAudioFormatDescription?
        let status = cookie.withUnsafeBytes { raw in
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: raw.count, magicCookie: raw.baseAddress, extensions: nil, formatDescriptionOut: &formatDescription)
        }
        guard status == noErr, let formatDescription else {
            return .failure(Failure(message: "format description \(status)"))
        }
        var info = "E-AC-3 \(channels)ch \(dataRate) kbps"
        if main.isAtmos {
            info += " · Atmos JOC \(main.atmosComplexity)"
        }
        if !dependent.isEmpty {
            info += " · \(dependent.count) dep"
        }
        return .success((formatDescription, info))
    }

    /// Frame header + bitstream info up to "addbsi", where the Atmos (JOC)
    /// flag lives. Field order follows FFmpeg's ff_ac3_parse_header /
    /// ff_eac3_parse_header.
    static func parse(_ bytes: [UInt8]) -> SyncFrame? {
        var reader = BitReader(bytes)
        guard reader.read(16) == 0x0B77 else { return nil }
        var frame = SyncFrame()
        frame.streamType = reader.read(2)
        guard frame.streamType != 3 else { return nil }
        frame.substreamID = reader.read(3)
        frame.frameSize = (reader.read(11) + 1) * 2
        frame.sampleRateCode = reader.read(2)
        var isReducedRate = false
        if frame.sampleRateCode == 3 {
            guard reader.read(2) != 3 else { return nil }
            isReducedRate = true
            frame.blocks = 6
        } else {
            frame.blocks = [1, 2, 3, 6][reader.read(2)]
        }
        frame.channelMode = reader.read(3)
        frame.lfe = reader.read(1)
        frame.bitstreamID = reader.read(5)
        guard frame.bitstreamID > 10, frame.bitstreamID <= 16, frame.frameSize >= 6 else { return nil }
        let programs = frame.channelMode == 0 ? 2 : 1
        for _ in 0 ..< programs {
            reader.skip(5) // dialnorm
            if reader.flag() { reader.skip(8) } // compr
        }
        if frame.streamType == 1, reader.flag() {
            frame.channelMap = reader.read(16)
        }
        // mixing metadata
        if reader.flag() {
            if frame.channelMode > 2 {
                reader.skip(2)
                if frame.channelMode & 1 != 0 { reader.skip(6) }
                if frame.channelMode & 4 != 0 { reader.skip(6) }
            }
            if frame.lfe == 1, reader.flag() { reader.skip(5) }
            if frame.streamType == 0 {
                for _ in 0 ..< programs {
                    if reader.flag() { reader.skip(6) }
                }
                if reader.flag() { reader.skip(6) }
                switch reader.read(2) {
                case 1: reader.skip(5)
                case 2: reader.skip(12)
                case 3: reader.skip((reader.read(5) + 2) * 8)
                default: break
                }
                if frame.channelMode < 2 {
                    for _ in 0 ..< programs {
                        if reader.flag() { reader.skip(14) }
                    }
                }
                if reader.flag() {
                    for _ in 0 ..< frame.blocks {
                        if frame.blocks == 1 || reader.flag() { reader.skip(5) }
                    }
                }
            }
        }
        // informational metadata
        if reader.flag() {
            frame.bitstreamMode = reader.read(3)
            reader.skip(2)
            if frame.channelMode == 2 { reader.skip(4) }
            if frame.channelMode >= 6 { reader.skip(2) }
            for _ in 0 ..< programs {
                if reader.flag() { reader.skip(8) }
            }
            if !isReducedRate { reader.skip(1) }
        }
        if frame.streamType == 0, frame.blocks != 6 { reader.skip(1) }
        if frame.streamType == 2, frame.blocks == 6 || reader.flag() { reader.skip(6) }
        // additional bitstream info: first byte's LSB = flag_ec3_extension_type_a
        if reader.flag() {
            let length = reader.read(6)
            reader.skip(7)
            frame.isAtmos = reader.flag()
            if frame.isAtmos, length >= 1 {
                frame.atmosComplexity = reader.read(8)
            }
        }
        guard !reader.isOverrun else { return nil }
        return frame
    }
}

private struct BitReader {
    private let bytes: [UInt8]
    private var position = 0
    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var isOverrun: Bool { position > bytes.count * 8 }

    mutating func read(_ count: Int) -> Int {
        var value = 0
        for _ in 0 ..< count {
            let index = position >> 3
            let bit = index < bytes.count ? (Int(bytes[index]) >> (7 - (position & 7))) & 1 : 0
            value = value << 1 | bit
            position += 1
        }
        return value
    }

    mutating func skip(_ count: Int) {
        position += count
    }

    mutating func flag() -> Bool {
        read(1) == 1
    }
}

private struct BitWriter {
    private(set) var bytes = [UInt8]()
    private var bitCount = 0

    mutating func write(_ value: Int, bits: Int) {
        for i in stride(from: bits - 1, through: 0, by: -1) {
            if bitCount & 7 == 0 { bytes.append(0) }
            if (value >> i) & 1 == 1 {
                bytes[bytes.count - 1] |= UInt8(0x80 >> (bitCount & 7))
            }
            bitCount += 1
        }
    }
}
