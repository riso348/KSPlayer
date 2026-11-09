//
//  DolbyVisionProfile7.swift
//  KSPlayer
//
//  Dolby Vision profile 7 (UHD Blu-ray, dual layer) → profile 8.1 for the
//  native AVSampleBufferDisplayLayer path. Apple TV decodes DV profiles 5, 8
//  and 10 only; a profile 7 stream is an HDR10 base layer, an enhancement
//  layer (UNSPEC63 NAL units) and an RPU (UNSPEC62) describing both. Drop
//  the enhancement layer and rewrite the RPU as a single-layer one and the
//  base layer plays as 8.1 with the full dynamic metadata — what Infuse does.
//
//  The RPU rewrite is dovi_tool's conversion mode 2 ("To 8.1"), byte for
//  byte (verified against its test vectors mel_orig → mel_to_81 and
//  fel_orig → fel_to_81):
//    - header: el_spatial_resampling_filter_flag = 0, disable_residual_flag = 1
//    - mapping: NLQ removed, x/y partitions = 1; for FEL the reshaping
//      curves become identity (the curves assume the EL residual is added)
//    - DM: P8.1 YCbCr→RGB / RGB→LMS coefficients, signal_color_space = 0
//    - extension metadata blocks (L1/L2/L5/L6/L8/…) copied as they are
//  Lost in the conversion: the FEL residual (a 12-bit refinement on top of
//  the 10-bit base). MEL carries no residual, so MEL loses nothing.
//

import Foundation

final class DolbyVisionProfile7Converter {
    enum Mode {
        /// dovi_tool mode 2.
        case to81
        /// dovi_tool mode 4 (8.1 keeping the reshaping curves even for FEL).
        case to81PreservingMapping
        /// Parse and write back unchanged — round-trip check for tests.
        case lossless
    }

    enum EnhancementLayer: String {
        case mel = "MEL"
        case fel = "FEL"
    }

    let mode: Mode
    /// From the last RPU that carried mapping data.
    private(set) var enhancementLayer: EnhancementLayer?
    private(set) var convertedCount = 0
    private(set) var failedCount = 0

    init(mode: Mode = .to81) {
        self.mode = mode
    }

    /// One access unit of length-prefixed HEVC NAL units: drops the
    /// enhancement layer and converts the RPU. nil = malformed sample.
    func convertSample(_ data: UnsafePointer<UInt8>, size: Int, nalLengthSize: Int) -> [UInt8]? {
        guard (1 ... 4).contains(nalLengthSize) else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(size)
        func appendLength(_ length: Int) {
            for i in stride(from: nalLengthSize - 1, through: 0, by: -1) {
                out.append(UInt8(truncatingIfNeeded: length >> (8 * i)))
            }
        }
        var offset = 0
        while offset + nalLengthSize <= size {
            var length = 0
            for i in 0 ..< nalLengthSize {
                length = length << 8 | Int(data[offset + i])
            }
            let start = offset + nalLengthSize
            guard length >= 2, start + length <= size else { return nil }
            offset = start + length
            let nal = UnsafeBufferPointer(start: data + start, count: length)
            switch (nal[0] >> 1) & 0x3F {
            case 63:
                // Enhancement layer.
                continue
            case 62:
                if let rpu = convertRPUNAL(nal), nalLengthSize == 4 || rpu.count < 1 << (8 * nalLengthSize) {
                    appendLength(rpu.count)
                    out += rpu
                    continue
                }
                // Not convertible: keep the original rather than leave the
                // frame without dynamic metadata.
                fallthrough
            default:
                appendLength(length)
                out += nal
            }
        }
        guard offset == size else { return nil }
        return out
    }

    /// UNSPEC62 NAL unit (2-byte NAL header, emulation prevention bytes in
    /// place) → the converted NAL unit, or nil to keep the original.
    func convertRPUNAL(_ nal: UnsafeBufferPointer<UInt8>) -> [UInt8]? {
        guard nal.count > 3 else { return nil }
        let payload = Self.removeEmulationPrevention(nal[2...])
        guard let converted = convertRPU(payload) else {
            failedCount += 1
            return nil
        }
        convertedCount += 1
        var out = [nal[0], nal[1]]
        out += Self.addEmulationPrevention(converted)
        return out
    }

