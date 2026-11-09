//
//  AtmosObjectRenderer.swift
//  KSPlayer (RMDB fork)
//
//  Renders a Dolby Atmos presentation — bed channels plus positioned
//  objects, as decoded from TrueHD — to a fixed 7.1.4 speaker layout.
//  tvOS takes 7.1.4 PCM and delivers it to the receiver over Dolby MAT, so
//  the height channels survive; the usual alternative on Apple TV is
//  TrueHD's 7.1 downmix presentation, which folds the heights into the floor.
//
//  Panner: allocentric ("room") panning in the spirit of ETSI TS 103 448.
//  An object's height splits it between the floor and the ceiling layer;
//  within a layer, depth picks between speaker rows and width between the
//  speakers of a row. Every step is constant-power (sin/cos), so a moving
//  object keeps its loudness. Beds route discretely to their speakers.
//
//  Metadata updates take effect at their sample offset and ramp linearly
//  from the gains in force to the new ones.
//

import Foundation

final class AtmosObjectRenderer {
    /// kAudioChannelLayoutTag_Atmos_7_1_4 order.
    enum Output: Int, CaseIterable {
        case left, right, center, lfe, leftSurround, rightSurround, leftRear, rightRear
        case leftTopFront, rightTopFront, leftTopRear, rightTopRear
    }

    static let outputCount = Output.allCases.count

    struct Element: Equatable {
        var isBed = false
        /// Bed speaker: 0 L, 1 R, 2 C, 3 LFE, 4 Lss, 5 Rss, 6 Lrs, 7 Rrs,
        /// 8 Lfh, 9 Rfh, 10 Lts, 11 Rts, 12 Lrh, 13 Rrh, 14 Lw, 15 Rw, 16 LFE2.
        var speaker = 0
        var active = true
        var snap = false
        var elevation = true
        var zones = 0
        /// x −1 left … 1 right, y −1 back … 1 front, z 0 floor … 1 ceiling.
        var x: Float = 0
        var y: Float = 0
        var z: Float = 0
        var size: Float = 0
        var gain: Float = 1
    }

    struct Update {
        /// Samples from the start of the access unit it came with.
        var sampleOffset: Int
        var ramp: Int
        var elements: [Element]
    }

    private typealias Gains = [Float] // [element * outputCount + output]

    private var current: Gains = []
    private var rampFrom: Gains = []
    private var rampTo: Gains = []
    private var rampLength = 0
    private var rampPosition = 0
    private var elementCount = 0
    /// Updates whose offset lies beyond the access unit they came with.
    private var pending: [Update] = []
    private var lastElements: [Element] = []

    func reset() {
        current = []
        rampFrom = []
        rampTo = []
        rampLength = 0
        rampPosition = 0
        elementCount = 0
        pending = []
        lastElements = []
    }

    /// Renders one access unit.
    /// - Parameters:
    ///   - input: interleaved `[sample][element]`
    ///   - output: interleaved `[sample][Output]`, `samples * outputCount` floats
    func render(input: UnsafePointer<Float>, elements: Int, samples: Int, updates: [Update], output: UnsafeMutablePointer<Float>) {
        if elements != elementCount {
            // New presentation layout: nothing to ramp from.
            elementCount = elements
            current = Gains(repeating: 0, count: elements * Self.outputCount)
            rampLength = 0
            if lastElements.count == elements {
                current = Self.gains(for: lastElements)
            }
        }
        pending += updates
        pending.sort { $0.sampleOffset < $1.sampleOffset }
        output.initialize(repeating: 0, count: samples * Self.outputCount)

        var sample = 0
        while sample < samples {
            // Start every update due at this sample.
            while let next = pending.first, next.sampleOffset <= sample {
                pending.removeFirst()
                start(next)
            }
            // Render up to the next update, constant gains outside ramps.
            let until = min(samples, pending.first?.sampleOffset ?? samples)
            if rampPosition < rampLength {
                let end = min(until, sample + (rampLength - rampPosition))
                for s in sample ..< end {
                    rampPosition += 1
                    let t = Float(rampPosition) / Float(rampLength)
                    for i in 0 ..< current.count {
                        current[i] = rampFrom[i] + (rampTo[i] - rampFrom[i]) * t
                    }
                    mix(input + s * elements, elements: elements, into: output + s * Self.outputCount)
                }
                sample = end
            } else {
                for s in sample ..< until {
                    mix(input + s * elements, elements: elements, into: output + s * Self.outputCount)
                }
                sample = until
            }
        }
        // Offsets of what is left are relative to the next access unit.
        for i in pending.indices {
            pending[i].sampleOffset -= samples
        }
    }

