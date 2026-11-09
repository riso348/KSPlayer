//! Renders the Atmos presentation (bed channels + positioned objects) to a
//! fixed 7.1.4 layout, in kAudioChannelLayoutTag_Atmos_7_1_4 order:
//! L R C LFE Ls Rs Lrs Rrs Ltf Rtf Ltr Rtr.
//!
//! Allocentric ("room") panning in the spirit of ETSI TS 103 448: an
//! object's height splits it between the floor and the ceiling layer; within
//! a layer, depth picks between speaker rows and width between the speakers
//! of a row. Every step is a constant-power sin/cos crossfade, so a moving
//! object keeps its loudness. Beds route discretely to their speakers.
//! Metadata updates take effect at their sample offset and ramp linearly
//! from the gains in force.
//!
//! Lives in Rust (not Swift) so it is optimized in every build of the app:
//! a debug build's unoptimized Swift could not keep up in real time.

use crate::ThdElement;

pub const OUTPUTS: usize = 12;

const L: usize = 0;
const R: usize = 1;
const C: usize = 2;
const LFE: usize = 3;
const LS: usize = 4;
const RS: usize = 5;
const LRS: usize = 6;
const RRS: usize = 7;
const LTF: usize = 8;
const RTF: usize = 9;
const LTR: usize = 10;
const RTR: usize = 11;

pub struct Update {
    /// Samples from the start of the access unit it came with.
    pub sample_offset: i64,
    pub ramp: usize,
    pub elements: Vec<ThdElement>,
}

#[derive(Default)]
pub struct Renderer {
    /// `[element * OUTPUTS + output]`
    current: Vec<f32>,
    ramp_from: Vec<f32>,
    ramp_to: Vec<f32>,
    ramp_length: usize,
    ramp_position: usize,
    element_count: usize,
    pending: Vec<Update>,
    last_elements: Vec<ThdElement>,
}

impl Renderer {
    /// `input`: interleaved `[sample][element]`; `output`: interleaved
    /// `[sample][OUTPUTS]`, `samples * OUTPUTS` floats.
    pub fn render(&mut self, input: &[f32], elements: usize, samples: usize, updates: Vec<Update>, output: &mut [f32]) {
        if elements != self.element_count {
            self.element_count = elements;
            self.ramp_length = 0;
            self.current = if self.last_elements.len() == elements {
                gains(&self.last_elements)
            } else {
                vec![0.0; elements * OUTPUTS]
            };
        }
        self.pending.extend(updates);
        self.pending.sort_by_key(|update| update.sample_offset);
        output[..samples * OUTPUTS].fill(0.0);

        let mut sample = 0;
        while sample < samples {
            while self.pending.first().is_some_and(|next| next.sample_offset <= sample as i64) {
                let next = self.pending.remove(0);
                self.start(next);
            }
            let until = self.pending.first().map_or(samples, |next| (next.sample_offset as usize).min(samples));
            if self.ramp_position < self.ramp_length {
                let end = until.min(sample + (self.ramp_length - self.ramp_position));
                for s in sample..end {
                    self.ramp_position += 1;
                    let t = self.ramp_position as f32 / self.ramp_length as f32;
                    for ((current, from), to) in self.current.iter_mut().zip(&self.ramp_from).zip(&self.ramp_to) {
                        *current = from + (to - from) * t;
                    }
                    mix(&self.current, &input[s * elements..(s + 1) * elements], &mut output[s * OUTPUTS..(s + 1) * OUTPUTS]);
                }
                sample = end;
            } else {
                for s in sample..until {
                    mix(&self.current, &input[s * elements..(s + 1) * elements], &mut output[s * OUTPUTS..(s + 1) * OUTPUTS]);
                }
                sample = until;
            }
        }
        // What is left applies to the next access unit.
        for update in &mut self.pending {
            update.sample_offset -= samples as i64;
        }
    }

