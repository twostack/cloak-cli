#!/bin/sh
# The macOS half of a release, built on the maintainer's Mac so that no signing
# secret is ever stored on GitHub.
#
#   tool/release/macos.sh            from a clean checkout of the tag v<version>
#   tool/release/macos.sh --trial    from any tree, to try the build out
#
# It refuses before building anything unless this Mac holds a Developer ID
# Application identity and a notarytool keychain profile (NOTARY_PROFILE,
# default cloak-notary), and unless the tag has a draft release to add to.
# Then it builds and checks the bundle as a Linux job does (resolve with the
# lock enforced, analyze, suite, Isar's library from pinned source, the
# program with tstokenlib's kernels through its build hook,
# notices, compile, links, smoke test, secret scan), signs the libraries and
# the program, packs the bundle into a disk image, signs that, has Apple
# notarize it, staples the ticket, checks it as a downloader would, and adds
# it to the draft with SHA256SUMS rewritten over all three files.
#
# --trial signs with any identity (SIGN_IDENTITY, or the first one found),
# skips notarization and the upload, allows a tree with changes and notices
# that cannot be written yet, and names
# the image cloak-<version>-macos-arm64-trial.dmg so it cannot be mistaken
# for a release. With TRIAL_NOTARIZE=1 a trial is notarized and stapled too,
# to try Apple's side out; it is still never uploaded.
set -eu
cd "$(dirname "$0")/../.."
trial=0
[ "${1:-}" = --trial ] && trial=1
notarize=$((1 - trial))
[ "$trial" -eq 1 ] && [ "${TRIAL_NOTARIZE:-0}" = 1 ] && notarize=1
profile=${NOTARY_PROFILE:-cloak-notary}
version=$(sed -n 's/^version: *//p' pubspec.yaml)
tag="v$version"
name="cloak-$version-macos-arm64"
out=build/macos
say() { echo "macos: $*"; }
die() { echo "macos: $*" >&2; exit 1; }

[ "$(uname -s)/$(uname -m)" = Darwin/arm64 ] || die "the macOS release is built on macOS arm64, not $(uname -s) $(uname -m)"

# what signs, before anything is built
identities=$(security find-identity -v -p codesigning)
if [ "$trial" -eq 1 ]; then
  identity=${SIGN_IDENTITY:-$(echo "$identities" | awk 'NR==1 {print $2}')}
  [ -n "$identity" ] || die "no signing identity at all; a trial needs one"
  image="$out/$name-trial.dmg"
else
  identity=$(echo "$identities" | awk '/"Developer ID Application: / {print $2; exit}')
  [ -n "$identity" ] || die "no Developer ID Application identity on this Mac, and Apple notarizes only what one signed. Found:
$identities
Create one in Xcode: Settings, Accounts, the team, Manage Certificates, +, Developer ID Application."
  xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 ||
    die "no notarytool keychain profile named $profile; make one with: xcrun notarytool store-credentials $profile"
  [ "$(git describe --exact-match --tags HEAD 2>/dev/null || true)" = "$tag" ] ||
    die "HEAD is not the tag $tag; check out the tag the release is made from"
  draft=$(gh release view "$tag" --json isDraft --jq .isDraft 2>/dev/null || true)
  [ "$draft" = true ] || die "there is no draft release for $tag; the release workflow makes it from the tag, with the Linux bundles"
  image="$out/$name.dmg"
fi
say "signing as $(echo "$identities" | awk -v id="$identity" '$2 == id {$1=""; $2=""; print; exit}')"

rm -rf "$out"
mkdir -p "$out"

# the same build and checks as a Linux job
dart pub get --enforce-lockfile
dart analyze lib bin test tool/release
tool/release/build-isar.sh "$out/native"
ISAR_CORE_LIB="$PWD/$out/native/libisar.dylib" dart test
if ! dart run tool/release/notices.dart "$out/THIRD_PARTY_NOTICES" 2>"$out/notices.err"; then
  cat "$out/notices.err" >&2
  [ "$trial" -eq 1 ] || die "the notices could not be written, and a release does not ship without them"
  # a trial goes on to try the rest; its image is named so it is never taken for a release
  printf 'TRIAL BUILD: the notices are incomplete.\n%s\n' "$(cat "$out/notices.err")" > "$out/THIRD_PARTY_NOTICES"
fi
if [ "$trial" -eq 1 ]; then tool/release/compile.sh "$out/build" --dirty; else tool/release/compile.sh "$out/build"; fi

