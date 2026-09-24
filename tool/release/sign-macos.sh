#!/bin/sh
# Signs a macOS bundle's Mach-O files with a Developer ID under the hardened
# runtime, the libraries first and then the program, and checks each
# signature: the runtime flag, a secure timestamp, and exactly the one
# entitlement on the program and none on the libraries.
#
#   tool/release/sign-macos.sh <bundle directory> <signing identity> [keychain]
#
# The identity is the certificate's name or hash, as `security find-identity`
# lists it; the keychain is the temporary one the workflow imports it into.
set -eu
bundle=${1:?usage: tool/release/sign-macos.sh <bundle directory> <signing identity> [keychain]}
identity=${2:?usage: tool/release/sign-macos.sh <bundle directory> <signing identity> [keychain]}
keychain=${3:-}
here=$(cd "$(dirname "$0")" && pwd)
entitlements="$here/cloak.entitlements"

sign() {
  if [ -n "$keychain" ]; then
    codesign --force --options runtime --timestamp --keychain "$keychain" --sign "$identity" "$@"
  else
    codesign --force --options runtime --timestamp --sign "$identity" "$@"
  fi
}

for lib in "$bundle"/lib/*.dylib; do sign "$lib"; done
sign --entitlements "$entitlements" "$bundle/bin/cloak"

bad=0
for f in "$bundle"/lib/*.dylib "$bundle/bin/cloak"; do
  codesign --verify --strict --verbose=1 "$f" || { echo "sign-macos: $f does not verify" >&2; bad=1; continue; }
  details=$(codesign -d --verbose=2 "$f" 2>&1)
  case "$details" in *"flags="*"(runtime)"*) ;; *) echo "sign-macos: $f is not under the hardened runtime" >&2; bad=1 ;; esac
  case "$details" in *"Timestamp="*) ;; *) echo "sign-macos: $f has no secure timestamp" >&2; bad=1 ;; esac
  # a file with no entitlements prints nothing, which is none
  xml=$(codesign -d --entitlements - --xml "$f" 2>/dev/null || true)
  keys='{}'
  [ -z "$xml" ] || keys=$(printf '%s' "$xml" | plutil -convert json -o - -)
  case "$f" in
    */bin/cloak)
      [ "$keys" = '{"com.apple.security.cs.allow-unsigned-executable-memory":true}' ] ||
        { echo "sign-macos: $f carries $keys, not exactly the one entitlement" >&2; bad=1; } ;;
    *)
      [ "$keys" = '{}' ] || { echo "sign-macos: $f carries entitlements: $keys" >&2; bad=1; } ;;
  esac
done
[ "$bad" -eq 0 ] && echo "sign-macos: $bundle signed and checked"
exit "$bad"