    /// RPU payload without emulation prevention bytes, starting with the
    /// 0x19 prefix. nil when it is not a valid profile 7 RPU (or, in a
    /// conversion mode, not profile 7 at all).
    func convertRPU(_ data: [UInt8]) -> [UInt8]? {
        do {
            return try rewrite(data)
        } catch {
            return nil
        }
    }

    // MARK: - RPU

    private struct InvalidRPU: Error {}

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func rewrite(_ data: [UInt8]) throws -> [UInt8]? {
        let trailingZeroes = data.reversed().prefix { $0 == 0 }.count
        let end = data.count - trailingZeroes
        // prefix + payload + CRC32 + 0x80
        guard end >= 7, data[0] == 0x19, data[end - 1] == 0x80 else { throw InvalidRPU() }
        let crcStart = end - 5
        let receivedCRC = data[crcStart ..< crcStart + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard Self.crc32(data[1 ..< crcStart]) == receivedCRC else { throw InvalidRPU() }

        var r = BitReader(data, endBit: end * 8)
        var w = BitWriter()
        let convert = mode != .lossless
        _ = try r.read(8)
        w.write(0x19, 8)

        // rpu_data_header
        let rpuType = try r.read(6)
        guard rpuType == 2 else { throw InvalidRPU() }
        let rpuFormat = try r.read(11)
        let vdrRpuProfile = try r.read(4)
        let vdrRpuLevel = try r.read(4)
        let seqInfoPresent = try r.bit()
        // Without sequence info the bit depths aren't known.
        guard seqInfoPresent else { throw InvalidRPU() }
        let chromaResamplingExplicitFilter = try r.bit()
        let coefficientDataType = try r.read(2)
        var coefficientLog2Denom: UInt64 = 0
        if coefficientDataType == 0 {
            coefficientLog2Denom = try r.ue()
        }
        let coefficientLength: Int
        switch coefficientDataType {
        case 0: coefficientLength = Int(coefficientLog2Denom)
        case 1: coefficientLength = 32
        default: throw InvalidRPU()
        }
        guard coefficientLength <= 64 else { throw InvalidRPU() }
        let vdrRpuNormalizedIdc = try r.read(2)
        let blVideoFullRange = try r.bit()
        let hasBitDepths = rpuFormat & 0x700 == 0
        var blBitDepthMinus8: UInt64 = 0
        var elBitDepthMinus8Raw: UInt64 = 0
        var vdrBitDepthMinus8: UInt64 = 0
        var spatialResamplingFilter = false
        var reservedZero3Bits: UInt64 = 0
        var elSpatialResamplingFilter = false
        var disableResidual = false
        if hasBitDepths {
            blBitDepthMinus8 = try r.ue()
            // Upper bits carry ext_mapping_idc.
            elBitDepthMinus8Raw = try r.ue()
            vdrBitDepthMinus8 = try r.ue()
            spatialResamplingFilter = try r.bit()
            reservedZero3Bits = try r.read(3)
            elSpatialResamplingFilter = try r.bit()
            disableResidual = try r.bit()
        }
        let vdrDmMetadataPresent = try r.bit()
        let usePrevVdrRpu = try r.bit()
        var prevVdrRpuId: UInt64 = 0
        if usePrevVdrRpu {
            prevVdrRpuId = try r.ue()
        }
        // dovi_tool's get_dovi_profile()
        let isProfile7 = vdrRpuProfile == 1 && elSpatialResamplingFilter && !disableResidual && vdrBitDepthMinus8 == 4
        if convert, !isProfile7 {
            return nil
        }
        let blBitDepth = Int(blBitDepthMinus8) + 8
        let elBitDepth = Int(elBitDepthMinus8Raw & 0xFF) + 8
        guard blBitDepth <= 16, elBitDepth <= 16 else { throw InvalidRPU() }

        w.write(rpuType, 6)
        w.write(rpuFormat, 11)
        w.write(vdrRpuProfile, 4)
        w.write(vdrRpuLevel, 4)
        w.bit(seqInfoPresent)
        w.bit(chromaResamplingExplicitFilter)
        w.write(coefficientDataType, 2)
        if coefficientDataType == 0 {
            w.ue(coefficientLog2Denom)
        }
        w.write(vdrRpuNormalizedIdc, 2)
        w.bit(blVideoFullRange)
        if hasBitDepths {
            w.ue(blBitDepthMinus8)
            w.ue(elBitDepthMinus8Raw)
            w.ue(vdrBitDepthMinus8)
            w.bit(spatialResamplingFilter)
            w.write(reservedZero3Bits, 3)
            w.bit(convert ? false : elSpatialResamplingFilter)
            w.bit(convert ? true : disableResidual)
        }
        w.bit(vdrDmMetadataPresent)
        w.bit(usePrevVdrRpu)
        if usePrevVdrRpu {
            w.ue(prevVdrRpuId)
        }

        // rpu_data_mapping
        if !usePrevVdrRpu {
            let vdrRpuId = try r.ue()
            let mappingColorSpace = try r.ue()
            let mappingChromaFormatIdc = try r.ue()
            var pivotCounts = [Int]()
            var pivots = [[UInt64]]()
            for _ in 0 ..< 3 {
                let numPivotsMinus2 = try r.ue()
                guard numPivotsMinus2 < 8 else { throw InvalidRPU() }
                let count = Int(numPivotsMinus2) + 2
                pivotCounts.append(count)
                pivots.append(try (0 ..< count).map { _ in try r.read(blBitDepth) })
            }
            let hasNLQ = hasBitDepths && !disableResidual
            var nlqHeader: Range<Int>?
            if hasNLQ {
                let start = r.position
                guard try r.read(3) == 0 else { throw InvalidRPU() } // NLQ_LINEAR_DZ
                _ = try r.read(blBitDepth)
                _ = try r.read(blBitDepth)
                nlqHeader = start ..< r.position
            }
            let numXPartitionsMinus1 = try r.ue()
            let numYPartitionsMinus1 = try r.ue()

            // rpu_data_mapping_param
            let paramsStart = r.position
            for component in 0 ..< 3 {
                for _ in 0 ..< pivotCounts[component] - 1 {
                    switch try r.ue() {
                    case 0: // polynomial
                        let orderMinus1 = try r.ue()
                        guard orderMinus1 <= 1 else { throw InvalidRPU() }
                        if orderMinus1 == 0, try r.bit() {
                            // linear_interp_flag: dovi_tool can't do it either
                            throw InvalidRPU()
                        }
                        for _ in 0 ..< orderMinus1 + 2 {
                            try r.coefficient(dataType: coefficientDataType, length: coefficientLength)
                        }
                    case 1: // MMR
                        let orderMinus1 = try r.read(2)
                        guard orderMinus1 <= 2 else { throw InvalidRPU() }
                        try r.coefficient(dataType: coefficientDataType, length: coefficientLength)
                        for _ in 0 ..< (orderMinus1 + 1) * 7 {
                            try r.coefficient(dataType: coefficientDataType, length: coefficientLength)
                        }
                    default:
                        throw InvalidRPU()
                    }
                }
            }
            let params = paramsStart ..< r.position

            // rpu_data_nlq
            var nlq: Range<Int>?
            if hasNLQ {
                let start = r.position
                var isMEL = true
                for _ in 0 ..< 3 {
                    let offset = try r.read(elBitDepth)
                    let vdrInMaxInt = try coefficientDataType == 0 ? r.ue() : 0
                    let vdrInMax = try r.read(coefficientLength)
                    let slopeInt = try coefficientDataType == 0 ? r.ue() : 0
                    let slope = try r.read(coefficientLength)
                    let thresholdInt = try coefficientDataType == 0 ? r.ue() : 0
                    let threshold = try r.read(coefficientLength)
                    if offset != 0 || vdrInMaxInt != 1 || vdrInMax != 0 || slopeInt != 0 || slope != 0 || thresholdInt != 0 || threshold != 0 {
                        isMEL = false
                    }
                }
                nlq = start ..< r.position
                enhancementLayer = isMEL ? .mel : .fel
            }

            w.ue(vdrRpuId)
            w.ue(mappingColorSpace)
            w.ue(mappingChromaFormatIdc)
            let identityMapping = mode == .to81 && enhancementLayer == .fel && nlq != nil
            if identityMapping {
                // dovi_tool set_empty_p81_mapping(): one polynomial piece
                // per component, y = x.
                for _ in 0 ..< 3 {
                    w.ue(0)
                    w.write(0, blBitDepth)
                    w.write(1023, blBitDepth)
                }
            } else {
                for component in 0 ..< 3 {
                    w.ue(UInt64(pivotCounts[component] - 2))
                    for pivot in pivots[component] {
                        w.write(pivot, blBitDepth)
                    }
                }
            }
            if !convert, let nlqHeader {
                w.copy(from: r, nlqHeader)
            }
            w.ue(convert ? 0 : numXPartitionsMinus1)
            w.ue(convert ? 0 : numYPartitionsMinus1)
            if identityMapping {
                for _ in 0 ..< 3 {
                    w.ue(0) // polynomial
                    w.ue(0) // poly_order_minus1
                    w.bit(false) // linear_interp_flag
                    for coefficientInt: Int64 in [0, 1] {
                        if coefficientDataType == 0 {
                            w.se(coefficientInt)
                        }
                        w.write(0, coefficientLength)
                    }
                }
            } else {
                w.copy(from: r, params)
            }
            if !convert, let nlq {
                w.copy(from: r, nlq)
            }
        }

        // vdr_dm_data_payload
        if vdrDmMetadataPresent {
            for _ in 0 ..< 3 {
                // affected_dm_metadata_id, current_dm_metadata_id, scene_refresh_flag
                w.ue(try r.ue())
            }
            let compressed = reservedZero3Bits == 1
            if !compressed {
                let fixed = r.position
                // ycc_to_rgb_coef (9×16), ycc_to_rgb_offset (3×32), rgb_to_lms_coef (9×16)
                _ = try r.skip(9 * 16 + 3 * 32 + 9 * 16)
                if convert {
                    for coefficient: Int16 in [9574, 0, 13802, 9574, -1540, -5348, 9574, 17610, 0] {
                        w.write(UInt64(UInt16(bitPattern: coefficient)), 16)
                    }
                    for offset: UInt64 in [16_777_216, 134_217_728, 134_217_728] {
                        w.write(offset, 32)
                    }
                    for coefficient: Int16 in [7222, 8771, 390, 2654, 12430, 1300, 0, 422, 15962] {
                        w.write(UInt64(UInt16(bitPattern: coefficient)), 16)
                    }
                } else {
                    w.copy(from: r, fixed ..< r.position)
                }
                // signal_eotf, signal_eotf_param0/1 (16), signal_eotf_param2 (32), signal_bit_depth (5)
                let signal = r.position
                _ = try r.skip(3 * 16 + 32 + 5)
                w.copy(from: r, signal ..< r.position)
                let signalColorSpace = try r.read(2)
                w.write(convert ? 0 : signalColorSpace, 2)
                // signal_chroma_format (2), signal_full_range_flag (2),
                // source_min_pq, source_max_pq (12), source_diagonal (10)
                let rest = r.position
                _ = try r.skip(2 + 2 + 12 + 12 + 10)
                w.copy(from: r, rest ..< r.position)
            }
            // CM v2.9 extension blocks, then CM v4.0 when there is room for them.
            try copyExtensionBlocks(&r, &w)
            if r.bitsLeft >= 56 {
                try copyExtensionBlocks(&r, &w)
            }
        }

        // rpu_alignment_zero_bit
        while !r.isByteAligned {
            guard try !r.bit() else { throw InvalidRPU() }
        }
        // Unknown data between the payload and the CRC is kept.
        if r.bitsLeft > 40 {
            let start = r.position
            _ = try r.skip(r.bitsLeft - 40)
            w.copy(from: r, start ..< r.position)
        }
        guard r.bitsLeft == 40 else { throw InvalidRPU() }
        w.byteAlign()
        var out = w.bytes
        let crc = Self.crc32(out[1...])
        out += [UInt8(crc >> 24), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc & 0xFF), 0x80]
        out += [UInt8](repeating: 0, count: trailingZeroes)
        return out
    }

