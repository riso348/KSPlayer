//! Decodes a .thd file through the C API and compares the PCM with the
//! CAF that `truehdd decode --presentation 3` wrote (24-bit big endian).
use rmdb_truehd::*;
use std::mem::MaybeUninit;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let thd = std::fs::read(&args[1]).unwrap();
    let caf = std::fs::read(&args[2]).unwrap();
    // CAF: 8-byte file header, then chunks (type, i64 size); data chunk starts with a 4-byte edit count.
    let mut pos = 8;
    let mut audio: &[u8] = &[];
    while pos + 12 <= caf.len() {
        let kind = &caf[pos..pos + 4];
        let size = i64::from_be_bytes(caf[pos + 4..pos + 12].try_into().unwrap());
        if kind == b"data" { audio = &caf[pos + 16..]; break; }
        pos += 12 + size as usize;
    }
    let decoder = thd_decoder_new();
    let mut frame: Box<MaybeUninit<ThdFrame>> = Box::new(MaybeUninit::uninit());
    let mut compared = 0usize;
    let mut mismatches = 0usize;
    let mut offset = 0usize;
    let mut first_updates = 0;
    let mut au = 0usize;
    let mut sample_pos = 0u64;
    for chunk in thd.chunks(30_000) {
        unsafe { thd_decoder_push(decoder, chunk.as_ptr(), chunk.len()) };
        while unsafe { thd_decoder_next(decoder, frame.as_mut_ptr()) } == 1 {
            let f = unsafe { frame.assume_init_ref() };
            let n = f.element_count as usize;
            for s in 0..f.sample_count as usize {
                for e in 0..n {
                    let ours = (f.pcm[s * n + e] * 8_388_608.0) as i32;
                    let b = &audio[offset..offset + 3];
                    let theirs = ((i32::from(b[0]) << 24 | i32::from(b[1]) << 16 | i32::from(b[2]) << 8) >> 8) as i32;
                    if ours != theirs { mismatches += 1; }
                    offset += 3;
                    compared += 1;
                }
            }
            for u in 0..f.update_count as usize {
                let up = &f.updates[u];
                if first_updates < 3 {
                    first_updates += 1;
                    println!("AU {au} samplePos {} update +{} ramp {} elements {}", sample_pos + up.sample_offset as u64, up.sample_offset, up.ramp, up.element_count);
                    for e in 0..up.element_count as usize {
                        let el = &up.elements[e];
                        if el.is_bed == 1 { println!("   [{e}] bed speaker {} active {} gain {:.3}", el.speaker, el.active, el.gain); }
                        else { println!("   [{e}] obj pos [{:.3}, {:.3}, {:.3}] size {} gain {:.3} active {}", el.x, el.y, el.z, el.size, el.gain, el.active); }
                    }
                }
            }
            sample_pos += f.sample_count as u64;
            au += 1;
        }
    }
    println!("access units {au}, samples compared {compared}, mismatches {mismatches}, reference samples {}, errors {}", audio.len() / 3, unsafe { thd_decoder_error_count(decoder) });
    unsafe { thd_decoder_free(decoder) };
}
