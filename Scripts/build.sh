#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
APP_VERSION=$(tr -d '\n' < "$PROJECT_DIR/VERSION")
BUILD_NUMBER=$(tr -d '\n' < "$PROJECT_DIR/BUILD")
[[ "$APP_VERSION" =~ '^[0-9]+\.[0-9]{2}$' && "$BUILD_NUMBER" =~ '^[0-9]+$' ]] || exit 1
STAGING=$(mktemp -d /private/tmp/gaocipan-build.XXXXXX)
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/搞磁盘.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$PROJECT_DIR/Assets" "$PROJECT_DIR/dist"
SDK=$(xcrun --sdk macosx --show-sdk-path)
if [[ ! -f "$PROJECT_DIR/Assets/AppIcon.icns" || "$PROJECT_DIR/Scripts/MakeIcon.swift" -nt "$PROJECT_DIR/Assets/AppIcon.icns" ]]; then
  xcrun swift -module-cache-path "$STAGING/cache" "$PROJECT_DIR/Scripts/MakeIcon.swift" "$PROJECT_DIR/Assets"
fi
ditto "$PROJECT_DIR/Sources" "$STAGING/Sources"
xcrun swiftc -swift-version 6 -O -target arm64-apple-macos14.0 -sdk "$SDK" -module-cache-path "$STAGING/cache" \
  "$STAGING"/Sources/*.swift -framework AppKit -framework SwiftUI -framework UniformTypeIdentifiers -framework CryptoKit \
  -o "$APP/Contents/MacOS/GaoCiPan"
ditto "$PROJECT_DIR/Resources" "$APP/Contents/Resources"
ditto "$PROJECT_DIR/Docs" "$APP/Contents/Resources/Docs"
cp "$PROJECT_DIR/Assets/AppIcon.icns" "$PROJECT_DIR/Assets/AppIcon.png" "$PROJECT_DIR/LICENSE" "$PROJECT_DIR/使用说明.txt" "$APP/Contents/Resources/"
python3 "$PROJECT_DIR/Scripts/make_plist.py" "$APP/Contents/Info.plist" "$APP_VERSION" "$BUILD_NUMBER"
plutil -lint "$APP/Contents/Info.plist"
SIGN_IDENTITY=${GAOCIPAN_SIGN_IDENTITY:--}
codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp=none --identifier com.gaoseries.GaoCiPan "$APP"
codesign --verify --deep --strict "$APP"
python3 "$PROJECT_DIR/Scripts/make_zip.py" "$APP" "$STAGING/GaoCiPan-$APP_VERSION-macOS-arm64.zip"
mkdir "$STAGING/verify"
python3 - "$PROJECT_DIR" "$STAGING/GaoCiPan-$APP_VERSION-macOS-arm64.zip" "$STAGING/verify/extracted" <<'PY'
import pathlib, sys
sys.path.insert(0, str(pathlib.Path(sys.argv[1])/"Scripts"))
from install import extract_zip
extract_zip(pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]))
PY
python3 "$PROJECT_DIR/Scripts/verify_bundle.py" "$APP" "$STAGING/verify/extracted/搞磁盘.app"
codesign --verify --deep --strict "$STAGING/verify/extracted/搞磁盘.app"
mv "$STAGING/GaoCiPan-$APP_VERSION-macOS-arm64.zip" "$PROJECT_DIR/dist/GaoCiPan-$APP_VERSION-macOS-arm64.zip"
(cd "$PROJECT_DIR/dist" && shasum -a 256 "GaoCiPan-$APP_VERSION-macOS-arm64.zip" > SHA256SUMS)
print "已构建并核验 V$APP_VERSION / build $BUILD_NUMBER；未启动应用。"
