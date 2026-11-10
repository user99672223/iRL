#!/usr/bin/env bash
# iRL's lean build (decision D5): only the runtime pieces Rocket League needs, built with
# Madeira's per-component scripts where they fit, and iRL's own app around them.
#
#   tools/build/irl-build.sh <stage> [<stage> ...]
#
# Stages (CI runs them as separate jobs; locally run them in this order):
#   deps       Homebrew tools
#   llvm       LLVM 15 for iOS (DXMT's runtime shader conversion)        -> madeira/toolchains/llvm-ios-build
#   fex        FEX from the fex/ submodule (irl-fex-aot): FEXCore for iOS (linked by the app),
#              xtajit64.dll and FEXOfflineCompiler.exe (ARM64EC)           -> fex/build-ios, build/fex-pe
#   native     Wine host tools, wineserver, ntdll/win32u unix sides (no FFmpeg, no Vulkan),
#              GnuTLS, FreeType, DXMT's iOS side                         -> madeira/app/Madeira/lib*.a
#   windows    Wine ARM64EC PE modules + ntdll, DXMT d3d11/dxgi/d3d10core/winemetal,
#              faultrep, wineios.drv                                      -> madeira/app/Madeira/arm64ec-windows
#   vcruntime  Microsoft's VC++ x64 runtime DLLs                          -> madeira/app/Madeira/x86_64-vcruntime
#   app        xcodegen + xcodebuild + IPA                                -> dist/iRL.ipa
#
# Dropped (see tools/build/components.md): i386/WoW64, aarch64 DLL farm, Madeira Dock/Steam,
# rppairing/StikJIT helper, FFmpeg, MoltenVK/zink/Mesa/KosmicKrisp/Vulkan/D3D12, LuaJIT, tftrace.
set -euo pipefail
IRL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
M="$IRL/madeira"
F="$IRL/fex"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc)}"
TC="$M/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"
export ROOT="$M" JOBS
mkdir -p "$IRL/logs"

