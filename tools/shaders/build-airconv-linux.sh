#!/usr/bin/env bash
# Build DXMT's airconv CLI natively on Debian against a host LLVM 15.0.7 (the version Madeira pins).
#   build/llvm15/{llvm,build}  host LLVM (see logs/shader-llvm15-build-*.log for the exact cmake line)
# Linux-only substitutions, both outside madeira/:
#   * shim/d3dcompiler.h is empty: the CLI only uses D3DDisassemble inside #ifdef __WIN32.
#   * air_msad.h / air_samplepos.h / air_tessellation.h are 1-byte stubs. Those helper modules come from
#     .metal sources that only Apple's metal compiler can build. airconv links them only for shaders that
#     use msad / samplepos / tessellation; for those it prints "Failed to parse air bitcode", and
#     convert.sh rejects the output, so such shaders fall back to DXMT's runtime conversion on the
#     device instead of shipping broken code. Drop real headers into build/airconv/gen to lift this
#     (e.g. from a macOS CI run of tools/build/build-shader-headers.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/madeira/dxmt"; LLVM="$ROOT/build/llvm15"; OUT="$ROOT/build/airconv"
mkdir -p "$OUT/shim" "$OUT/gen" "$OUT/obj"
: > "$OUT/shim/d3dcompiler.h"
for n in air_msad air_samplepos air_tessellation; do
  [ -s "$OUT/gen/$n.h" ] && grep -q "$n\[\] = {$" "$OUT/gen/$n.h" 2>/dev/null && continue
  [ -f "$OUT/gen/$n.real" ] && continue
  printf 'unsigned char %s[] = {0x00};\nunsigned int %s_len = 1;\n' "$n" "$n" > "$OUT/gen/$n.h"
done
FLAGS=(-std=c++20 -O2 -fno-exceptions -funwind-tables -fno-rtti -D_FILE_OFFSET_BITS=64 -D__STDC_CONSTANT_MACROS
       -D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS -Wno-extern-c-compat -include optional -include string -include cstring
       -I"$SRC/include" -I"$SRC/libs" -I"$SRC/src/airconv" -I"$OUT/gen" -I"$OUT/shim" -I"$SRC/include/native/directx" -I"$SRC/include/native/windows"
       -I"$LLVM/llvm/include" -I"$LLVM/build/include")
SRCS=(airconv_context.cpp dxso_compile.cpp ffp_compile.cpp air_type.cpp air_signature.cpp air_operations.cpp
      dxbc_converter.cpp dxbc_converter_gs.cpp dxbc_converter_ts.cpp dxbc_converter_basicblock.cpp
      dxbc_converter_cfg.cpp dxbc_instructions.cpp dxbc_signature.cpp metallib_writer.cpp nt/air_builder.cpp
      nt/dxbc_converter_base.cpp transforms/lower_16bit_texread.cpp airconv_cli.cpp)
# DXBCParser (libs/DXBCParser/meson.build), linked into airconv by DXMT's meson
PARSER=(BlobContainer.cpp DXBCUtils.cpp ShaderBinary.cpp)
OBJS=()
for s in "${SRCS[@]}"; do
  o="$OUT/obj/$(echo "$s" | tr / _).o"; OBJS+=("$o")
  [ "$o" -nt "$SRC/src/airconv/$s" ] && continue
  in="$SRC/src/airconv/$s"
  # LP64 Linux: uint64_t is `unsigned long`, so `0ull` index literals in Create{Extract,Insert}Element are
  # ambiguous between LLVM's uint64_t and Value* overloads. Compile copies with exact-typed literals.
  if grep -q 'Element(.*[0-9]ull)' "$in"; then
    mkdir -p "$OUT/patched/$(dirname "$s")"
    perl -pe 's/(Create(?:Extract|Insert)Element\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*?,\s*)(\d+)ull\)/$1(uint64_t)$2)/g' "$in" > "$OUT/patched/$s"
    in="$OUT/patched/$s"
  fi
  echo "CXX $s"; clang++ "${FLAGS[@]}" -I"$(dirname "$SRC/src/airconv/$s")" -c "$in" -o "$o"
done
for s in "${PARSER[@]}"; do
  o="$OUT/obj/DXBCParser_$s.o"; OBJS+=("$o")
  [ "$o" -nt "$SRC/libs/DXBCParser/$s" ] && continue
  # DXMT builds DXBCParser with exceptions enabled (libs/DXBCParser/meson.build has no -fno-exceptions)
  echo "CXX DXBCParser/$s"; clang++ "${FLAGS[@]/-fno-exceptions/-fexceptions}" -Wno-unknown-pragmas -c "$SRC/libs/DXBCParser/$s" -o "$o"
done
LIBS=(Passes Target ObjCARCOpts Coroutines ipo Instrumentation Vectorize Linker IRReader AsmParser FrontendOpenMP
      ScalarOpts InstCombine AggressiveInstCombine TransformUtils BitWriter Analysis ProfileData Symbolize
      DebugInfoPDB DebugInfoMSF DebugInfoDWARF Object TextAPI MCParser MC DebugInfoCodeView BitReader Core
      Remarks BitstreamReader BinaryFormat Support Demangle)
echo "LD airconv"
clang++ -o "$OUT/airconv" "${OBJS[@]}" -L"$LLVM/build/lib" -Wl,--start-group $(printf -- '-lLLVM%s ' "${LIBS[@]}") -Wl,--end-group -lpthread -ldl
echo "built $OUT/airconv"
