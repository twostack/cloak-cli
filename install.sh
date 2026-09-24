#!/bin/sh
# Installs cloak for the person running it, without sudo.
#
#   curl -fsSL https://raw.githubusercontent.com/twostack/cloak-cli/main/install.sh | sh
#   sh install.sh [--version 0.1.0] [--uninstall]
#
# It downloads the bundle for this machine (on macOS, the notarized disk
# image) and SHA256SUMS from the GitHub release (the latest, or the version
# named), checks one against the other, unpacks it (or copies it out of the
# image, mounted read-only) into ~/.local/share/cloak/<version>/ and points the link
# ~/.local/bin/cloak at it. A failed download or a checksum that does not
# match installs nothing and leaves whatever was installed as it was. Each
# version keeps its own directory, so an upgrade that goes wrong leaves the
# old one working, and going back is moving the link.
#
# It talks to GitHub and nothing else, sends nothing about the person, and
# never opens, reads or removes a wallet: a wallet is money, and uninstalling
# a program is not a reason to touch it.
#
# CLOAK_INSTALL_BASE replaces the release address, for testing against a
# directory of files (file://...); anything else must be HTTPS.
set -eu

repo_releases=https://github.com/twostack/cloak-cli/releases
base=${CLOAK_INSTALL_BASE:-$repo_releases}
share="$HOME/.local/share/cloak"
bindir="$HOME/.local/bin"
link="$bindir/cloak"

say() { echo "install.sh: $*"; }
die() { echo "install.sh: $*" >&2; exit 1; }

version=""
uninstall=0
while [ $# -gt 0 ]; do
  case "$1" in
    --version) [ $# -ge 2 ] || die "--version needs a version, such as 0.1.0"; version=${2#v}; shift 2 ;;
    --uninstall) uninstall=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "$1 is not an option; the options are --version <version> and --uninstall" ;;
  esac
done

wallet=${CLOAK_WALLET:-$HOME/.cloak}