log() { printf '\n\033[1;34m==> [%s] %s\033[0m\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
# Every step: timestamped, full command line, full output (CLAUDE.md logging rules).
step() {
    local name=$1; shift
    local L="$IRL/logs/build-$name-$(date -u +%Y%m%dT%H%M%SZ).log"
    log "$name: $*"
    { echo "# $(date -Is) $*"; } > "$L"
    if ! "$@" >> "$L" 2>&1; then
        echo "# $(date -Is) FAILED" >> "$L"
        tail -200 "$L" >&2
        die "$name failed (full log: ${L#$IRL/})"
    fi
    echo "# $(date -Is) OK" >> "$L"
}

stage_deps() {
    brew install cmake ninja meson pkg-config autoconf automake libtool bison flex sevenzip llvm xcodegen || true
}

stage_llvm() {
    step llvm "$M/tools/build/build-llvm-ios.sh"
}

fex_patch() {
    # Madeira's own FEX patches (build/fex-patches/*.patch) on the irl-fex-aot tree. Same logic
    # as Madeira's apply.sh, pointed at fex/ (that script hardcodes madeira/FEX).
    local p
    for p in "$M"/build/fex-patches/*.patch; do
        if git -C "$F" apply --reverse --check "$p" 2>/dev/null; then echo "fex-patches: $(basename "$p") already applied"
        elif git -C "$F" apply --check "$p"; then git -C "$F" apply "$p"; echo "fex-patches: applied $(basename "$p")"
        else die "fex-patches: $(basename "$p") does not apply on fex $(git -C "$F" rev-parse --short HEAD)"; fi
    done
}

fex_ios() {
    # Options mirror madeira/tools/build/build-fex-ios.sh (no FEX_IOS_HOST: this is the native
    # library the app links, which uses __APPLE__).
    cmake -S "$F" -B "$F/build-ios" -G Ninja \
        -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR=arm64 -DCMAKE_OSX_SYSROOT=iphoneos \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_TESTING=OFF -DBUILD_FEX_LINUX_TESTS=OFF -DBUILD_THUNKS=OFF -DBUILD_FEXCONFIG=OFF \
        -DBUILD_STEAM_SUPPORT=OFF -DENABLE_FEX_ALLOCATOR=OFF -DENABLE_ASSERTIONS=OFF -DENABLE_LTO=OFF \
        -DENABLE_CCACHE=OFF -DTUNE_CPU=generic -DTUNE_ARCH=generic
    cmake --build "$F/build-ios" --parallel "$JOBS" \
        --target FEXCore FEXCore_Base JemallocLibs fmt cephes_128bit softfloat_3e xxhash
}

fex_arm64ec() {
    # Options mirror madeira/build/fex-arm64ec/build.sh exactly (FEX_IOS_HOST for C, C++ and ASM).
    # FEXOfflineCompiler is built in the same tree with the same options, so the caches it
    # writes are produced by the same FEXCore build that xtajit64.dll runs.
    export PATH="$TC:$PATH"
    cmake -S "$F" -B "$F/build-arm64ec" -G Ninja -DCMAKE_BUILD_TYPE=Release \
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
    cmake --build "$F/build-arm64ec" --parallel "$JOBS" --target arm64ecfex FEXOfflineCompiler
    mkdir -p "$IRL/build/fex-pe"
    cp "$F/build-arm64ec/Bin/libarm64ecfex.dll" "$IRL/build/fex-pe/xtajit64.dll"
    cp "$F/build-arm64ec/Bin/FEXOfflineCompiler.exe" "$IRL/build/fex-pe/FEXOfflineCompiler.exe"
    ls -l "$IRL/build/fex-pe"
}

stage_fex() {
    git -C "$IRL" submodule update --init --recursive --depth 1 fex
    step fex-patch fex_patch
    step fex-ios fex_ios
    step setup-mingw "$M/tools/build/setup-llvm-mingw.sh"
    step fex-arm64ec fex_arm64ec
}

ntdll_lean() {
    python3 "$IRL/tools/build/make_lean_ntdll.py"
    bash "$M/build/ntdll-unix/build-irl.sh"
}

shader_headers() {
    # Madeira's build-shader-headers.sh adds a 5th argument to __metal_atomic_fetch_add_explicit
    # when the Metal toolchain defines __METAL_MEMORY_FLAGS_NONE__ (Xcode 27). Xcode 26.6 defines the
    # macro but its builtin still takes 4 arguments, so probe the builtin itself, and on a 4-argument
    # toolchain mark the source so Madeira's patch leaves the 4-argument call in place.
    local src="$M/dxmt/src/airconv/shaders/air_tessellation.metal" probe
    probe="$(mktemp -d)/p.metal"
    printf '#include <metal_stdlib>\nusing namespace metal;\nkernel void k(device atomic_int *c [[buffer(0)]]) { __metal_atomic_fetch_add_explicit(c, 1, int(memory_order_relaxed), __METAL_MEMORY_SCOPE_DEVICE__, __METAL_MEMORY_FLAGS_NONE__); }\n' > "$probe"
    if xcrun -sdk iphoneos metal -c "$probe" -o "${probe%.metal}.air" 2>/dev/null; then
        echo "Metal toolchain: 5-argument atomic builtin (Madeira's patch applies)"
    else
        echo "Metal toolchain: 4-argument atomic builtin, keeping the 4-argument call"
        python3 - "$src" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
call = "  return __metal_atomic_fetch_add_explicit(out_count, 1, int(memory_order_relaxed), __METAL_MEMORY_SCOPE_THREADGROUP__);\n"
note = "// iRL: this toolchain defines __METAL_MEMORY_FLAGS_NONE__ but its builtin takes 4 arguments\n"
if "#ifdef __METAL_MEMORY_FLAGS_NONE__" in s:
    s = s.replace("#ifdef __METAL_MEMORY_FLAGS_NONE__", "#if 0 " + note.strip(), 1)
elif note not in s:
    assert call in s, "expected atomic call not found"
    s = s.replace(call, note + call, 1)
p.write_text(s)
PY
    fi
    "$M/tools/build/build-shader-headers.sh"
}

stage_native() {
    git -C "$M" submodule update --init --depth 1 wine
    git -C "$M" submodule update --init --recursive --depth 1 dxmt
    # bison 3 first (Wine tools); Homebrew LLVM last, only for llvm-objcopy and friends that Xcode lacks.
    export PATH="$(brew --prefix bison)/bin:$PATH:$(brew --prefix llvm)/bin"
    step setup-mingw "$M/tools/build/setup-llvm-mingw.sh"
    step wine-host "$M/tools/build/build-wine.sh"
    step freetype "$M/tools/build/build-freetype-ios.sh"
    step gnutls "$M/build/gnutls-ios/build.sh"
    step gnutls-sync "$M/tools/build/sync-gnutls-libs.sh"
    step wineserver "$M/build/wineserver/build.sh"
    step ntdll-unix ntdll_lean
    step win32u-unix "$M/build/win32u-unix/build.sh"
    xcodebuild -downloadComponent MetalToolchain >/dev/null 2>&1 || true
    step shader-headers shader_headers
    step dxmt-ios "$M/tools/build/build-dxmt-ios.sh"
}

dxmt_pe_arm64ec() {
    export PATH="$TC:$PATH"
    bash "$M/build/dxmt-patches/apply.sh"
    local W="$M/wine/build-arm64ec" B="$M/dxmt/build-arm64ec" X="$M/wine/build-arm64ec/dxmt-arm64ec.ini"
    sed "s|@GLOBAL_SOURCE_ROOT@|$M|g" "$M/dxmt/build-arm64ec-win.txt" > "$X"
    if [ ! -f "$B/build.ninja" ]; then
        SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" meson setup "$B" "$M/dxmt" \
            --cross-file "$X" --native-file "$M/dxmt/build-osx.txt" --buildtype release \
            -Dwine_build_path="$W" -Dwine_builtin_dll=true -Denable_nvapi=true
    fi
    SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" meson compile -C "$B" -j "$JOBS"
    local m
    for m in d3d11/d3d11.dll dxgi/dxgi.dll d3d10/d3d10core.dll winemetal/winemetal.dll; do
        "$TC/arm64ec-w64-mingw32-strip" --strip-debug -o "$M/app/Madeira/arm64ec-windows/$(basename "$m")" "$B/src/$m"
    done
}

wine_pe_arm64ec() {
    export PATH="$TC:$PATH"
    local modules=() name
    while IFS= read -r name; do [ "$name" = ntdll ] || modules+=("$name"); done \
        < <(python3 "$M/build/windows-runtime/targets.py" arm64ec list)
    [ ${#modules[@]} -gt 0 ] || die 'no ARM64EC Wine modules selected'
    bash "$M/build/wine-pe/build-modules.sh" "${modules[@]}"
    bash "$M/build/wine-pe/build-ntdll.sh"
}

small_pe() {
    export PATH="$TC:$PATH"
    bash "$M/build/faultrep/build.sh"      # RocketLeague.exe imports faultrep.dll
    "$TC/arm64ec-w64-mingw32-clang" -shared -O2 -Wl,--no-insert-timestamp \
        -o "$M/app/Madeira/arm64ec-windows/wineios.drv" "$M/build/wineios-drv/wineios.c"
}

prune_farm() {
    # Madeira's farm carries test programs and modules for paths iRL drops. Anything here that
    # Rocket League turns out to load shows up as c0000135 in the device log.
    local d="$M/app/Madeira/arm64ec-windows" f
    for f in d3d12.dll d3d12core.dll madeira_d3d12.dll dockhost.exe dock-notices.txt tftrace-x64.dll \
             winevulkan.dll vulkan-1.dll winegstreamer.dll d3d9.dll nvapi64.dll; do rm -f "$d/$f"; done
    find "$d" -maxdepth 1 -name '*-x64.exe' -delete
    echo "farm: $(ls "$d" | wc -l | tr -d ' ') files, $(du -sh "$d" | cut -f1)"
}

stage_windows() {
    git -C "$M" submodule update --init --depth 1 wine
    git -C "$M" submodule update --init --recursive --depth 1 dxmt
    # bison 3 first (Wine tools); Homebrew LLVM last, only for llvm-objcopy and friends that Xcode lacks.
    export PATH="$(brew --prefix bison)/bin:$PATH:$(brew --prefix llvm)/bin"
    step setup-mingw "$M/tools/build/setup-llvm-mingw.sh"
    step wine-host "$M/tools/build/build-wine.sh"
    step wine-pe wine_pe_arm64ec
    step dxmt-pe dxmt_pe_arm64ec
    step small-pe small_pe
    step prune-farm prune_farm
}

stage_vcruntime() {
    step vcruntime "$M/tools/build/prepare-vcruntime.sh"
}

stage_app() {
    step app bash "$IRL/tools/build/package-ipa.sh"
}

[ $# -gt 0 ] || { sed -n '2,20p' "$0"; exit 1; }
for s in "$@"; do
    declare -F "stage_$s" >/dev/null || die "unknown stage: $s"
    "stage_$s"
done
