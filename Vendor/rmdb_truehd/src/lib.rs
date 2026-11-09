//! C API over the `truehd` crate for KSPlayer (RMDB fork).
//!
//! Feeds TrueHD bytes in (one Matroska packet at a time, any number of
//! access units), hands decoded access units out: the PCM of every element
//! of the Atmos presentation (presentation 3: bed channels and objects) and
//! the object audio metadata updates that arrived with it. Rendering the
//! objects to speakers happens in Swift.
//!
//! Every entry point catches panics: a malformed stream must never take the
//! player down, it just loses audio until the next major sync.

mod render;

use std::collections::VecDeque;
use std::panic::{AssertUnwindSafe, catch_unwind};

use truehd::structs::oamd::{GAIN_MINUS_INFINITY, ObjectAudioMetadataPayload};
use truehd::process::decode::{DecodedAccessUnit, Decoder};
use truehd::process::extract::Extractor;
use truehd::process::parse::Parser;

pub const THD_MAX_SAMPLES: usize = 160;
pub const THD_MAX_ELEMENTS: usize = 16;
pub const THD_MAX_UPDATES: usize = 4;

/// One element of the presentation as of an update.
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct ThdElement {
    /// 1 = bed channel at `speaker`, 0 = object at `x`, `y`, `z`.
    pub is_bed: u8,
    /// Bed speaker: 0 L, 1 R, 2 C, 3 LFE, 4 Lss, 5 Rss, 6 Lrs, 7 Rrs, 8 Lfh,
    /// 9 Rfh, 10 Lts, 11 Rts, 12 Lrh, 13 Rrh, 14 Lw, 15 Rw, 16 LFE2.
    pub speaker: u8,
    pub active: u8,
    pub snap: u8,
    pub elevation: u8,
    /// 0 all, 1 no back, 2 no sides, 3 center back, 4 screen only, 5 surround only.
    pub zones: u8,
    pub reserved: [u8; 2],
    /// Room coordinates: x −1 left … 1 right, y −1 back … 1 front, z 0 floor … 1 ceiling.
    pub x: f32,
    pub y: f32,
    pub z: f32,
    pub size: f32,
    /// Linear gain (0 = −∞ dB).
    pub gain: f32,
}

/// Metadata update: applies `sample_offset` samples into the access unit,
/// reached linearly over `ramp` samples.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct ThdUpdate {
    pub sample_offset: u32,
    pub ramp: u32,
    pub element_count: u32,
    pub elements: [ThdElement; THD_MAX_ELEMENTS],
}

impl Default for ThdUpdate {
    fn default() -> Self {
        Self { sample_offset: 0, ramp: 0, element_count: 0, elements: [ThdElement::default(); THD_MAX_ELEMENTS] }
    }
}

/// One decoded access unit.
#[repr(C)]
pub struct ThdFrame {
    pub sample_rate: u32,
    pub sample_count: u32,
    pub element_count: u32,
    /// Interleaved `[sample][element]`, full scale ±1.
    pub pcm: [f32; THD_MAX_SAMPLES * THD_MAX_ELEMENTS],
    pub update_count: u32,
    pub updates: [ThdUpdate; THD_MAX_UPDATES],
}

/// One decoded access unit, rendered to 7.1.4
/// (kAudioChannelLayoutTag_Atmos_7_1_4 order: L R C LFE Ls Rs Lrs Rrs Ltf Rtf Ltr Rtr).
#[repr(C)]
pub struct ThdRendered {
    pub sample_rate: u32,
    pub sample_count: u32,
    /// Elements (beds + objects) in the presentation.
    pub element_count: u32,
    /// Interleaved `[sample][12]`, full scale ±1.
    pub pcm: [f32; THD_MAX_SAMPLES * render::OUTPUTS],
}

pub struct ThdDecoder {
    renderer: render::Renderer,
    extractor: Extractor,
    parser: Parser,
    decoder: Decoder,
    ready: VecDeque<DecodedAccessUnit>,
    /// After an error: nothing until the next major sync.
    resyncing: bool,
    errors: u64,
}

impl ThdDecoder {
    fn new() -> Self {
        Self {
            renderer: render::Renderer::default(),
            extractor: Extractor::default(),
            parser: Parser::default(),
            decoder: Decoder::default(),
            ready: VecDeque::new(),
            resyncing: false,
            errors: 0,
        }
    }

