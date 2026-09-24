#!/bin/sh
# Builds the released program with `dart build cli`, which runs tstokenlib's
# build hook: it puts the kernels library, the prebuilt one the locked
# tstokenlib pins by SHA-256 (or one built from its crate when none is
# listed), in lib/ beside bin/cloak.
#
#   tool/release/compile.sh <output directory> [--dirty]
#
# Leaves <output directory>/bundle/bin/cloak and bundle/lib/libstark_kernels.*.
# Run from the repository root, after `dart pub get --enforce-lockfile`.
# The release's facts are written into lib/src/build_facts.dart for the build
# and the committed file is put back afterwards, whatever happens; --dirty is
# for a trial build from a working tree with changes (see facts.dart).
set -eu
out=${1:?usage: tool/release/compile.sh <output directory> [--dirty]}
shift
cp lib/src/build_facts.dart lib/src/build_facts.dart.committed
trap 'mv -f lib/src/build_facts.dart.committed lib/src/build_facts.dart' EXIT INT TERM
dart run tool/release/facts.dart "$@"
rm -rf "$out/bundle"
dart build cli --target bin/cloak.dart -o "$out"
