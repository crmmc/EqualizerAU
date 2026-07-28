#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
derived="$root/.build/AdHocPreviewDerivedData"
release_dir="$root/.build/release"
verify_dir="$release_dir/verify"
app="$derived/Build/Products/Release/M1/EqualizerAU.app"
binary="$app/Contents/MacOS/EqualizerAU"
expected_identifier=com.ruimingchen.EqualizerAU
expected_version=${EXPECTED_VERSION:-0.1.0}
expected_build=${EXPECTED_BUILD:-1}
expected_minimum_system=${EXPECTED_MINIMUM_SYSTEM:-14.2}

fail() {
  print -u2 -- "package-adhoc-preview: $1"
  exit 1
}

[[ "$derived" == "$root/.build/"* ]] || fail "unsafe DerivedData path"
[[ "$release_dir" == "$root/.build/"* ]] || fail "unsafe release path"

changes=$(git -C "$root" status --porcelain --untracked-files=all \
  | grep -vE '^\?\? \.codegraph(/|$)' || true)
if [[ -n "$changes" && ${ALLOW_DIRTY:-0} != 1 ]]; then
  print -u2 -- "$changes"
  fail "source tree has uncommitted release inputs; commit them or use ALLOW_DIRTY=1 for local validation"
fi

source_revision=$(git -C "$root" rev-parse HEAD)
[[ -z "$changes" ]] || source_revision+="-dirty"

rm -rf "$derived" "$verify_dir"
mkdir -p "$release_dir"

xcodebuild \
  -project "$root/EqualizerAU.xcodeproj" \
  -scheme EqualizerAUM1 \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  DEVELOPMENT_TEAM= \
  build | tee "$release_dir/xcodebuild.log"

[[ -x "$binary" ]] || fail "Release executable not found"

codesign \
  --force \
  --sign - \
  --options runtime \
  --timestamp=none \
  "$app"

codesign --verify --deep --strict --verbose=2 "$app"
signature=$(codesign -d --verbose=4 "$app" 2>&1)
print -r -- "$signature" | grep -q '^Signature=adhoc$' || fail "signature is not ad-hoc"
print -r -- "$signature" | grep -q '^TeamIdentifier=not set$' || fail "unexpected signing team"
print -r -- "$signature" | grep -Eq '^CodeDirectory .*flags=.*runtime' || fail "Hardened Runtime is missing"

[[ "$(lipo -archs "$binary")" == arm64 ]] || fail "product is not arm64-only"

plist="$app/Contents/Info.plist"
[[ "$(plutil -extract CFBundleIdentifier raw "$plist")" == "$expected_identifier" ]] \
  || fail "unexpected bundle identifier"
[[ "$(plutil -extract CFBundleShortVersionString raw "$plist")" == "$expected_version" ]] \
  || fail "unexpected marketing version"
[[ "$(plutil -extract CFBundleVersion raw "$plist")" == "$expected_build" ]] \
  || fail "unexpected build number"
[[ "$(plutil -extract LSMinimumSystemVersion raw "$plist")" == "$expected_minimum_system" ]] \
  || fail "unexpected minimum system version"

leaked=$(find "$app" \( -name '*.xctest' -o -name '*.dylib' \) -print)
[[ -z "$leaked" ]] || fail "test bundle or unexpected dylib found: $leaked"

while IFS= read -r dependency; do
  [[ "$dependency" == /System/Library/* || "$dependency" == /usr/lib/* ]] \
    || fail "non-system dynamic dependency: $dependency"
done < <(otool -L "$binary" | tail -n +2 | awk '{print $1}')

payload_name="EqualizerAU-${expected_version}-arm64-preview"
payload="$release_dir/$payload_name"
zip_name="$payload_name.zip"
zip_path="$release_dir/$zip_name"

rm -rf "$payload" "$zip_path" "$zip_path.sha256"
mkdir -p "$payload"
ditto "$app" "$payload/EqualizerAU.app"
cp "$root/LICENSE" "$root/THIRD_PARTY_NOTICES.md" "$payload/"
print -r -- "EqualizerAU source revision: $source_revision" > "$payload/SOURCE_COMMIT.txt"

ditto -c -k --sequesterRsrc --keepParent "$payload" "$zip_path"
(
  cd "$release_dir"
  shasum -a 256 "$zip_name" > "$zip_name.sha256"
  shasum -a 256 -c "$zip_name.sha256"
)

mkdir -p "$verify_dir"
ditto -x -k "$zip_path" "$verify_dir"
verified_app="$verify_dir/$payload_name/EqualizerAU.app"
codesign --verify --deep --strict --verbose=2 "$verified_app"
[[ "$(lipo -archs "$verified_app/Contents/MacOS/EqualizerAU")" == arm64 ]] \
  || fail "ZIP round-trip changed architecture"

print -r -- "M7_PREVIEW_PACKAGE=$zip_path"
print -r -- "M7_PREVIEW_SHA256=$zip_path.sha256"
print -r -- "M7_PREVIEW_SOURCE=$source_revision"
