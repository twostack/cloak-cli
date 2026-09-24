#!/bin/sh
# Checks that a bundle's program and libraries link only to what every
# machine of its platform has, and that no library is named by the directory
# it was built in.
#
#   tool/release/check-links.sh <bundle directory>
#
# macOS: every dependency under /usr/lib/ or /System/Library/Frameworks/ (or
# the bundle's own libraries by @rpath), each library's own name @rpath/...,
# and no absolute rpath. Linux: every NEEDED entry on the C library's list, no
# SONAME with a path in it, no RPATH or RUNPATH, and no symbol newer than
# glibc 2.35. Fails naming each file and dependency that is not allowed.
set -eu
bundle=${1:?usage: tool/release/check-links.sh <bundle directory>}
files="$bundle/bin/cloak $(ls "$bundle"/lib/* 2>/dev/null || true)"
bad=0
fail() { echo "check-links: $1" >&2; bad=1; }

for f in $files; do
  [ -f "$f" ] || { fail "$f is missing"; continue; }
  case "$(uname -s)" in
    Darwin)
      # a universal file prints a heading per architecture, ending in ':'
      own=$(otool -D "$f" | grep -v ':$' | head -1)
      case "$f" in
        */lib/*) case "$own" in @rpath/*) ;; *) fail "$f names itself $own, not @rpath/..." ;; esac ;;
      esac
      # otool -L indents what a file loads, a library's own name among them
      otool -L "$f" | grep '^[[:space:]]' | awk '{print $1}' | sort -u | while read -r dep; do
        [ "$dep" = "$own" ] && continue
        case "$dep" in
          /usr/lib/*|/System/Library/Frameworks/*) ;;
          @rpath/libstark_kernels.dylib|@rpath/libisar.dylib) ;;
          *) echo "check-links: $f loads $dep, which is not a system library" >&2; echo bad ;;
        esac
      done | grep -q bad && bad=1
      otool -l "$f" | awk '/LC_RPATH/{r=1} r&&/ path /{print $2; r=0}' | while read -r rp; do
        case "$rp" in
          @loader_path*|@executable_path*) ;;
          *) echo "check-links: $f has the rpath $rp" >&2; echo bad ;;
        esac
      done | grep -q bad && bad=1
      ;;
    Linux)
      readelf -d "$f" | awk '/\(NEEDED\)/{gsub(/[\[\]]/,"",$5); print $5}' | while read -r dep; do
        case "$dep" in
          libc.so.6|libm.so.6|libpthread.so.0|libdl.so.2|librt.so.1|libgcc_s.so.1|ld-linux-*.so.*) ;;
          *) echo "check-links: $f loads $dep, which is not a system library" >&2; echo bad ;;
        esac
      done | grep -q bad && bad=1
      soname=$(readelf -d "$f" | awk '/\(SONAME\)/{gsub(/[\[\]]/,"",$5); print $5}')
      case "$soname" in */*) fail "$f names itself $soname" ;; esac
      if readelf -d "$f" | grep -Eq '\((RPATH|RUNPATH)\)'; then
        fail "$f has an rpath: $(readelf -d "$f" | grep -E '\((RPATH|RUNPATH)\)')"
      fi
      newest=$(objdump -T "$f" | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -t. -k1,1n -k2,2n | tail -1)
      if [ -n "$newest" ]; then
        major=${newest%%.*}; minor=${newest#*.}; minor=${minor%%.*}
        if [ "$major" -gt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -gt 35 ]; }; then
          fail "$f needs glibc $newest, newer than 2.35"
        fi
      fi
      ;;
    *) fail "$(uname -s) is not a platform cloak is released for" ;;
  esac
done
[ "$bad" -eq 0 ] && echo "check-links: $bundle links only to system libraries"
exit "$bad"
