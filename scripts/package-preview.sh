#!/bin/bash
# Local-only packaging. Never installs, launches, publishes, or changes Keychain ACLs.
set -euo pipefail
umask 022
export COPYFILE_DISABLE=1
app_name='萌生｜JotBloom.app'
package_name='JotBloom-1.0.3-universal.dmg'
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="${1:?Usage: bash scripts/package-preview.sh NEW_ABSOLUTE_OUTPUT_DIRECTORY}"
case "$output_dir" in /*) ;; *) echo 'Output must be an absolute path.' >&2; exit 2;; esac
if [ -e "$output_dir" ]; then echo 'Output already exists; refusing to overwrite.' >&2; exit 2; fi
mkdir -p "$(dirname "$output_dir")"
mkdir "$output_dir"
build_dir="$(mktemp -d /tmp/jotbloom-release-build.XXXXXX)"
stage_dir="$(mktemp -d /tmp/jotbloom-release-stage.XXXXXX)"
mount_dir="$(mktemp -d /tmp/jotbloom-release-mount.XXXXXX)"
mounted=0
cleanup() { if [ "$mounted" -eq 1 ]; then hdiutil detach "$mount_dir" >/dev/null || true; fi; }
trap cleanup EXIT
echo 'Building v1.0.3 (1.0.3 build 1105); does not publish automatically.'
xcodebuild -project "$project_dir/JotBloom.xcodeproj" -scheme JotBloom \
  -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "$build_dir" \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- \
  MARKETING_VERSION=1.0.3 CURRENT_PROJECT_VERSION=1105 build > "$output_dir/build.log" 2>&1
app="$build_dir/Build/Products/Release/$app_name"
codesign --verify --deep --strict --verbose=2 "$app" > "$output_dir/signature.log" 2>&1
lipo -archs "$app/Contents/MacOS/JotBloom" > "$output_dir/architectures.txt"
for arch in arm64 x86_64; do lipo "$app/Contents/MacOS/JotBloom" -verify_arch "$arch"; done
# No resource forks / AppleDouble sidecars from external-volume staging.
COPYFILE_DISABLE=1 ditto --norsrc --noextattr "$app" "$stage_dir/$app_name"
cp "$project_dir/release/INSTALL-preview.txt" "$stage_dir/安装说明.txt"
ln -s /Applications "$stage_dir/Applications"
dmg="$output_dir/$package_name"
hdiutil create -volname 'JotBloom Preview' -srcfolder "$stage_dir" -format UDZO -ov "$dmg" > "$output_dir/dmg-create.log" 2>&1
hdiutil verify "$dmg" > "$output_dir/dmg-verify.log" 2>&1
hdiutil attach "$dmg" -readonly -nobrowse -mountpoint "$mount_dir" > "$output_dir/mount.log" 2>&1
mounted=1
codesign --verify --deep --strict --verbose=2 "$mount_dir/$app_name" > "$output_dir/mounted-signature.log" 2>&1
test "$(readlink "$mount_dir/Applications")" = /Applications
test -f "$mount_dir/安装说明.txt"
cmp "$app/Contents/MacOS/JotBloom" "$mount_dir/$app_name/Contents/MacOS/JotBloom"
cmp "$project_dir/JotBloom/Resources/AppIcon.icns" "$mount_dir/$app_name/Contents/Resources/AppIcon.icns"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleDisplayName' "$mount_dir/$app_name/Contents/Info.plist")" = '萌生｜JotBloom'
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleName' "$mount_dir/$app_name/Contents/Info.plist")" = '萌生｜JotBloom'
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIconFile' "$mount_dir/$app_name/Contents/Info.plist")" = 'AppIcon.icns'
find "$mount_dir" -type f -print > "$output_dir/bundle-inventory.txt"
if [ -n "$(find "$mount_dir/$app_name" -type f \( -name '*.sqlite*' -o -name '*.log' -o -name '.env*' -o -name '._*' \) -print -quit)" ]; then
  echo 'Unexpected development/data file in app bundle.' >&2; exit 1
fi
/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$mount_dir/$app_name/Contents/Info.plist" > "$output_dir/version.txt"
/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$mount_dir/$app_name/Contents/Info.plist" >> "$output_dir/version.txt"
codesign -dv --verbose=4 "$mount_dir/$app_name" > "$output_dir/signing-metadata.txt" 2>&1
hdiutil detach "$mount_dir" > "$output_dir/unmount.log" 2>&1
mounted=0
(cd "$output_dir" && shasum -a 256 "$package_name" > SHA256SUMS.txt)
echo "Preview ready: $dmg"
echo "Build/staging retained for inspection: $build_dir $stage_dir"
echo 'No app was installed/launched. Gatekeeper, upgrade and Keychain acceptance remain pending.'
