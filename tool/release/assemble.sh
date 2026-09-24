#!/bin/sh
# Lays out one bundle and packs it:
#
#   cloak-<version>-<os>-<arch>/
#     bin/cloak                          the program
#     lib/libstark_kernels.{dylib,so}    tstokenlib's kernels
#     lib/libisar.{dylib,so}             Isar's core
#     README.md  LICENSE  THIRD_PARTY_NOTICES
#
#   tool/release/assemble.sh <program> <kernels> <isar> <notices> <output directory>
#
# Run from the repository root. Prints the bundle's path; fails, printing the
# size, when the packed bundle is over 25 MB.
set -eu
[ $# -eq 5 ] || { echo "usage: tool/release/assemble.sh <program> <kernels> <isar> <notices> <output directory>" >&2; exit 2; }
program=$1; kernels=$2; isar=$3; notices=$4; out=$5
limit=25000000

version=$(sed -n 's/^version: *//p' pubspec.yaml)
case "$(uname -s)" in
  Darwin) os=macos; ext=dylib ;;
  Linux) os=linux; ext=so ;;
  *) echo "assemble: $(uname -s) is not a platform cloak is released for" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  arm64|aarch64) arch=arm64 ;;
  x86_64|amd64) arch=amd64 ;;
  *) echo "assemble: $(uname -m) is not an architecture cloak is released for" >&2; exit 1 ;;
esac
name="cloak-$version-$os-$arch"

for f in "$program" "$kernels" "$isar" "$notices" README.md LICENSE; do
  [ -f "$f" ] || { echo "assemble: $f is missing" >&2; exit 1; }
done

mkdir -p "$out"
dir="$out/$name"
rm -rf "$dir" "$dir.tar.gz"
mkdir -p "$dir/bin" "$dir/lib"
cp "$program" "$dir/bin/cloak"
cp "$kernels" "$dir/lib/libstark_kernels.$ext"
cp "$isar" "$dir/lib/libisar.$ext"
cp README.md LICENSE "$dir/"
cp "$notices" "$dir/THIRD_PARTY_NOTICES"
chmod 755 "$dir/bin/cloak"
chmod 644 "$dir/lib/"* "$dir/README.md" "$dir/LICENSE" "$dir/THIRD_PARTY_NOTICES"

# no AppleDouble files or extended attributes in the archive: a bundle holds
# exactly what is listed above
(cd "$out" && COPYFILE_DISABLE=1 tar -czf "$name.tar.gz" "$name")
size=$(wc -c < "$dir.tar.gz" | tr -d ' ')
if [ "$size" -gt "$limit" ]; then
  echo "assemble: $name.tar.gz is $size bytes, over the $limit byte limit" >&2
  exit 1
fi
echo "assemble: $name.tar.gz, $size bytes" >&2
echo "$dir.tar.gz"
