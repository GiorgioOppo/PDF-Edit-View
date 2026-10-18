#!/bin/bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Uso: ./scripts/build-app.sh [--no-sign]

Compila CartaPDF in modalità Release e crea dist/CartaPDF.app.
L'app riceve una firma ad hoc locale; --no-sign omette la firma.
USAGE
}

should_sign=1
for argument in "$@"; do
  case "$argument" in
    --no-sign) should_sign=0 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Opzione sconosciuta: %s\n' "$argument" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'La compilazione richiede macOS e gli strumenti da riga di comando di Xcode.\n' >&2
  exit 1
fi

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"
diff -qr "$repository_root/Resources/PDFAProfiles" "$repository_root/Sources/CartaPDF/Resources/PDFAProfiles"
diff -qr "$repository_root/Resources/PDFFontData" "$repository_root/Sources/CartaPDF/Resources/PDFFontData"

# Respect an explicit toolchain choice. When only Command Line Tools are selected,
# use the installed Xcode for this process if it supplies SwiftUI's macro plugin.
if [[ -z "${DEVELOPER_DIR+x}" ]]; then
  selected_developer_directory="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
  full_xcode_directory="/Applications/Xcode.app/Contents/Developer"
  swiftui_macros="$full_xcode_directory/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib"
  case "$selected_developer_directory" in
    */CommandLineTools)
      if [[ -f "$swiftui_macros" ]]; then
        export DEVELOPER_DIR="$full_xcode_directory"
        printf 'Strumenti Xcode per questa compilazione: %s\n' "$DEVELOPER_DIR"
      fi
      ;;
  esac
fi

mkdir -p "$repository_root/.build/ModuleCache" "$repository_root/.build/cache"
export CLANG_MODULE_CACHE_PATH="$repository_root/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"

xcrun --find swift >/dev/null
xcrun --find swiftc >/dev/null
xcrun --find iconutil >/dev/null

printf 'Compilazione di CartaPDF…\n'
build_options=(--configuration release --scratch-path "$repository_root/.build"
               --cache-path "$repository_root/.build/cache" --manifest-cache local)
xcrun swift build "${build_options[@]}"
binary_directory="$(xcrun swift build "${build_options[@]}" --show-bin-path)"

staging_directory="$(mktemp -d "${TMPDIR:-/tmp}/cartapdf-build.XXXXXX")"
trap 'rm -rf -- "$staging_directory"' EXIT

application="$staging_directory/CartaPDF.app"
resources="$application/Contents/Resources"
mkdir -p "$application/Contents/MacOS" "$resources" "$repository_root/dist"
cp "$binary_directory/CartaPDF" "$application/Contents/MacOS/CartaPDF"
cp "$repository_root/Resources/Info.plist" "$application/Contents/Info.plist"
cp "$repository_root/Resources/CartaPDF.sdef" "$resources/CartaPDF.sdef"
cp "$repository_root/README.md" "$resources/README.md"
cp "$repository_root/LICENSE" "$resources/LICENSE"
cp -R "$repository_root/Resources/PDFAProfiles" "$resources/PDFAProfiles"
cp -R "$repository_root/Resources/PDFFontData" "$resources/PDFFontData"
for swift_resource_bundle in "$binary_directory"/CartaPDF_*.bundle; do
  if [[ -d "$swift_resource_bundle" ]]; then cp -R "$swift_resource_bundle" "$resources/"; fi
done
if [[ -f "$repository_root/Development/FeatureVerification.json" ]]; then
  cp "$repository_root/Development/FeatureVerification.json" "$resources/FeatureVerification.json"
fi
if [[ -d "$binary_directory/Metadata.appintents" ]]; then
  cp -R "$binary_directory/Metadata.appintents" "$resources/Metadata.appintents"
else
  # SwiftPM emits Swift constant values but does not package App Intents metadata
  # for a manually assembled .app. Use Apple's extractor from the same toolchain.
  find "$repository_root/Sources/CartaPDF" -name '*.swift' -type f > "$staging_directory/sources.list"
  find "$repository_root/.build" -path '*/Release/*' -name '*.swiftconstvalues' -type f > "$staging_directory/constants.list"
  toolchain_directory="$(cd -- "$(dirname -- "$(xcrun --find swiftc)")/../.." && pwd)"
  sdk_directory="$(xcrun --sdk macosx --show-sdk-path)"
  xcode_build_version="$(xcodebuild -version | /usr/bin/awk '/Build version/ { print $3 }')"
  xcrun appintentsmetadataprocessor --output "$resources" \
    --toolchain-dir "$toolchain_directory" --module-name CartaPDF --sdk-root "$sdk_directory" \
    --xcode-version "$xcode_build_version" --platform-family macOS --deployment-target 14.0 \
    --target-triple "$(uname -m)-apple-macosx14.0" \
    --source-file-list "$staging_directory/sources.list" --swift-const-vals-list "$staging_directory/constants.list"
fi

printf 'Creazione dell’icona…\n'
xcrun swiftc -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  "$repository_root/Resources/create-icon.swift" -o "$staging_directory/create-icon"
"$staging_directory/create-icon" "$staging_directory/AppIcon.iconset"
xcrun iconutil --convert icns "$staging_directory/AppIcon.iconset" --output "$resources/AppIcon.icns"
/usr/bin/plutil -lint "$application/Contents/Info.plist"

if [[ "$should_sign" -eq 1 ]]; then
  printf 'Firma ad hoc locale…\n'
  # Signing disallows resource forks and Finder attributes. Remove inherited
  # metadata only from the generated staging bundle, leaving sources untouched.
  /usr/bin/xattr -cr "$application"
  /usr/bin/codesign --force --sign - "$application"
  /usr/bin/codesign --verify --strict "$application"
fi

destination="$repository_root/dist/CartaPDF.app"
if [[ -e "$destination" ]]; then
  rm -rf -- "$destination"
fi
mv "$application" "$destination"
printf '\nApp pronta: %s\n' "$destination"
printf 'Avvio: open "%s"\n' "$destination"