    fn push(&mut self, data: &[u8]) {
        self.extractor.push_bytes(data);
        while let Some(frame) = self.extractor.next() {
            let Ok(frame) = frame else {
                self.errors += 1;
                continue;
            };
            if self.resyncing && !frame.is_major_sync() {
                continue;
            }
            let access_unit = match self.parser.parse(&frame) {
                Ok(access_unit) => access_unit,
                Err(_) => {
                    self.lose_sync();
                    continue;
                }
            };
            match self.decoder.decode_presentation(&access_unit, 3) {
                Ok(decoded) => {
                    self.resyncing = false;
                    if !decoded.is_duplicate {
                        self.ready.push_back(decoded);
                    }
                }
                Err(_) => self.lose_sync(),
            }
        }
    }

    fn lose_sync(&mut self) {
        self.errors += 1;
        self.parser.reset_for_next_major_sync();
        self.decoder.reset_for_next_major_sync();
        self.resyncing = true;
    }
}

fn element_from(oamd: &ObjectAudioMetadataPayload, index: usize, beds: &[usize]) -> Option<ThdElement> {
    let element = oamd.object_element.as_ref()?;
    let block = element.object_data.get(index)?.first()?;
    let basic = &block.object_basic_info;
    let render = &block.object_render_info;
    let gain = if basic.object_gain == GAIN_MINUS_INFINITY {
        0.0
    } else {
        10f32.powf(basic.object_gain as f32 / 20.0)
    };
    let mut out = ThdElement {
        active: (!block.b_object_not_active) as u8,
        gain,
        ..Default::default()
    };
    if block.b_object_in_bed_or_isf {
        out.is_bed = 1;
        out.speaker = *beds.get(index)? as u8;
    } else {
        // OAMD: x 0 left … 1 right, y 0 front … 1 back. Out: the room
        // coordinates Atmos masters use (x −1 … 1, y −1 back … 1 front).
        out.x = (2.0 * render.pos3d[0] - 1.0) as f32;
        out.y = (1.0 - 2.0 * render.pos3d[1]) as f32;
        out.z = render.pos3d[2] as f32;
        out.size = render.object_size[0] as f32;
        out.snap = render.b_object_snap as u8;
        out.elevation = render.b_enable_elevation as u8;
        out.zones = render.zone_constraints_idx;
    }
    Some(out)
}

fn update_from(oamd: &ObjectAudioMetadataPayload) -> Option<ThdUpdate> {
    let element = oamd.object_element.as_ref()?;
    let info = &element.md_update_info;
    let block = info.block_update_info.first()?;
    let beds: Vec<usize> = oamd
        .program_assignment
        .bed_assignment
        .first()
        .map(|bed| bed.to_index_vec())
        .unwrap_or_default();
    let mut update = ThdUpdate {
        sample_offset: (info.sample_offset as u64 + u64::from(block.block_offset_factor_bits) * 32 + oamd.evo_sample_offset) as u32,
        ramp: u32::from(block.ramp_duration),
        ..Default::default()
    };
    let count = oamd.object_count.min(THD_MAX_ELEMENTS);
    for index in 0..count {
        update.elements[index] = element_from(oamd, index, &beds)?;
    }
    update.element_count = count as u32;
    Some(update)
}

