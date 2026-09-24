#!/bin/sh
# Builds Isar's core library from source, from the commit of the Isar
# repository that the isar package version pubspec.lock pins was released
# from, with a Cargo.lock kept here, and names it the way a bundle needs.
#
#   tool/release/build-isar.sh <output directory>
#
# Isar publishes no library for Linux on arm64, so none is downloaded for any
# platform: one way of getting it for all three is one way to check. Its
# repository keeps no Cargo.lock, so its Rust dependencies would float to
# whatever is newest on the day; tool/release/isar/Cargo.lock pins them, made
# with the resolver that keeps to the pinned toolchain.
set -eu
out=${1:?usage: tool/release/build-isar.sh <output directory>}
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)

# the one isar version this lock and commit are for
tag=3.1.0+1
commit=6643d064abf22606b6c6a741ea873e4781115ef4
locked=$(awk -v p="isar" '$1 == p":" {f = 1} f && $1 == "version:" {gsub(/"/, "", $2); print $2; exit}' pubspec.lock)
[ "$locked" = "$tag" ] || { echo "build-isar: pubspec.lock pins isar $locked, and this script builds $tag; update both together" >&2; exit 1; }

src="$out/isar-src"
rm -rf "$src"
git init -q "$src"
git -C "$src" fetch -q --depth 1 https://github.com/isar/isar.git "$commit"
git -C "$src" checkout -q FETCH_HEAD
echo "build-isar: isar $tag, commit $(git -C "$src" rev-parse HEAD)"
cp "$here/isar/Cargo.lock" "$src/Cargo.lock"

case "$(uname -s)" in
  Darwin) name=libisar.dylib ;;
  Linux) name=libisar.so ;;
  *) echo "build-isar: $(uname -s) is not a platform cloak is released for" >&2; exit 1 ;;
esac
(cd "$src" && cargo build --release --locked -p isar)
cp "$src/target/release/$name" "$out/$name"
if [ "$(uname -s)" = Darwin ]; then
  install_name_tool -id "@rpath/$name" "$out/$name"
fi
echo "build-isar: $out/$name"
