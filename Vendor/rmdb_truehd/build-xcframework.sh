#!/bin/bash
# Builds Vendor/RMDBTrueHD.xcframework from this crate (Rust, over the
# `truehd` crate pinned in Cargo.lock). Run after changing src/lib.rs or
# bumping truehd:  ./Vendor/rmdb_truehd/build-xcframework.sh
#
# Needs rustup with: aarch64-apple-ios aarch64-apple-ios-sim
# aarch64-apple-tvos aarch64-apple-tvos-sim aarch64-apple-darwin x86_64-apple-darwin
set -euo pipefail
cd "$(dirname "$0")"
OUT=../RMDBTrueHD.xcframework
BUILD=target/xcframework
rm -rf "$BUILD" "$OUT"
mkdir -p "$BUILD"

build() {
    cargo build --locked --release --lib --target "$1"
}
for target in aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-tvos aarch64-apple-tvos-sim aarch64-apple-darwin x86_64-apple-darwin; do
    build "$target"
done

lib() { echo "target/$1/release/librmdb_truehd.a"; }
stage() {
    mkdir -p "$BUILD/$1"
    cp "$2" "$BUILD/$1/librmdb_truehd.a"
    strip -S "$BUILD/$1/librmdb_truehd.a"
}
stage ios "$(lib aarch64-apple-ios)"
stage tvos "$(lib aarch64-apple-tvos)"
# Simulators: arm64 from Rust + an x86_64 stub (see stub.c) so universal
# simulator builds link.
simulator() { # name rust-target clang-target
    mkdir -p "$BUILD/$1"
    xcrun clang -c -O2 -target "$3" -isysroot "$(xcrun --sdk "$4" --show-sdk-path)" stub.c -o "$BUILD/$1/stub.o"
    libtool -static -o "$BUILD/$1/stub.a" "$BUILD/$1/stub.o"
    lipo -create "$(lib "$2")" "$BUILD/$1/stub.a" -output "$BUILD/$1/librmdb_truehd.a"
    strip -S "$BUILD/$1/librmdb_truehd.a"
}
simulator ios-sim aarch64-apple-ios-sim x86_64-apple-ios13.0-simulator iphonesimulator
simulator tvos-sim aarch64-apple-tvos-sim x86_64-apple-tvos13.0-simulator appletvsimulator
mkdir -p "$BUILD/macos"
lipo -create "$(lib aarch64-apple-darwin)" "$(lib x86_64-apple-darwin)" -output "$BUILD/macos/librmdb_truehd.a"
strip -S "$BUILD/macos/librmdb_truehd.a"

args=()
for platform in ios ios-sim tvos tvos-sim macos; do
    args+=(-library "$BUILD/$platform/librmdb_truehd.a" -headers include)
done
xcodebuild -create-xcframework "${args[@]}" -output "$OUT"
du -sh "$OUT"
