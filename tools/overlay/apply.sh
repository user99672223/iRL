#!/usr/bin/env bash
# Apply iRL's changes on top of the pinned Madeira checkout. Idempotent; fails loudly when an
# expected pattern is missing (i.e. the Madeira pin moved and this overlay needs updating).
# Touches only app/build configuration, never FEX source (see REPORT.md, decision D4).
set -euo pipefail
M="${1:-$(cd "$(dirname "$0")/../../madeira" && pwd)}"
echo "# $(date -Is) iRL overlay on $M ($(git -C "$M" rev-parse --short HEAD))"

need() { grep -q "$2" "$1" || { echo "overlay: pattern '$2' not found in $1" >&2; exit 1; }; }

P="$M/app/Madeira.xcodeproj/project.pbxproj"
if ! grep -q "MADEIRA_BUNDLE_IDENTIFIER = io.github.irl;" "$P"; then
  need "$P" "MADEIRA_BUNDLE_IDENTIFIER = com.willfaust.madeora;"
  sed -i.bak 's/MADEIRA_BUNDLE_IDENTIFIER = com.willfaust.madeora;/MADEIRA_BUNDLE_IDENTIFIER = io.github.irl;/' "$P"
fi

I="$M/app/Madeira/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName iRL' "$I"
for k in UIFileSharingEnabled LSSupportsOpeningDocumentsInPlace GCSupportsGameMode; do
  /usr/libexec/PlistBuddy -c "Set :$k true" "$I" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :$k bool true" "$I"
done

# Free Apple IDs cannot carry Extended Virtual Addressing [confirmed]; leaving it in makes the
# re-sign fail or the entitlement silently drop. IML stays (Impactor grants it).
E="$M/app/Madeira/Madeira.entitlements"
/usr/libexec/PlistBuddy -c 'Delete :com.apple.developer.kernel.extended-virtual-addressing' "$E" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.kernel.increased-memory-limit' "$E" >/dev/null

rm -f "$P.bak"
echo "overlay: applied"
