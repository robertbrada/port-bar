#!/bin/bash
#
# Builds, signs, notarises and staples a distributable PortBar.dmg.
#
#   ./scripts/release.sh
#
# Prerequisites, both one-off:
#
#   1. A "Developer ID Application" certificate in your login keychain.
#      Xcode > Settings > Accounts > Manage Certificates > + .
#      An "Apple Development" certificate is NOT enough — it signs builds that
#      only run on machines registered to your team.
#
#   2. A stored notary credential profile named below:
#
#        xcrun notarytool store-credentials portbar \
#          --apple-id you@example.com \
#          --team-id GMGW3DYJY8 \
#          --password <app-specific-password>
#
#      Generate the app-specific password at appleid.apple.com > Sign-In and
#      Security. Your normal Apple ID password will not work. The credential is
#      kept in the keychain, so no secret ever lands in this repo.
#
# The app is notarised twice on purpose: once as a zipped .app so the ticket can
# be stapled to the bundle itself, and again as the .dmg that people download.
# Stapling only the disk image leaves the extracted app relying on an online
# Gatekeeper check, which fails for a user who is offline on first launch.

set -euo pipefail

PROJECT="PortBar.xcodeproj"
SCHEME="PortBar"
PROFILE="portbar"            # notarytool keychain profile, see above
BUILD="build"
ARCHIVE="$BUILD/PortBar.xcarchive"
EXPORT="$BUILD/export"
STAGE="$BUILD/dmg"

cd "$(dirname "$0")/.."

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
die()  { printf '\n\033[31mError: %s\033[0m\n' "$1" >&2; exit 1; }

# Runs xcodebuild with its full output captured, and on failure prints the lines
# that actually say what went wrong. Filtering xcodebuild's output inline hides
# the one line you need: the first version of this script piped through grep and
# reported nothing but "Archive failed".
xcode() {
    local log=$1; shift
    mkdir -p "$(dirname "$log")"
    if ! xcodebuild "$@" > "$log" 2>&1; then
        printf '\n\033[31mxcodebuild failed. Relevant lines:\033[0m\n' >&2
        grep -iE "error:|failed|cannot|unable to" "$log" | head -15 >&2
        printf '\nFull log: %s\n' "$log" >&2
        return 1
    fi
    grep -E "^\*\* " "$log" || true
}

# --- Preflight ---------------------------------------------------------------

step "Checking prerequisites"

security find-identity -v -p codesigning | grep -q "Developer ID Application" \
    || die "No 'Developer ID Application' certificate found. See the header of this script."

xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
    || die "No notary credentials stored under profile '$PROFILE'. See the header of this script."

VERSION=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ MARKETING_VERSION/ {print $2; exit}')
[ -n "$VERSION" ] || die "Could not read MARKETING_VERSION from the project."
DMG="$BUILD/PortBar-$VERSION.dmg"
echo "  version $VERSION"

# A sandboxed build would pass every check here and still be useless: lsof
# returns an empty table rather than an error. Fail loudly instead.
grep -q "ENABLE_APP_SANDBOX = NO" "$PROJECT/project.pbxproj" \
    || die "App Sandbox appears to be enabled. PortBar cannot work sandboxed — see README."

# --- Build -------------------------------------------------------------------

# Archive with the project's own automatic signing, and do NOT force the
# identity here. Passing CODE_SIGN_IDENTITY="Developer ID Application" to an
# automatically-signed target is rejected outright: "conflicting provisioning
# settings ... automatically signed for development, but a conflicting code
# signing identity has been manually specified". The Developer ID signature is
# applied by the export step below, which is exactly what Xcode's Organizer
# does when you pick Distribute App > Developer ID.
step "Archiving"
rm -rf "$BUILD"
xcode "$BUILD/archive.log" -project "$PROJECT" -scheme "$SCHEME" \
    -configuration Release -archivePath "$ARCHIVE" archive \
    || die "Archive failed."
[ -d "$ARCHIVE" ] || die "Archive produced nothing at $ARCHIVE"

step "Exporting a Developer ID build"
xcode "$BUILD/export.log" -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist scripts/ExportOptions.plist -exportPath "$EXPORT" \
    || die "Export failed."
APP="$EXPORT/PortBar.app"
[ -d "$APP" ] || die "Export produced nothing at $APP"

step "Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "Authority|Identifier|Runtime|TeamIdentifier"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "app-sandbox" \
    && die "The exported app claims the sandbox entitlement. It must not."
echo "  hardened runtime and Developer ID signature look right"

# --- Notarise the app --------------------------------------------------------

step "Notarising the app bundle"
ditto -c -k --keepParent "$APP" "$BUILD/PortBar.zip"
xcrun notarytool submit "$BUILD/PortBar.zip" --keychain-profile "$PROFILE" --wait \
    || die "Notarisation of the app was rejected. Run: xcrun notarytool log <id> --keychain-profile $PROFILE"

step "Stapling the app"
xcrun stapler staple "$APP"

# --- Package -----------------------------------------------------------------

step "Building the disk image"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "PortBar" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

step "Signing the disk image"
codesign --sign "Developer ID Application" --timestamp "$DMG"

step "Notarising the disk image"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait \
    || die "Notarisation of the disk image was rejected."

step "Stapling the disk image"
xcrun stapler staple "$DMG"

# --- Final verification ------------------------------------------------------

step "Final check, as Gatekeeper sees it"
spctl --assess --type exec --verbose=4 "$APP" 2>&1 | sed 's/^/  /'
xcrun stapler validate "$DMG" | sed 's/^/  /'

printf '\n\033[1mDone.\033[0m %s\n' "$DMG"
echo "Attach it to a GitHub release, then flip the README's download section."
