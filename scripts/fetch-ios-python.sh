#!/bin/bash
# Fetches the pinned CPython runtime for iOS into third_party/python-ios (git-ignored). Runs from XcodeGen's
# preGenCommand and never fails the build: without the runtime the app just cannot run Python scripts.
#   IDJ_PYTHON=0            build without Python (also removes an unpacked runtime)
#   IDJ_PYTHON_CACHE=<dir>  download cache, default ~/Library/Caches/idj-python
set -u
cd "$(dirname "$0")/.." || exit 0

# BeeWare Python-Apple-support: CPython + patches as Python.xcframework (device and simulator), PSF-2.0.
TAG=3.13-b18
FILE=Python-3.13-iOS-support.b18.tar.gz
SHA256=d06acf2a9c7964a8689566353a0e707402eff822037de5e29ba0e16040f7047d
URL="https://github.com/beeware/Python-Apple-support/releases/download/$TAG/$FILE"

DEST=third_party/python-ios
STAMP="$TAG $SHA256"
CACHE="${IDJ_PYTHON_CACHE:-$HOME/Library/Caches/idj-python}"

warn() { echo "warning: [python] $*; this build will not include the Python runtime" >&2; }
digest() { shasum -a 256 "$1" 2>/dev/null | cut -d ' ' -f 1; }

if [ "${IDJ_PYTHON:-1}" = 0 ]; then
  rm -rf "$DEST"
  exit 0
fi
[ "$(uname -s)" = Darwin ] || exit 0
[ "$(cat "$DEST/.stamp" 2>/dev/null)" = "$STAMP" ] && exit 0
rm -rf "$DEST"

mkdir -p "$CACHE" || { warn "cannot create $CACHE"; exit 0; }
ARCHIVE="$CACHE/$FILE"
if [ ! -f "$ARCHIVE" ] || [ "$(digest "$ARCHIVE")" != "$SHA256" ]; then
  PART="$ARCHIVE.part.$$"
  trap 'rm -f "$PART"' EXIT
  echo "[python] downloading $URL"
  if ! curl --fail --location --silent --show-error --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 900 -o "$PART" "$URL"; then
    warn "download failed"
    exit 0
  fi
  GOT=$(digest "$PART")
  if [ "$GOT" != "$SHA256" ]; then
    warn "SHA-256 mismatch for $FILE (expected $SHA256, got $GOT)"
    exit 0
  fi
  mv -f "$PART" "$ARCHIVE" || { warn "cannot write $ARCHIVE"; exit 0; }
fi

TMP="$DEST.tmp.$$"
rm -rf "$TMP"
if mkdir -p "$TMP" && tar -xzf "$ARCHIVE" -C "$TMP" Python.xcframework VERSIONS && printf '%s' "$STAMP" > "$TMP/.stamp" && mv "$TMP" "$DEST"; then
  echo "[python] $(head -1 "$DEST/VERSIONS")($TAG)"
else
  rm -rf "$TMP" "$DEST"
  warn "unpacking failed"
fi
exit 0