    /// num_ext_blocks, dm_alignment_zero_bit, then each block's length,
    /// level and payload (padding included) copied unchanged.
    private func copyExtensionBlocks(_ r: inout BitReader, _ w: inout BitWriter) throws {
        let count = try r.ue()
        guard count <= 255 else { throw InvalidRPU() }
        w.ue(count)
        while !r.isByteAligned {
            guard try !r.bit() else { throw InvalidRPU() }
        }
        w.byteAlign()
        for _ in 0 ..< count {
            let length = try r.ue()
            guard length <= 255 else { throw InvalidRPU() }
            w.ue(length)
            w.write(try r.read(8), 8)
            let start = r.position
            _ = try r.skip(Int(length) * 8)
            w.copy(from: r, start ..< r.position)
        }
    }

    // MARK: - Helpers

    static func removeEmulationPrevention(_ data: some Collection<UInt8>) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(data.count)
        var zeros = 0
        for byte in data {
            if zeros >= 2, byte == 3 {
                zeros = 0
                continue
            }
            zeros = byte == 0 ? zeros + 1 : 0
            out.append(byte)
        }
        return out
    }

    static func addEmulationPrevention(_ data: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(data.count + 8)
        var zeros = 0
        for byte in data {
            if zeros >= 2, byte <= 3 {
                out.append(3)
                zeros = 0
            }
            zeros = byte == 0 ? zeros + 1 : 0
            out.append(byte)
        }
        return out
    }

    private static let crcTable: [UInt32] = (0 ..< 256).map { i in
        var crc = UInt32(i) << 24
        for _ in 0 ..< 8 {
            crc = crc & 0x8000_0000 != 0 ? crc << 1 ^ 0x04C1_1DB7 : crc << 1
        }
        return crc
    }

    /// CRC-32/MPEG-2.
    static func crc32(_ data: some Sequence<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crc << 8 ^ crcTable[Int((crc >> 24) ^ UInt32(byte))]
        }
        return crc
    }
}