    fn start(&mut self, update: Update) {
        if update.elements.len() != self.element_count {
            return;
        }
        let target = gains(&update.elements);
        self.last_elements = update.elements;
        if update.ramp == 0 || self.current.iter().all(|&gain| gain == 0.0) {
            self.current = target;
            self.ramp_length = 0;
            self.ramp_position = 0;
        } else {
            self.ramp_from = self.current.clone();
            self.ramp_to = target;
            self.ramp_length = update.ramp;
            self.ramp_position = 0;
        }
    }
}

#[inline(always)]
fn mix(gains: &[f32], frame: &[f32], out: &mut [f32]) {
    for (e, &value) in frame.iter().enumerate() {
        if value == 0.0 {
            continue;
        }
        let row = &gains[e * OUTPUTS..(e + 1) * OUTPUTS];
        for (o, gain) in out.iter_mut().zip(row) {
            *o += value * gain;
        }
    }
}

fn gains(elements: &[ThdElement]) -> Vec<f32> {
    let mut out = Vec::with_capacity(elements.len() * OUTPUTS);
    for element in elements {
        out.extend_from_slice(&speaker_gains(element));
    }
    out
}

pub fn speaker_gains(element: &ThdElement) -> [f32; OUTPUTS] {
    let mut g = [0.0f32; OUTPUTS];
    if element.active == 0 || element.gain <= 0.0 {
        return g;
    }
    if element.is_bed == 1 {
        for &(output, weight) in bed_routing(element.speaker) {
            g[output] = weight * element.gain;
        }
        return g;
    }
    let z = if element.elevation == 1 { element.z.clamp(0.0, 1.0) } else { 0.0 };
    if element.snap == 1 {
        g[nearest_speaker(element.x, element.y, z)] = 1.0;
    } else if element.size > 0.01 {
        // Spread: power average of the point pans around the object.
        let s = element.size.min(1.0);
        let mut power = [0.0f32; OUTPUTS];
        let mut taps = 0.0f32;
        for dx in [-s, 0.0, s] {
            for dy in [-s, 0.0, s] {
                for dz in [-s, 0.0, s] {
                    let p = point_gains(element.x + dx, element.y + dy, z + dz);
                    for o in 0..OUTPUTS {
                        power[o] += p[o] * p[o];
                    }
                    taps += 1.0;
                }
            }
        }
        for o in 0..OUTPUTS {
            g[o] = (power[o] / taps).sqrt();
        }
    } else {
        g = point_gains(element.x, element.y, z);
    }
    apply_zones(element.zones, &mut g);
    for gain in &mut g {
        *gain *= element.gain;
    }
    g
}

/// Constant-power crossfade: (first, second) for t 0 … 1.
#[inline(always)]
fn pair(t: f32) -> (f32, f32) {
    let angle = t.clamp(0.0, 1.0) * std::f32::consts::FRAC_PI_2;
    (angle.cos(), angle.sin())
}

fn point_gains(x: f32, y: f32, z: f32) -> [f32; OUTPUTS] {
    let x = x.clamp(-1.0, 1.0);
    let y = y.clamp(-1.0, 1.0);
    let (floor, ceiling) = pair(z.clamp(0.0, 1.0));
    let mut g = [0.0f32; OUTPUTS];
    if floor > 0.0001 {
        // Floor rows: front (y 1: L C R), side (y 0: Ls Rs), rear (y −1: Lrs Rrs).
        let front_row = |g: &mut [f32; OUTPUTS], weight: f32| {
            if x <= 0.0 {
                let (l, c) = pair(x + 1.0);
                g[L] += weight * l;
                g[C] += weight * c;
            } else {
                let (c, r) = pair(x);
                g[C] += weight * c;
                g[R] += weight * r;
            }
        };
        let row = |g: &mut [f32; OUTPUTS], left: usize, right: usize, weight: f32| {
            let (l, r) = pair((x + 1.0) / 2.0);
            g[left] += weight * l;
            g[right] += weight * r;
        };
        if y >= 0.0 {
            let (side, front) = pair(y);
            row(&mut g, LS, RS, floor * side);
            front_row(&mut g, floor * front);
        } else {
            let (rear, side) = pair(y + 1.0);
            row(&mut g, LRS, RRS, floor * rear);
            row(&mut g, LS, RS, floor * side);
        }
    }
    if ceiling > 0.0001 {
        // Ceiling rows: top front at y 0.5, top rear at y −0.5.
        let (rear, front) = pair(y + 0.5);
        let (l, r) = pair((x + 1.0) / 2.0);
        g[LTF] += ceiling * front * l;
        g[RTF] += ceiling * front * r;
        g[LTR] += ceiling * rear * l;
        g[RTR] += ceiling * rear * r;
    }
    g
}

