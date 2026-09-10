#!/bin/sh
# Builds the proxy SDL2.dll (DXGI flip-model presentation for the OpenGL frame).
set -e
cd "$(dirname "$0")"
g++ -std=c++17 -O2 -shared -static -static-libgcc -static-libstdc++ -o SDL2.dll shim.cpp SDL2.def \
    -Wl,--enable-stdcall-fixup -ld3d11 -ldxgi -ldxguid -ld2d1 -ldwrite -lopengl32 -lgdi32 -luser32
ls -la SDL2.dll
