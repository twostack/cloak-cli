#!/bin/sh
# Submits a signed disk image to Apple's notary service, waits for the
# answer, keeps the log, and on Accepted staples the ticket to the image.
#
#   tool/release/notarize-macos.sh <image.dmg> <log file>
#
# The credentials are a notarytool keychain profile on this Mac, named by
# NOTARY_PROFILE (default cloak-notary), made once with
# `xcrun notarytool store-credentials cloak-notary`. They are never passed on
# a command line or stored anywhere else.
set -eu
image=${1:?usage: tool/release/notarize-macos.sh <image.dmg> <log file>}
log=${2:?usage: tool/release/notarize-macos.sh <image.dmg> <log file>}
profile=${NOTARY_PROFILE:-cloak-notary}

result=$(xcrun notarytool submit "$image" --keychain-profile "$profile" --wait --output-format json) ||
  { echo "notarize-macos: the submission failed: $result" >&2; exit 1; }
id=$(printf '%s' "$result" | plutil -extract id raw -o - - 2>/dev/null || true)
status=$(printf '%s' "$result" | plutil -extract status raw -o - - 2>/dev/null || true)
if [ -n "$id" ]; then
  xcrun notarytool log "$id" --keychain-profile "$profile" "$log" >/dev/null 2>&1 ||
    echo "notarize-macos: the log for $id could not be fetched" >&2
fi
echo "notarize-macos: submission ${id:-unknown}: ${status:-no answer}"
if [ "$status" != "Accepted" ]; then
  [ -f "$log" ] && cat "$log" >&2
  exit 1
fi
xcrun stapler staple "$image"
xcrun stapler validate "$image"
spctl --assess --type open --context context:primary-signature --verbose "$image"