fn fill(decoded: &DecodedAccessUnit, out: &mut ThdFrame) {
    let samples = decoded.sample_length.min(THD_MAX_SAMPLES);
    let elements = decoded.channel_count.min(THD_MAX_ELEMENTS);
    out.sample_rate = decoded.sampling_frequency;
    out.sample_count = samples as u32;
    out.element_count = elements as u32;
    const SCALE: f32 = 1.0 / 8_388_608.0;
    for s in 0..samples {
        for e in 0..elements {
            out.pcm[s * elements + e] = decoded.pcm_data[s][e] as f32 * SCALE;
        }
    }
    out.update_count = 0;
    for oamd in &decoded.oamd {
        if out.update_count as usize == THD_MAX_UPDATES {
            break;
        }
        if let Some(update) = update_from(oamd) {
            out.updates[out.update_count as usize] = update;
            out.update_count += 1;
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn thd_decoder_new() -> *mut ThdDecoder {
    Box::into_raw(Box::new(ThdDecoder::new()))
}

/// # Safety
/// `decoder` comes from `thd_decoder_new` and is not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn thd_decoder_free(decoder: *mut ThdDecoder) {
    if !decoder.is_null() {
        drop(unsafe { Box::from_raw(decoder) });
    }
}

/// Drops all state, e.g. after a seek. Decoding resumes at the next major sync.
///
/// # Safety
/// `decoder` comes from `thd_decoder_new`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn thd_decoder_reset(decoder: *mut ThdDecoder) {
    if let Some(decoder) = unsafe { decoder.as_mut() } {
        let errors = decoder.errors;
        *decoder = ThdDecoder::new();
        decoder.errors = errors;
    }
}

/// Feeds bitstream bytes. Returns the number of decoded access units waiting.
///
/// # Safety
/// `decoder` comes from `thd_decoder_new`; `data` points to `length` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn thd_decoder_push(decoder: *mut ThdDecoder, data: *const u8, length: usize) -> i32 {
    let Some(decoder) = (unsafe { decoder.as_mut() }) else { return -1 };
    if data.is_null() || length == 0 {
        return decoder.ready.len() as i32;
    }
    let bytes = unsafe { std::slice::from_raw_parts(data, length) };
    let result = catch_unwind(AssertUnwindSafe(|| decoder.push(bytes)));
    if result.is_err() {
        // A panic leaves the decoder half updated: start over.
        let errors = decoder.errors + 1;
        *decoder = ThdDecoder::new();
        decoder.errors = errors;
        decoder.resyncing = true;
        return -1;
    }
    decoder.ready.len() as i32
}

/// Takes the next decoded access unit. Returns 1 when `out` was filled, 0 when none is waiting.
///
/// # Safety
/// `decoder` comes from `thd_decoder_new`; `out` points to a `ThdFrame`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn thd_decoder_next(decoder: *mut ThdDecoder, out: *mut ThdFrame) -> i32 {
    let (Some(decoder), Some(out)) = (unsafe { decoder.as_mut() }, unsafe { out.as_mut() }) else { return -1 };
    let Some(decoded) = decoder.ready.pop_front() else { return 0 };
    match catch_unwind(AssertUnwindSafe(|| fill(&decoded, out))) {
        Ok(()) => 1,
        Err(_) => -1,
    }
}

/// Takes the next decoded access unit rendered to 7.1.4. Returns 1 when
/// `out` was filled, 0 when none is waiting.
///
/// # Safety
/// `decoder` comes from `thd_decoder_new`; `out` points to a `ThdRendered`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn thd_decoder_next_rendered(decoder: *mut ThdDecoder, out: *mut ThdRendered) -> i32 {
    let (Some(decoder), Some(out)) = (unsafe { decoder.as_mut() }, unsafe { out.as_mut() }) else { return -1 };
    let Some(decoded) = decoder.ready.pop_front() else { return 0 };
    let result = catch_unwind(AssertUnwindSafe(|| {
        let samples = decoded.sample_length.min(THD_MAX_SAMPLES);
        let elements = decoded.channel_count.min(THD_MAX_ELEMENTS);
        let mut input = vec![0f32; samples * elements];
        const SCALE: f32 = 1.0 / 8_388_608.0;
        for s in 0..samples {
            for e in 0..elements {
                input[s * elements + e] = decoded.pcm_data[s][e] as f32 * SCALE;
            }
        }
        let updates = decoded
            .oamd
            .iter()
            .filter_map(update_from)
            .map(|update| render::Update {
                sample_offset: i64::from(update.sample_offset),
                ramp: update.ramp as usize,
                elements: update.elements[..update.element_count as usize].to_vec(),
            })
            .collect();
        decoder.renderer.render(&input, elements, samples, updates, &mut out.pcm);
        out.sample_rate = decoded.sampling_frequency;
        out.sample_count = samples as u32;
        out.element_count = elements as u32;
    }));
    match result {
        Ok(()) => 1,
        Err(_) => -1,
    }
}

/// Bitstream errors so far (extraction, parse and decode), for diagnostics.
///
/// # Safety
/// `decoder` comes from `thd_decoder_new`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn thd_decoder_error_count(decoder: *const ThdDecoder) -> u64 {
    unsafe { decoder.as_ref() }.map_or(0, |decoder| decoder.errors)
}
