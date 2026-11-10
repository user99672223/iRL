#!/usr/bin/env bash
# Build iRL.app from app/project.yml and package dist/iRL.ipa (ad-hoc signed with iRL's
# entitlements; Impactor re-signs it with the owner's Apple ID and keeps IML).
#
# The runtime pieces are copied into the bundle after xcodebuild, then the bundle is signed:
#   arm64ec-windows/   Wine's ARM64EC DLL farm + DXMT + faultrep + wineios.drv
#                      + xtajit64.dll and FEXOfflineCompiler.exe (fex/ irl-fex-aot)
#   nls/               Wine code-page tables
#   x86_64-vcruntime/  Microsoft's VC++ x64 runtime (WineProcessBridge links it over Wine's)
# The static FEX code maps (AOT/codemaps/, AOT/manifest.json) are added afterwards on the laptop by
# tools/aot/inject-ipa.sh: they are derived from the game files, which CI never sees.
set -euo pipefail
IRL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
M="$IRL/madeira/app/Madeira"
DERIVED="$IRL/app/DerivedData"
CONFIGURATION="${CONFIGURATION:-Release}"   # Madeira glue keeps its Debug codegen (project.yml)
APP="$DERIVED/Build/Products/$CONFIGURATION-iphoneos/iRL.app"
DIST="$IRL/dist"

required=(
  "$IRL/fex/build-ios/FEXCore/Source/libFEXCore.a"
  "$IRL/build/fex-pe/xtajit64.dll"
  "$IRL/build/fex-pe/FEXOfflineCompiler.exe"
  "$M/libwineserver.a" "$M/libntdll_unix.a" "$M/libwin32u_unix.a" "$M/libdxmt_combined.a"
  "$M/libgnutls.a" "$M/libnettle.a" "$M/libhogweed.a" "$M/libgmp.a"
  "$M/arm64ec-windows/ntdll.dll" "$M/arm64ec-windows/d3d11.dll" "$M/arm64ec-windows/dxgi.dll"
  "$M/arm64ec-windows/winemetal.dll" "$M/arm64ec-windows/faultrep.dll" "$M/arm64ec-windows/wineios.drv"
  "$M/x86_64-vcruntime/vcruntime140.dll"
)
for f in "${required[@]}"; do [[ -s "$f" ]] || { echo "ERROR: missing build output: ${f#$IRL/}" >&2; exit 1; }; done

(cd "$IRL/app" && xcodegen generate --spec project.yml)
rm -rf "$DERIVED" "$DIST/Payload"
mkdir -p "$DIST"
xcodebuild -project "$IRL/app/iRL.xcodeproj" -scheme iRL -configuration "$CONFIGURATION" \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' build
[[ -d "$APP" ]] || { echo "ERROR: xcodebuild succeeded but iRL.app is missing" >&2; exit 1; }
# A shipped app has no debug-dylib split and no preview stub.
if ls "$APP"/*.debug.dylib "$APP"/__preview.dylib >/dev/null 2>&1; then
  ls -l "$APP"/*.dylib >&2; echo "ERROR: debug/preview dylibs in the bundle (ENABLE_DEBUG_DYLIB)" >&2; exit 1
fi
# dSYM for symbolicating device crash logs (uploaded as its own artifact).
DSYM="$DERIVED/Build/Products/$CONFIGURATION-iphoneos/iRL.app.dSYM"
if [[ -d "$DSYM" ]]; then
  mkdir -p "$DIST"; (cd "$(dirname "$DSYM")" && rm -f "$DIST/iRL.app.dSYM.zip" && zip -qry "$DIST/iRL.app.dSYM.zip" iRL.app.dSYM)
  dwarfdump --uuid "$DSYM" | tee "$IRL/logs/ipa-dsym-uuid.txt"
fi

rsync -a --delete "$M/arm64ec-windows/" "$APP/arm64ec-windows/"
cp "$IRL/build/fex-pe/xtajit64.dll" "$IRL/build/fex-pe/FEXOfflineCompiler.exe" "$APP/arm64ec-windows/"
rsync -a "$M/nls/" "$APP/nls/"
rsync -a "$M/x86_64-vcruntime/" "$APP/x86_64-vcruntime/"
mkdir -p "$APP/licenses"
cp "$IRL/madeira/LICENSE" "$APP/licenses/Madeira-LICENSE.txt" 2>/dev/null || true
cp "$IRL/fex/LICENSE" "$APP/licenses/FEX-LICENSE.txt" 2>/dev/null || true

# No symlinks in an IPA.
if find "$APP" -type l | grep -q .; then find "$APP" -type l >&2; echo "ERROR: symlinks in the bundle" >&2; exit 1; fi

codesign --force --sign - --entitlements "$IRL/app/iRL/iRL.entitlements" "$APP"
codesign -d --entitlements - "$APP" | tee "$IRL/logs/ipa-entitlements.txt"

mkdir -p "$DIST/Payload"
ditto "$APP" "$DIST/Payload/iRL.app"
(cd "$DIST" && rm -f iRL.ipa && zip -qry iRL.ipa Payload)
rm -rf "$DIST/Payload"
unzip -tq "$DIST/iRL.ipa"
echo "iRL.ipa: $(du -h "$DIST/iRL.ipa" | cut -f1), $(unzip -l "$DIST/iRL.ipa" | tail -1 | awk '{print $2}') files"
