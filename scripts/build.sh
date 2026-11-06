#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

configuration="${1:-release}"
architecture="${2:-native}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
if [[ "$configuration" != "release" && "$configuration" != "debug" ]]; then
  echo "Usage: scripts/build.sh [release|debug] [native|universal]" >&2
  exit 2
fi
case "$architecture" in
  native) architectures=("$(uname -m)") ;;
  universal) architectures=(arm64 x86_64) ;;
  *) echo "Architecture must be native or universal." >&2; exit 2 ;;
esac
build_flags=(--disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security -c "$configuration")
app_binaries=()
cli_binaries=()
for arch in "${architectures[@]}"; do
  swift build "${build_flags[@]}" --arch "$arch" --product CleanmossApp
  swift build "${build_flags[@]}" --arch "$arch" --product cleanmoss
  bin_dir="$(swift build "${build_flags[@]}" --arch "$arch" --show-bin-path)"
  app_binaries+=("$bin_dir/CleanmossApp")
  cli_binaries+=("$bin_dir/cleanmoss")
done
app="$PWD/dist/Cleanmoss.app"
mkdir -p "$PWD/dist"
staging_dir="$(mktemp -d "$PWD/dist/.staging.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
staging_app="$staging_dir/Cleanmoss.app"
mkdir -p "$staging_app/Contents/MacOS" "$staging_app/Contents/Resources"
if [[ "$architecture" == "universal" ]]; then
  lipo -create "${app_binaries[@]}" -output "$staging_app/Contents/MacOS/Cleanmoss"
  lipo -create "${cli_binaries[@]}" -output "$staging_dir/cleanmoss"
else
  cp "${app_binaries[0]}" "$staging_app/Contents/MacOS/Cleanmoss"
  cp "${cli_binaries[0]}" "$staging_dir/cleanmoss"
fi
cp packaging/Info.plist "$staging_app/Contents/Info.plist"
swift scripts/make-icon.swift "$staging_app/Contents/Resources/Cleanmoss.icns"
codesign --force --sign - --identifier com.cleanmoss.mac "$staging_app"
codesign --force --sign - --identifier com.cleanmoss.cli "$staging_dir/cleanmoss"
codesign --verify --strict "$staging_app"
codesign --verify --strict "$staging_dir/cleanmoss"
if [[ -e "$app" ]]; then rm -rf "$app"; fi
mv "$staging_app" "$app"
mv "$staging_dir/cleanmoss" "$PWD/dist/cleanmoss"
echo "Built $app"
echo "Install: ./dist/cleanmoss install"
