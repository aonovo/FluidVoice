#!/bin/bash

# Build a Release FluidVoice.app signed with a Developer ID Application certificate,
# ready to copy into /Applications on this Mac. Not notarized.
#
# Usage:
#   ./scripts/build-release.sh                                  # dist/FluidVoice.app
#   FLUIDVOICE_DEVELOPMENT_TEAM=XXXXXXXXXX ./scripts/build-release.sh
#   FLUIDVOICE_SIGNING_IDENTITY="Apple Development" ./scripts/build-release.sh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${FLUIDVOICE_DIST_DIR:-${PROJECT_DIR}/dist}"
DERIVED_DATA_PATH="${FLUIDVOICE_DERIVED_DATA_PATH:-${PROJECT_DIR}/DerivedData}"
IDENTITY="${FLUIDVOICE_SIGNING_IDENTITY:-Developer ID Application}"
ARCHIVE_PATH="${DIST_DIR}/FluidVoice.xcarchive"
APP_PATH="${DIST_DIR}/FluidVoice.app"

resolve_development_team() {
    if [ -n "${FLUIDVOICE_DEVELOPMENT_TEAM:-}" ]; then
        printf '%s\n' "${FLUIDVOICE_DEVELOPMENT_TEAM}"
        return
    fi
    local certificate
    certificate="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n "s/.*\"\(${IDENTITY}:[^\"]*\)\".*/\1/p" | head -n 1)"
    [ -n "${certificate}" ] || return 0
    security find-certificate -c "${certificate}" -p 2>/dev/null \
        | openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null \
        | sed -n 's/.*OU=\([^,]*\).*/\1/p'
}

TEAM="$(resolve_development_team)"
if [ -z "${TEAM}" ]; then
    printf >&2 'No "%s" signing identity found in the keychain.\n' "${IDENTITY}"
    printf >&2 'Create one in Xcode > Settings > Accounts > Manage Certificates, or set\n'
    printf >&2 'FLUIDVOICE_SIGNING_IDENTITY / FLUIDVOICE_DEVELOPMENT_TEAM explicitly.\n'
    exit 1
fi

# SPM binary xcframeworks can be embedded without their symlinks: Versions/Current, the
# top-level binary and Resources arrive as real copies, and the vendor's signature seal still
# lists the Headers Xcode stripped. Restore the canonical layout so the framework can be re-signed.
fix_framework_layout() {
    local framework="$1" version entry name
    [ -d "${framework}/Versions" ] || return 0
    [ -L "${framework}/Versions/Current" ] && return 0
    version="$(ls "${framework}/Versions" | grep -v '^Current$' | head -n 1)"
    [ -n "${version}" ] || return 0
    rm -rf "${framework}/Versions/Current"
    ln -s "${version}" "${framework}/Versions/Current"
    for entry in "${framework}"/*; do
        name="$(basename "${entry}")"
        [ "${name}" = "Versions" ] && continue
        [ -e "${framework}/Versions/${version}/${name}" ] || continue
        rm -rf "${entry}"
        ln -s "Versions/Current/${name}" "${entry}"
    done
    echo "Restored framework layout: $(basename "${framework}")"
}

XCCONFIG="$(mktemp -t fluidvoice-release).xcconfig"
ENTITLEMENTS="$(mktemp -t fluidvoice-entitlements).plist"
trap 'rm -f "${XCCONFIG}" "${ENTITLEMENTS}"' EXIT
cat > "${XCCONFIG}" <<XC
CODE_SIGN_STYLE = Manual
DEVELOPMENT_TEAM = ${TEAM}
CODE_SIGN_IDENTITY = ${IDENTITY}
CODE_SIGN_IDENTITY[sdk=macosx*] = ${IDENTITY}
PROVISIONING_PROFILE_SPECIFIER =
OTHER_CODE_SIGN_FLAGS = --timestamp
XC

mkdir -p "${DIST_DIR}"
rm -rf "${ARCHIVE_PATH}" "${APP_PATH}"

echo "Archiving Release build signed as '${IDENTITY}' (team ${TEAM})..."
xcodebuild archive \
    -project "${PROJECT_DIR}/Fluid.xcodeproj" \
    -scheme Fluid \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "${ARCHIVE_PATH}" \
    -derivedDataPath "${DERIVED_DATA_PATH}" \
    -xcconfig "${XCCONFIG}" \
    -quiet

ditto "${ARCHIVE_PATH}/Products/Applications/FluidVoice.app" "${APP_PATH}"

# Re-sign inside out: Xcode does not re-seal embedded binary frameworks after stripping
# their headers, which fails `codesign --verify --deep`. Keep the app's own entitlements.
codesign -d --entitlements - --xml "${APP_PATH}" > "${ENTITLEMENTS}"
for framework in "${APP_PATH}"/Contents/Frameworks/*.framework; do
    [ -e "${framework}" ] || continue
    fix_framework_layout "${framework}"
    codesign --force --sign "${IDENTITY}" --timestamp --options runtime "${framework}"
done
codesign --force --sign "${IDENTITY}" --timestamp --options runtime \
    --entitlements "${ENTITLEMENTS}" "${APP_PATH}"
codesign --verify --deep --strict "${APP_PATH}"

VERSION="$(defaults read "${APP_PATH}/Contents/Info.plist" CFBundleShortVersionString)"
echo "Built FluidVoice ${VERSION}: ${APP_PATH}"
echo "Install with: cp -R \"${APP_PATH}\" /Applications/"