if [ "$uninstall" -eq 1 ]; then
  if [ -L "$link" ]; then
    case "$(readlink "$link")" in
      "$share"/*) rm -f "$link" ;;
      *) say "left $link alone: it does not point into $share" ;;
    esac
  fi
  rm -rf "$share"
  say "removed cloak from $share"
  if [ -e "$wallet" ]; then
    say "the wallet in $wallet was not touched; it is yours to keep or remove"
  else
    say "no wallet was touched"
  fi
  exit 0
fi

case "$base" in
  https://*) proto='=https' ;;
  file://*) proto='=file' ;;
  *) die "$base is not an HTTPS address; cloak is only downloaded over HTTPS" ;;
esac
command -v curl >/dev/null 2>&1 || die "curl is needed to download cloak, and was not found"
command -v tar >/dev/null 2>&1 || die "tar is needed to unpack cloak, and was not found"
fetch() { curl --proto "$proto" --tlsv1.2 -fsSL "$1" -o "$2"; }

# which bundle this machine runs
os=$(uname -s)
arch=$(uname -m)
case "$os/$arch" in
  Darwin/arm64) platform=macos-arm64 ;;
  Linux/x86_64|Linux/amd64) platform=linux-amd64 ;;
  Linux/aarch64|Linux/arm64) platform=linux-arm64 ;;
  *)
    case "$os" in Darwin) name=macOS ;; *) name=$os ;; esac
    die "cloak is not built for $name $arch; it runs on macOS arm64 (Apple silicon), Linux x86_64 and Linux aarch64"
    ;;
esac

if [ "$os" = Linux ]; then
  found=$( (ldd --version 2>&1 || true) | head -1)
  glibc=$(echo "$found" | grep -Eo '[0-9]+\.[0-9]+$' || true)
  case "$found" in *GLIBC*|*"GNU libc"*|*glibc*) ;; *) glibc="" ;; esac
  [ -n "$glibc" ] || die "cloak needs glibc 2.35 or later, and this system's C library is: ${found:-unknown}"
  major=${glibc%%.*}; minor=${glibc#*.}
  if [ "$major" -lt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -lt 35 ]; }; then
    die "cloak needs glibc 2.35 or later, and this system has glibc $glibc"
  fi
fi

if [ -z "$version" ]; then
  if [ "$proto" = '=file' ]; then
    [ -f "${base#file://}/latest" ] || die "no version given, and $base has no latest"
    version=$(cat "${base#file://}/latest")
  else
    # the latest release's page redirects to its tag
    where=$(curl --proto '=https' --tlsv1.2 -fsSLI -o /dev/null -w '%{url_effective}' "$base/latest") ||
      die "could not ask GitHub for the latest release"
    version=${where##*/v}
    case "$version" in ''|*/*) die "could not tell the latest version from $where" ;; esac
  fi
fi

case "$platform" in
  macos-*) asset="cloak-$version-$platform.dmg" ;;
  *) asset="cloak-$version-$platform.tar.gz" ;;
esac
tmp=$(mktemp -d)
mounted=""
cleanup() {
  [ -z "$mounted" ] || hdiutil detach -quiet "$mounted" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM
say "downloading cloak $version for $platform"
fetch "$base/download/v$version/$asset" "$tmp/$asset" || die "could not download $asset from $base/download/v$version/"
fetch "$base/download/v$version/SHA256SUMS" "$tmp/SHA256SUMS" || die "could not download SHA256SUMS for $version"

# the one line naming this bundle, as '<64 hex digits>  <file>'
line=$(grep -E "^[0-9a-f]{64}  $asset\$" "$tmp/SHA256SUMS" || true)
[ -n "$line" ] || die "SHA256SUMS has no line for $asset, so the download cannot be checked; nothing was installed"
[ "$(echo "$line" | wc -l | tr -d ' ')" -eq 1 ] || die "SHA256SUMS names $asset more than once; nothing was installed"
want=${line%% *}
if command -v sha256sum >/dev/null 2>&1; then
  got=$(sha256sum "$tmp/$asset" | cut -d' ' -f1)
elif command -v shasum >/dev/null 2>&1; then
  got=$(shasum -a 256 "$tmp/$asset" | cut -d' ' -f1)
else
  die "neither sha256sum nor shasum was found, so the download cannot be checked; nothing was installed"
fi
[ "$got" = "$want" ] || die "$asset does not match SHA256SUMS: it is $got, and SHA256SUMS says $want; nothing was installed"

mkdir -p "$tmp/unpacked"
case "$asset" in
  *.dmg)
    mkdir -p "$tmp/mnt"
    hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$tmp/mnt" "$tmp/$asset" 2>/dev/null ||
      die "$asset could not be opened; nothing was installed"
    mounted="$tmp/mnt"
    ditto "$tmp/mnt/cloak-$version-$platform" "$tmp/unpacked/cloak-$version-$platform" 2>/dev/null ||
      die "$asset holds no cloak-$version-$platform; nothing was installed"
    hdiutil detach -quiet "$mounted" && mounted=""
    ;;
  *) tar -xzf "$tmp/$asset" -C "$tmp/unpacked" || die "$asset could not be unpacked; nothing was installed" ;;
esac
unpacked="$tmp/unpacked/cloak-$version-$platform"
[ -x "$unpacked/bin/cloak" ] || die "$asset holds no bin/cloak; nothing was installed"

# the version's directory is replaced whole, then the link is moved in one
# rename, so at every moment the link names a complete install or the old one
mkdir -p "$share" "$bindir"
target="$share/$version"
rm -rf "$share/.incoming"
mv "$unpacked" "$share/.incoming"
rm -rf "$target"
mv "$share/.incoming" "$target"
ln -s "$target/bin/cloak" "$bindir/.cloak.incoming"
mv -f "$bindir/.cloak.incoming" "$link"

say "installed cloak $version in $target"
say "$link points at it"
case ":$PATH:" in
  *":$bindir:"*) ;;
  *) say "$bindir is not on your PATH; add it with: export PATH=\"$bindir:\$PATH\"" ;;
esac
