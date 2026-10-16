#!/bin/bash

# Notarize the Release build from build-release.sh and wrap it in a notarized disk image,
# so it opens on other Macs without a Gatekeeper warning.
#
# Usage:
#   xcrun notarytool store-credentials <profile> --apple-id <apple-id> --team-id <team-id>   # once
#   ./scripts/notarize-release.sh <profile>

set -euo pipefail

PROFILE="${1:?usage: $0 <notarytool keychain profile>}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${FLUIDVOICE_DIST_DIR:-${PROJECT_DIR}/dist}"
IDENTITY="${FLUIDVOICE_SIGNING_IDENTITY:-Developer ID Application}"
APP_PATH="${DIST_DIR}/FluidVoice.app"

[ -d "${APP_PATH}" ] || { printf >&2 'No %s; run scripts/build-release.sh first.\n' "${APP_PATH}"; exit 1; }

VERSION="$(defaults read "${APP_PATH}/Contents/Info.plist" CFBundleShortVersionString)"
DMG_PATH="${DIST_DIR}/FluidVoice-${VERSION}.dmg"
WORK_DIR="$(mktemp -d -t fluidvoice-notarize)"
trap 'rm -rf "${WORK_DIR}"' EXIT

echo "Notarizing ${APP_PATH}..."
ditto -c -k --keepParent "${APP_PATH}" "${WORK_DIR}/FluidVoice.zip"
xcrun notarytool submit "${WORK_DIR}/FluidVoice.zip" --keychain-profile "${PROFILE}" --wait
xcrun stapler staple "${APP_PATH}"

echo "Building ${DMG_PATH}..."
mkdir "${WORK_DIR}/image"
ditto "${APP_PATH}" "${WORK_DIR}/image/FluidVoice.app"
ln -s /Applications "${WORK_DIR}/image/Applications"
rm -f "${DMG_PATH}"
hdiutil create -volname FluidVoice -srcfolder "${WORK_DIR}/image" -format UDZO "${DMG_PATH}"
codesign --sign "${IDENTITY}" --timestamp "${DMG_PATH}"
xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${PROFILE}" --wait
xcrun stapler staple "${DMG_PATH}"

spctl --assess --type execute "${APP_PATH}"
spctl --assess --type open --context context:primary-signature "${DMG_PATH}"
echo "Notarized FluidVoice ${VERSION}: ${DMG_PATH}"