    private func start(_ update: Update) {
        guard update.elements.count == elementCount else { return }
        lastElements = update.elements
        let target = Self.gains(for: update.elements)
        if update.ramp <= 0 || current.allSatisfy({ $0 == 0 }) {
            current = target
            rampLength = 0
            rampPosition = 0
        } else {
            rampFrom = current
            rampTo = target
            rampLength = update.ramp
            rampPosition = 0
        }
    }

    @inline(__always)
    private func mix(_ frame: UnsafePointer<Float>, elements: Int, into out: UnsafeMutablePointer<Float>) {
        current.withUnsafeBufferPointer { gains in
            for e in 0 ..< elements {
                let value = frame[e]
                if value == 0 { continue }
                let row = e * Self.outputCount
                for o in 0 ..< Self.outputCount {
                    out[o] += value * gains[row + o]
                }
            }
        }
    }

    // MARK: - Panning

    private static func gains(for elements: [Element]) -> Gains {
        var out = Gains(repeating: 0, count: elements.count * outputCount)
        for (index, element) in elements.enumerated() {
            let speakers = speakerGains(element)
            for o in 0 ..< outputCount {
                out[index * outputCount + o] = speakers[o]
            }
        }
        return out
    }

    static func speakerGains(_ element: Element) -> [Float] {
        var g = [Float](repeating: 0, count: outputCount)
        guard element.active, element.gain > 0 else { return g }
        if element.isBed {
            for (output, weight) in bedRouting(element.speaker) {
                g[output.rawValue] = weight * element.gain
            }
            return g
        }
        let z = element.elevation ? min(max(element.z, 0), 1) : 0
        if element.snap {
            g[nearestSpeaker(x: element.x, y: element.y, z: z).rawValue] = 1
        } else if element.size > 0.01 {
            // Spread: power average of the point pans around the object.
            let s = min(element.size, 1)
            var power = [Float](repeating: 0, count: outputCount)
            var taps: Float = 0
            for dx in [-s, 0, s] {
                for dy in [-s, 0, s] {
                    for dz in [-s, 0, s] {
                        let p = pointGains(x: element.x + dx, y: element.y + dy, z: z + dz)
                        for o in 0 ..< outputCount {
                            power[o] += p[o] * p[o]
                        }
                        taps += 1
                    }
                }
            }
            for o in 0 ..< outputCount {
                g[o] = (power[o] / taps).squareRoot()
            }
        } else {
            g = pointGains(x: element.x, y: element.y, z: z)
        }
        applyZones(element.zones, to: &g)
        for o in 0 ..< outputCount {
            g[o] *= element.gain
        }
        return g
    }

    /// Constant-power crossfade: (first, second) for t 0 … 1.
    @inline(__always)
    private static func pair(_ t: Float) -> (Float, Float) {
        let angle = min(max(t, 0), 1) * .pi / 2
        return (cos(angle), sin(angle))
    }

