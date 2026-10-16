#!/bin/bash
# Sign with a stable local identity when the Mac has one, so rebuilds keep the same signature.
# Falls back to ad-hoc. Reuses Pager's "Pager Local Signing" identity if present.
set -euo pipefail
bin="${1:?usage: sign.sh <binary>}"
hash="$(security find-identity -p codesigning 2>/dev/null | grep -E '"(Brim|Pager) Local Signing"' | head -1 | awk '{print $2}' || true)"
if [ -n "$hash" ]; then
  codesign -f -s "$hash" -i com.signedadam.brim "$bin" 2>/dev/null || codesign -f -s - "$bin"
else
  codesign -f -s - -i com.signedadam.brim "$bin"
fi