const SPEAKERS: [(usize, f32, f32, f32); 11] = [
    (L, -1.0, 1.0, 0.0),
    (R, 1.0, 1.0, 0.0),
    (C, 0.0, 1.0, 0.0),
    (LS, -1.0, 0.0, 0.0),
    (RS, 1.0, 0.0, 0.0),
    (LRS, -1.0, -1.0, 0.0),
    (RRS, 1.0, -1.0, 0.0),
    (LTF, -1.0, 0.5, 1.0),
    (RTF, 1.0, 0.5, 1.0),
    (LTR, -1.0, -0.5, 1.0),
    (RTR, 1.0, -0.5, 1.0),
];

fn nearest_speaker(x: f32, y: f32, z: f32) -> usize {
    let distance = |s: &(usize, f32, f32, f32)| (s.1 - x).powi(2) + (s.2 - y).powi(2) + (s.3 - z).powi(2);
    SPEAKERS
        .iter()
        .min_by(|a, b| distance(a).total_cmp(&distance(b)))
        .map_or(C, |s| s.0)
}

/// Zone constraints: mute the excluded speakers and keep the power.
fn apply_zones(zones: u8, g: &mut [f32; OUTPUTS]) {
    let excluded: &[usize] = match zones {
        1 => &[LRS, RRS, LTR, RTR],                    // no back
        2 => &[LS, RS],                                // no sides
        4 => &[LFE, LS, RS, LRS, RRS, LTF, RTF, LTR, RTR], // screen only
        5 => &[L, C, R, LTF, RTF],                     // surround only
        _ => return,
    };
    let before: f32 = g.iter().map(|v| v * v).sum();
    let mut masked = *g;
    for &output in excluded {
        masked[output] = 0.0;
    }
    let after: f32 = masked.iter().map(|v| v * v).sum();
    if after <= 0.000_001 {
        return;
    }
    let scale = (before / after).sqrt();
    for (gain, value) in g.iter_mut().zip(masked) {
        *gain = value * scale;
    }
}

const HALF: f32 = std::f32::consts::FRAC_1_SQRT_2;

fn bed_routing(speaker: u8) -> &'static [(usize, f32)] {
    match speaker {
        0 => &[(L, 1.0)],
        1 => &[(R, 1.0)],
        2 => &[(C, 1.0)],
        3 | 16 => &[(LFE, 1.0)],
        4 => &[(LS, 1.0)],
        5 => &[(RS, 1.0)],
        6 => &[(LRS, 1.0)],
        7 => &[(RRS, 1.0)],
        8 => &[(LTF, 1.0)],
        9 => &[(RTF, 1.0)],
        10 => &[(LTF, HALF), (LTR, HALF)],
        11 => &[(RTF, HALF), (RTR, HALF)],
        12 => &[(LTR, 1.0)],
        13 => &[(RTR, 1.0)],
        14 => &[(L, HALF), (LS, HALF)],
        15 => &[(R, HALF), (RS, HALF)],
        _ => &[],
    }
}