private struct BitReader {
    let bytes: [UInt8]
    let endBit: Int
    private(set) var position = 0

    init(_ bytes: [UInt8], endBit: Int) {
        self.bytes = bytes
        self.endBit = endBit
    }

    var bitsLeft: Int { endBit - position }
    var isByteAligned: Bool { position & 7 == 0 }

    mutating func bit() throws -> Bool {
        guard position < endBit else { throw DolbyVisionBitstreamError() }
        let value = bytes[position >> 3] >> (7 - UInt8(position & 7)) & 1
        position += 1
        return value == 1
    }

    mutating func read(_ count: Int) throws -> UInt64 {
        guard count <= 64, count <= bitsLeft else { throw DolbyVisionBitstreamError() }
        var value: UInt64 = 0
        for _ in 0 ..< count {
            value = value << 1 | (try bit() ? 1 : 0)
        }
        return value
    }

    mutating func skip(_ count: Int) throws -> Int {
        guard count >= 0, count <= bitsLeft else { throw DolbyVisionBitstreamError() }
        position += count
        return count
    }

    mutating func ue() throws -> UInt64 {
        var zeros = 0
        while try !bit() {
            zeros += 1
            guard zeros < 64 else { throw DolbyVisionBitstreamError() }
        }
        return (UInt64(1) << zeros) - 1 + (try read(zeros))
    }

