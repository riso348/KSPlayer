# rmdb_truehd

C API over [`truehd`](https://crates.io/crates/truehd) (Apache-2.0, research
TrueHD decoder by Rainbaby / the truehdd contributors), for KSPlayer's
TrueHD Atmos → 7.1.4 path (`TrueHDAtmosDecode` + `AtmosObjectRenderer`).

- `src/lib.rs` — decoder wrapper: TrueHD bytes in, per access unit the PCM of
  every element of the Atmos presentation (presentation 3) and the object
  audio metadata updates out. PCM is bit-exact with `truehdd decode`.
- `include/` — C header + module map (`import RMDBTrueHD`).
- `build-xcframework.sh` — rebuilds `../RMDBTrueHD.xcframework` (committed, so
  the package builds without Rust).

`truehd` is pinned to an exact version in `Cargo.toml` / `Cargo.lock`; review
its source before bumping it.
