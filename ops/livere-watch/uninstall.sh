#!/usr/bin/env bash
# livere-watch 제거 (상태/로그는 남김)
set -uo pipefail
LA="$HOME/Library/LaunchAgents"
for p in com.cizion.livere-watch com.cizion.livere-caffeinate; do
  launchctl unload "$LA/$p.plist" 2>/dev/null || true
  rm -f "$LA/$p.plist"
done
echo "✓ livere-watch 중지·제거됨 (상태/로그 ~/.livere-watch 는 유지)."
