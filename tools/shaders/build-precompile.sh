#!/bin/bash
# Link tools/shaders/dxmt_precompile.cpp against the Linux airconv objects (build-airconv-linux.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/madeira/dxmt"; LLVM="$ROOT/build/llvm15"; OUT="$ROOT/build/airconv"
[ -x "$OUT/airconv" ] || bash "$ROOT/tools/shaders/build-airconv-linux.sh"
OBJS=$(ls "$OUT"/obj/*.o | grep -v airconv_cli.cpp.o)
LIBS=(Passes Target ObjCARCOpts Coroutines ipo Instrumentation Vectorize Linker IRReader AsmParser FrontendOpenMP
      ScalarOpts InstCombine AggressiveInstCombine TransformUtils BitWriter Analysis ProfileData Symbolize
      DebugInfoPDB DebugInfoMSF DebugInfoDWARF Object TextAPI MCParser MC DebugInfoCodeView BitReader Core
      Remarks BitstreamReader BinaryFormat Support Demangle)
clang++ -std=c++20 -O2 -fno-rtti -I"$SRC/src/airconv" -I"$SRC/include" -I"$OUT/gen" -I"$OUT/shim" \
  -include optional -include string -include cstring -c "$ROOT/tools/shaders/dxmt_precompile.cpp" -o "$OUT/dxmt_precompile.o"
clang++ -o "$OUT/dxmt_precompile" "$OUT/dxmt_precompile.o" $OBJS -L"$LLVM/build/lib" \
  -Wl,--start-group $(printf -- '-lLLVM%s ' "${LIBS[@]}") -Wl,--end-group -lpthread -ldl
echo "built $OUT/dxmt_precompile"
