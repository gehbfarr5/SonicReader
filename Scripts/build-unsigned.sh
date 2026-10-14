#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
mkdir -p Artifacts
xcodegen generate
xcodebuild -project SonicReader.xcodeproj -scheme SonicReader \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath .build/Device CODE_SIGNING_ALLOWED=NO build \
  > Artifacts/build-device.log 2>&1
staging_root="$(mktemp -d)"
trap 'rm -rf "$staging_root"' EXIT
mkdir -p "$staging_root/Payload"
cp -R .build/Device/Build/Products/Release-iphoneos/SonicReader.app "$staging_root/Payload/"
release_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' .build/Device/Build/Products/Release-iphoneos/SonicReader.app/Info.plist)"
output_ipa="Artifacts/SonicReader-${release_version}-unsigned.ipa"
python3 Scripts/package.py "$staging_root" "$output_ipa"
shasum -a 256 "$output_ipa" > "${output_ipa%.ipa}-SHA256SUMS"
print "Built $output_ipa (requires signing before installation)"
