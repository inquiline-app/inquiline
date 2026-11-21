#!/bin/bash
# Builds the helper's ad blocking engine (Scripts/vm/adblock-engine: Brave's adblock-rust) for
# Android into .build/adblock-engine/libinquiline_adblock.so, which build-notifications-agent.sh
# puts in the helper. Needs rustup's stable toolchain with the aarch64-linux-android target
# (brew install rustup; rustup toolchain install stable --target aarch64-linux-android) and the
# NDK in .build/tools/ndk.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD
NDK=$ROOT/.build/tools/ndk/toolchains/llvm/prebuilt/darwin-x86_64/bin
export RUSTUP_HOME=${RUSTUP_HOME:-$HOME/.rustup} CARGO_HOME=${CARGO_HOME:-$HOME/.cargo}
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER=$NDK/aarch64-linux-android35-clang
export CC_aarch64_linux_android=$NDK/aarch64-linux-android35-clang AR_aarch64_linux_android=$NDK/llvm-ar
# rustup's own toolchain, not Homebrew's Rust, which has no Android target.
TOOLCHAIN=$RUSTUP_HOME/toolchains/stable-aarch64-apple-darwin/bin
export RUSTC=$TOOLCHAIN/rustc
"$TOOLCHAIN/cargo" build --release --target aarch64-linux-android \
    --manifest-path Scripts/vm/adblock-engine/Cargo.toml --target-dir "$ROOT/.build/adblock-engine/target"
cp .build/adblock-engine/target/aarch64-linux-android/release/libinquiline_adblock.so .build/adblock-engine/
ls -la .build/adblock-engine/libinquiline_adblock.so
