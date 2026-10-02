#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app='build/device/Build/Products/Release-iphoneos/AudioRelayLab.app'
test -d "$app"
test -f "$app/AudioRelayLab"
test -f "$app/Info.plist"
test -f "$app/Assets.car"
architectures="$(lipo -archs "$app/AudioRelayLab")"
printf '真机可执行架构：%s\n' "$architectures"
[[ " $architectures " == *' arm64 '* ]]
if codesign --verify "$app" >build-codesign.log 2>&1; then
  echo '错误：产物已签名，拒绝将其标记为 unsigned IPA。'
  exit 1
fi
test ! -e "$app/embedded.mobileprovision"
mkdir -p dist/Payload
cp -R "$app" dist/Payload/
(
  cd dist
  /usr/bin/zip -qry AudioRelayLab-unsigned.ipa Payload
  unzip -l AudioRelayLab-unsigned.ipa
)
python3 scripts/verify_ipa.py dist/AudioRelayLab-unsigned.ipa --manifest dist/ipa-manifest.json
