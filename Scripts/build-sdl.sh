#!/bin/bash
# Builds SDL 3 (zlib license) for game controllers only, static, into .build/sdl, which
# Package.swift links: Inquiline reads every controller through it (SDLGamepads), as Steam and
# most emulators do, with its own drivers for PlayStation, Xbox, Switch and their copies, its
# controller database, calibration, rumble and motion sensors. No video, audio or rendering.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
VERSION=3.4.20
SRC=$ROOT/.build/sdl-src
OUT=$ROOT/.build/sdl
export MACOSX_DEPLOYMENT_TARGET=14.0

[ -d "$SRC" ] || git clone -q --depth 1 --branch "release-$VERSION" https://github.com/libsdl-org/SDL.git "$SRC"
rm -rf "$OUT" "$SRC/build"
cmake -S "$SRC" -B "$SRC/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST_LIBRARY=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF -DSDL_INSTALL_DOCS=OFF \
    -DSDL_AUDIO=OFF -DSDL_VIDEO=OFF -DSDL_GPU=OFF -DSDL_RENDER=OFF -DSDL_CAMERA=OFF -DSDL_DIALOG=OFF -DSDL_TRAY=OFF \
    -DSDL_POWER=OFF -DSDL_JOYSTICK=ON -DSDL_HAPTIC=ON -DSDL_HIDAPI=ON -DSDL_SENSOR=ON \
    -DCMAKE_INSTALL_PREFIX="$OUT" >/dev/null
cmake --build "$SRC/build" >/dev/null
cmake --install "$SRC/build" >/dev/null
ls -la "$OUT/lib"
