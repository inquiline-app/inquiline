#!/bin/bash
# Builds WebRTC data channels for the phone remote (PhoneRemote): libdatachannel (MPL 2.0) with
# its libjuice and usrsctp, over mbedTLS (Apache 2.0), all static, into .build/webrtc, which
# Package.swift links. No media, no WebSocket: only the data channel, which carries a phone's
# input over UDP and drops a late packet rather than holding the ones after it.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
SRC=$ROOT/.build/webrtc-src
OUT=$ROOT/.build/webrtc
export MACOSX_DEPLOYMENT_TARGET=14.0
mkdir -p "$SRC"

[ -d "$SRC/mbedtls" ] || git clone -q --depth 1 --branch v3.6.8 --recurse-submodules --shallow-submodules \
    https://github.com/Mbed-TLS/mbedtls.git "$SRC/mbedtls"
[ -d "$SRC/libdatachannel" ] || git clone -q --depth 1 --branch v0.24.6 --recurse-submodules --shallow-submodules \
    https://github.com/paullouisageneau/libdatachannel.git "$SRC/libdatachannel"

rm -rf "$OUT" "$SRC/mbedtls/build" "$SRC/libdatachannel/build"
# WebRTC's DTLS negotiates SRTP even for data alone; mbedTLS leaves it out by default.
python3 "$SRC/mbedtls/scripts/config.py" -f "$SRC/mbedtls/include/mbedtls/mbedtls_config.h" set MBEDTLS_SSL_DTLS_SRTP
cmake -S "$SRC/mbedtls" -B "$SRC/mbedtls/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DENABLE_PROGRAMS=OFF -DENABLE_TESTING=OFF -DUSE_SHARED_MBEDTLS_LIBRARY=OFF -DCMAKE_INSTALL_PREFIX="$OUT" >/dev/null
cmake --build "$SRC/mbedtls/build" >/dev/null
cmake --install "$SRC/mbedtls/build" >/dev/null

cmake -S "$SRC/libdatachannel" -B "$SRC/libdatachannel/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DUSE_MBEDTLS=ON -DMbedTLS_ROOT="$OUT" -DCMAKE_PREFIX_PATH="$OUT" \
    -DNO_MEDIA=ON -DNO_WEBSOCKET=ON -DNO_EXAMPLES=ON -DNO_TESTS=ON -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_INSTALL_PREFIX="$OUT" >/dev/null
cmake --build "$SRC/libdatachannel/build" >/dev/null
cmake --install "$SRC/libdatachannel/build" >/dev/null
# The static library's own dependencies, which its install leaves in the build tree.
find "$SRC/libdatachannel/build" -name "libjuice*.a" -o -name "libusrsctp*.a" | while read -r lib; do cp "$lib" "$OUT/lib/"; done
ls "$OUT/lib"