# signed files first, then the bundle is assembled from them
mkdir -p "$out/signed/bin" "$out/signed/lib"
cp "$out/build/bundle/bin/cloak" "$out/signed/bin/cloak"
cp "$out/build/bundle/lib/libstark_kernels.dylib" "$out/native/libisar.dylib" "$out/signed/lib/"
tool/release/sign-macos.sh "$out/signed" "$identity"
tarball=$(tool/release/assemble.sh "$out/signed/bin/cloak" "$out/signed/lib/libstark_kernels.dylib" \
  "$out/signed/lib/libisar.dylib" "$out/THIRD_PARTY_NOTICES" "$out/bundle")
bundle=${tarball%.tar.gz}
tool/release/check-links.sh "$bundle"
tool/release/smoke.sh "$tarball"
dart run tool/release/scan_secrets.dart "$bundle"

# the image: a volume holding the bundle directory and nothing else
mkdir -p "$out/volume"
ditto "$bundle" "$out/volume/$name"
hdiutil create -quiet -volname "cloak $version" -srcfolder "$out/volume" -fs HFS+ -format UDZO -ov "$image"
codesign --force --timestamp --sign "$identity" "$image"
codesign --verify --strict "$image"
size=$(wc -c < "$image" | tr -d ' ')
[ "$size" -le 25000000 ] || die "$image is $size bytes, over the 25000000 byte limit"
say "$image, $size bytes"

mount=$(mktemp -d)
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mount" "$image"
listed=$(cd "$mount" && find . -mindepth 1 -not -path './.fseventsd*' | sort)
hdiutil detach -quiet "$mount"
expected=$(cd "$out/volume" && find . -mindepth 1 | sort)
[ "$listed" = "$expected" ] || die "the image holds:
$listed
and should hold exactly:
$expected"

if [ "$notarize" -eq 1 ]; then
  tool/release/notarize-macos.sh "$image" "$out/notary-log.json"
fi

# as a downloader gets it: the image quarantined, the bundle copied out
# carrying the mark, the program run
check=$(mktemp -d)
cp "$image" "$check/"
mark="0081;$(printf '%x' "$(date +%s)");Safari;"
xattr -w com.apple.quarantine "$mark" "$check/$(basename "$image")"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$check/mnt" "$check/$(basename "$image")"
ditto "$check/mnt/$name" "$check/$name"
hdiutil detach -quiet "$check/mnt"
find "$check/$name" -type f -exec xattr -w com.apple.quarantine "$mark" {} \;
# macOS kills a quarantined program it cannot vouch for, which is the check:
# spctl's execute assessment only judges app bundles, and answers "does not
# seem to be an app" for any command-line program, notarized or not. So a
# trial that was not notarized is expected to be stopped here, and anything
# notarized must run.
if ran=$("$check/$name/bin/cloak" --version 2>&1); then
  [ "$notarize" -eq 1 ] || { rm -rf "$check"; die "a program that was not notarized ran quarantined, so this check shows nothing: $ran"; }
  say "the quarantined program runs: $ran"
elif [ "$notarize" -eq 0 ]; then
  say "macOS stops the quarantined program, as it must one that was not notarized"
else
  rm -rf "$check"
  die "macOS does not run the quarantined program: ${ran:-killed}"
fi
rm -rf "$check"

if [ "$trial" -eq 1 ]; then
  say "trial image at $image; $([ "$notarize" -eq 1 ] && echo notarized and stapled || echo not notarized), and not uploaded"
  exit 0
fi

# into the draft, with SHA256SUMS covering all three files
sums="$out/release"
mkdir -p "$sums"
gh release download "$tag" --pattern 'cloak-*.tar.gz' --pattern SHA256SUMS --dir "$sums" --clobber
cp "$image" "$sums/"
(cd "$sums" && grep -v " $(basename "$image")\$" SHA256SUMS > SHA256SUMS.new || true)
(cd "$sums" && shasum -a 256 "$(basename "$image")" >> SHA256SUMS.new && sort -k2 SHA256SUMS.new > SHA256SUMS && rm SHA256SUMS.new)
(cd "$sums" && shasum -a 256 -c SHA256SUMS)
[ "$(wc -l < "$sums/SHA256SUMS" | tr -d ' ')" -eq 3 ] || die "SHA256SUMS should list three files: $(cat "$sums/SHA256SUMS")"
gh release upload "$tag" "$image" "$sums/SHA256SUMS" --clobber
say "added $(basename "$image") to the draft $tag; publish it once the checklist in docs/RELEASING.md is done"
