#!/bin/sh
# Runs a packed bundle the way a person would, and fails on anything a person
# would trip over.
#
#   tool/release/smoke.sh <cloak-<version>-<os>-<arch>.tar.gz>
#
# The bundle is unpacked under a path with a space in it and run through a
# link from another directory, from a working directory that has nothing to
# do with it, with an environment of HOME, PATH and CLOAK_PASSPHRASE only.
# Then it is broken on purpose: its libraries removed, a library planted in
# the working directory, its directory made read-only. Needs a C compiler for
# the planted library.
set -eu
tarball=${1:?usage: tool/release/smoke.sh <bundle.tar.gz>}
tarball=$(cd "$(dirname "$tarball")" && pwd)/$(basename "$tarball")
name=$(basename "$tarball" .tar.gz)
case "$(uname -s)" in Darwin) ext=dylib ;; *) ext=so ;; esac

# the versions the lock pins, when run from the repository root as the
# workflow does, for --version --json to be checked against
pins=""
if [ -f pubspec.lock ]; then
  for lib in libcloak libspiffy tstokenlib ricochet; do
    pins="$pins \"$lib\":\"$(awk -v p="$lib" '$1 == p":" {f = 1} f && $1 == "version:" {gsub(/"/, "", $2); print $2; exit}' pubspec.lock)\""
  done
fi

tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)
trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
installed="$tmp/an install"
home="$tmp/home"
elsewhere="$tmp/elsewhere"
path="$tmp/path"
mkdir -p "$installed" "$home" "$elsewhere" "$path"
failed=0
fail() { echo "smoke: FAIL: $1" >&2; failed=1; }
ok() { echo "smoke: ok: $1"; }

# What a bundle holds: exactly these, under one directory
expected="$name/
$name/LICENSE
$name/README.md
$name/THIRD_PARTY_NOTICES
$name/bin/
$name/bin/cloak
$name/lib/
$name/lib/libisar.$ext
$name/lib/libstark_kernels.$ext"
listed=$(tar -tzf "$tarball" | sort)
if [ "$listed" = "$(echo "$expected" | sort)" ]; then ok "what a bundle holds"; else
  fail "the bundle holds:
$listed
and should hold exactly:
$expected"
fi

tar -xzf "$tarball" -C "$installed"
bundle="$installed/$name"
ln -s "$bundle/bin/cloak" "$path/cloak"

# cloak as a person runs it: through the link, from elsewhere, in a bare
# environment. The passphrase is a test value, and the wallet is thrown away.
run() {
  (cd "$elsewhere" && env -i HOME="$home" PATH="$path:/usr/bin:/bin" CLOAK_PASSPHRASE='smoke test only' cloak "$@")
}
expect_ok() {
  if out=$(run "$@" 2>&1); then ok "cloak $*"; else fail "cloak $* exited non-zero:
$out"; fi
}

# the tree outside the wallet, before and after, to show nothing else was written
snapshot() { (cd "$tmp" && find . -path ./home/.cloak -prune -o -print | sort); }
before=$(snapshot)

version=$(run --version)
case "$version" in
  *"development build"*) fail "--version says $version: a release build names its commit" ;;
  "cloak "*) ok "--version: $version" ;;
  *) fail "--version printed $version" ;;
esac
facts=$(run --json --version)
for pin in $pins; do
  case "$facts" in
    *"$pin"*) ok "--version --json names $pin" ;;
    *) fail "--version --json does not name $pin: $facts" ;;
  esac
done
expect_ok --help
expect_ok init --network regtest
expect_ok address
expect_ok address --transparent
expect_ok status
expect_ok balance
status=$(run --json status)
for lib in kernels isar; do
  if echo "$status" | grep -q "\"name\":\"$lib\"[^}]*\"present\":true"; then ok "status names $lib present"; else
    fail "status --json does not report $lib present: $status"
  fi
done

after=$(snapshot)
if [ "$before" = "$after" ]; then ok "no file outside the wallet directory"; else
  fail "files changed outside the wallet directory:
$(printf '%s\n' "$before" > "$tmp/.a"; printf '%s\n' "$after" > "$tmp/.b"; diff "$tmp/.a" "$tmp/.b" || true)"
fi

# A planted library is not loaded: the bundle's kernels gone, and a library
# of the kernels' name in the working directory that leaves a mark if loaded
planted="$elsewhere/native/stark_kernels/target/release"
mkdir -p "$planted"
marker="$tmp/planted-was-loaded"
cat > "$tmp/stub.c" <<EOF
#include <stdio.h>
unsigned int sk_version(void) { return 7; }
__attribute__((constructor)) static void loaded(void) { FILE *f = fopen("$marker", "w"); if (f) fclose(f); }
EOF
cc -shared -fPIC -o "$planted/libstark_kernels.$ext" "$tmp/stub.c"
mv "$bundle/lib/libstark_kernels.$ext" "$tmp/kernels.saved"
if out=$(run address 2>&1); then fail "address ran with the kernels removed: $out"; else
  case "$out" in
    *'refused at "native library"'*"libstark_kernels.$ext"*) ok "the kernels removed: $out" ;;
    *) fail "address with the kernels removed said: $out" ;;
  esac
  case "$out" in *cargo*) fail "the refusal names cargo" ;; esac
fi
if [ -e "$marker" ]; then fail "the planted library was loaded"; else ok "the planted library was not loaded"; fi
rm -rf "$elsewhere/native"
mv "$tmp/kernels.saved" "$bundle/lib/libstark_kernels.$ext"

# Isar's library absent, in a read-only bundle: a refusal, and no download
mv "$bundle/lib/libisar.$ext" "$tmp/isar.saved"
chmod -R a-w "$bundle"
before=$(snapshot)
if out=$(run address --transparent 2>&1); then fail "address --transparent ran with Isar's library removed: $out"; else
  case "$out" in
    *'refused at "native library"'*"libisar.$ext"*"$bundle/lib"*) ok "Isar's library absent: $out" ;;
    *) fail "address --transparent with Isar's library removed said: $out" ;;
  esac
fi
[ "$before" = "$(snapshot)" ] && ok "nothing written for the missing Isar library" || fail "files were written when Isar's library was missing"
chmod -R u+w "$bundle"
mv "$tmp/isar.saved" "$bundle/lib/libisar.$ext"

# A bundle with no libraries: what needs none still works
mv "$bundle/lib" "$tmp/lib.saved"
for args in --help --version status balance notes journal; do
  # shellcheck disable=SC2086 # one word each
  if out=$(run $args 2>&1); then ok "no libraries: cloak $args"; else fail "no libraries: cloak $args: $out"; fi
done
mv "$tmp/lib.saved" "$bundle/lib"

if [ "$failed" -eq 0 ]; then echo "smoke: $name passed"; else echo "smoke: $name FAILED" >&2; fi
exit "$failed"