    private static func pointGains(x rawX: Float, y rawY: Float, z rawZ: Float) -> [Float] {
        let x = min(max(rawX, -1), 1)
        let y = min(max(rawY, -1), 1)
        let (floor, ceiling) = pair(min(max(rawZ, 0), 1))
        var g = [Float](repeating: 0, count: outputCount)
        func add(_ output: Output, _ weight: Float) {
            g[output.rawValue] += weight
        }
        if floor > 0.0001 {
            // Floor rows: front (y 1: L C R), side (y 0: Ls Rs), rear (y −1: Lrs Rrs).
            func frontRow(_ weight: Float) {
                if x <= 0 {
                    let (l, c) = pair(x + 1)
                    add(.left, weight * l)
                    add(.center, weight * c)
                } else {
                    let (c, r) = pair(x)
                    add(.center, weight * c)
                    add(.right, weight * r)
                }
            }
            func row(_ left: Output, _ right: Output, _ weight: Float) {
                let (l, r) = pair((x + 1) / 2)
                add(left, weight * l)
                add(right, weight * r)
            }
            if y >= 0 {
                let (side, front) = pair(y)
                row(.leftSurround, .rightSurround, floor * side)
                frontRow(floor * front)
            } else {
                let (rear, side) = pair(y + 1)
                row(.leftRear, .rightRear, floor * rear)
                row(.leftSurround, .rightSurround, floor * side)
            }
        }
        if ceiling > 0.0001 {
            // Ceiling rows: top front at y 0.5, top rear at y −0.5.
            let (rear, front) = pair((y + 0.5))
            let (l, r) = pair((x + 1) / 2)
            add(.leftTopFront, ceiling * front * l)
            add(.rightTopFront, ceiling * front * r)
            add(.leftTopRear, ceiling * rear * l)
            add(.rightTopRear, ceiling * rear * r)
        }
        return g
    }

    private static let speakerPositions: [(Output, Float, Float, Float)] = [
        (.left, -1, 1, 0), (.right, 1, 1, 0), (.center, 0, 1, 0),
        (.leftSurround, -1, 0, 0), (.rightSurround, 1, 0, 0),
        (.leftRear, -1, -1, 0), (.rightRear, 1, -1, 0),
        (.leftTopFront, -1, 0.5, 1), (.rightTopFront, 1, 0.5, 1),
        (.leftTopRear, -1, -0.5, 1), (.rightTopRear, 1, -0.5, 1),
    ]

    private static func nearestSpeaker(x: Float, y: Float, z: Float) -> Output {
        speakerPositions.min { a, b in
            let da = (a.1 - x) * (a.1 - x) + (a.2 - y) * (a.2 - y) + (a.3 - z) * (a.3 - z)
            let db = (b.1 - x) * (b.1 - x) + (b.2 - y) * (b.2 - y) + (b.3 - z) * (b.3 - z)
            return da < db
        }?.0 ?? .center
    }

    /// Zone constraints: mute the excluded speakers and keep the power.
    private static func applyZones(_ zones: Int, to g: inout [Float]) {
        let excluded: [Output]
        switch zones {
        case 1: excluded = [.leftRear, .rightRear, .leftTopRear, .rightTopRear] // no back
        case 2: excluded = [.leftSurround, .rightSurround] // no sides
        case 4: excluded = Output.allCases.filter { ![.left, .center, .right].contains($0) } // screen only
        case 5: excluded = [.left, .center, .right, .leftTopFront, .rightTopFront] // surround only
        default: return
        }
        let before = g.reduce(0) { $0 + $1 * $1 }
        var masked = g
        for output in excluded {
            masked[output.rawValue] = 0
        }
        let after = masked.reduce(0) { $0 + $1 * $1 }
        guard after > 0.000001 else { return }
        let scale = (before / after).squareRoot()
        g = masked.map { $0 * scale }
    }

    private static let half: Float = Float(0.5).squareRoot()

    private static func bedRouting(_ speaker: Int) -> [(Output, Float)] {
        switch speaker {
        case 0: [(.left, 1)]
        case 1: [(.right, 1)]
        case 2: [(.center, 1)]
        case 3, 16: [(.lfe, 1)]
        case 4: [(.leftSurround, 1)]
        case 5: [(.rightSurround, 1)]
        case 6: [(.leftRear, 1)]
        case 7: [(.rightRear, 1)]
        case 8: [(.leftTopFront, 1)]
        case 9: [(.rightTopFront, 1)]
        case 10: [(.leftTopFront, half), (.leftTopRear, half)]
        case 11: [(.rightTopFront, half), (.rightTopRear, half)]
        case 12: [(.leftTopRear, 1)]
        case 13: [(.rightTopRear, 1)]
        case 14: [(.left, half), (.leftSurround, half)]
        case 15: [(.right, half), (.rightSurround, half)]
        default: []
        }
    }
}