    /// One coefficient: an Exp-Golomb integer part (fixed point only) and
    /// a fraction of `length` bits.
    mutating func coefficient(dataType: UInt64, length: Int) throws {
        if dataType == 0 {
            _ = try ue() // se(v) has the same length as ue(v)
        }
        _ = try skip(length)
    }
}

private struct BitWriter {
    private(set) var bytes = [UInt8]()
    private var bitCount = 0

    mutating func bit(_ value: Bool) {
        if bitCount & 7 == 0 {
            bytes.append(0)
        }
        if value {
            bytes[bytes.count - 1] |= 0x80 >> UInt8(bitCount & 7)
        }
        bitCount += 1
    }

    mutating func write(_ value: UInt64, _ count: Int) {
        for i in stride(from: count - 1, through: 0, by: -1) {
            bit(i < 64 && value >> UInt64(i) & 1 == 1)
        }
    }

    mutating func ue(_ value: UInt64) {
        let x = value + 1
        let length = 64 - x.leadingZeroBitCount
        write(0, length - 1)
        write(x, length)
    }

    mutating func se(_ value: Int64) {
        ue(value > 0 ? UInt64(2 * value - 1) : UInt64(-2 * value))
    }

    mutating func byteAlign() {
        while bitCount & 7 != 0 {
            bit(false)
        }
    }

    mutating func copy(from reader: BitReader, _ range: Range<Int>) {
        for position in range {
            bit(reader.bytes[position >> 3] >> (7 - UInt8(position & 7)) & 1 == 1)
        }
    }
}

private struct DolbyVisionBitstreamError: Error {}
