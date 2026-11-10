#!/bin/bash
# Build Madeira's iOS ARM64EC FEX (xtajit64.dll) and FEXOfflineCompiler.exe on the Debian laptop,
# with the same llvm-mingw release and CMake options as madeira/build/fex-arm64ec/build.sh
# (that script is macOS-hosted; only the toolchain host differs). Compile verification + AOT tool.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
V=20260421; N="llvm-mingw-$V-ucrt-ubuntu-22.04-x86_64"
TC="$ROOT/toolchains/$N"
if [ ! -x "$TC/bin/arm64ec-w64-mingw32-clang" ]; then
  mkdir -p "$ROOT/toolchains/dl"
  curl -fL --retry 3 "https://github.com/mstorsjo/llvm-mingw/releases/download/$V/$N.tar.xz" -o "$ROOT/toolchains/dl/$N.tar.xz"
  tar -xJf "$ROOT/toolchains/dl/$N.tar.xz" -C "$ROOT/toolchains" && rm "$ROOT/toolchains/dl/$N.tar.xz"
fi
export PATH="$TC/bin:$PATH"
F="$ROOT/madeira/FEX"; B="$ROOT/build/fex-arm64ec"
bash "$ROOT/madeira/build/fex-patches/apply.sh"
git -C "$F" submodule update --init --recursive --depth 1
cmake -S "$F" -B "$B" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_DISABLE_FIND_PACKAGE_fmt=ON -DCMAKE_DISABLE_FIND_PACKAGE_range-v3=ON \
  -DCMAKE_DISABLE_FIND_PACKAGE_unordered_dense=ON \
  -DCMAKE_TOOLCHAIN_FILE="$F/Data/CMake/toolchain_mingw.cmake" \
  -DMINGW_TRIPLE=arm64ec-w64-mingw32 -DTUNE_CPU=cortex-a78 \
  -DFEX_IOS_HOST_BUILD=ON -DCMAKE_C_FLAGS=-DFEX_IOS_HOST=1 \
  -DCMAKE_CXX_FLAGS=-DFEX_IOS_HOST=1 -DCMAKE_ASM_FLAGS=-DFEX_IOS_HOST=1 \
  -DENABLE_LTO=OFF -DENABLE_FEX_ALLOCATOR=ON -DENABLE_JEMALLOC_GLIBC_ALLOC=ON -DENABLE_OFFLINE_RUNTIME=ON \
  -DBUILD_FEXCONFIG=ON -DENABLE_CLANG_THUNKS=ON -DENABLE_CCACHE=OFF \
  -DBUILD_TESTING=OFF -DBUILD_THUNKS=OFF -DENABLE_ASSERTIONS=OFF \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build "$B" --target arm64ecfex -j"$(nproc)"
cmake --build "$B" --target FEXOfflineCompiler -j"$(nproc)" || echo "FEXOfflineCompiler: build failed (see above)"
ls -l "$B/Bin/"
