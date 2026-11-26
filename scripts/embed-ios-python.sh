#!/bin/bash
# Xcode build phase of target STV: puts the CPython runtime fetched by scripts/fetch-ios-python.sh into the app.
#   Frameworks/Python.framework               interpreter, thinned to $ARCHS
#   Frameworks/<module>.framework             one per extension module (iOS only loads code from frameworks)
#   python/lib/stdlib.pyz                     pure-Python standard library, trimmed; a stored zip (named .pyz because zip
#                                             does not compress *.zip again when the IPA is packed)
#   python/lib/python3.13/lib-dynload/*.fwork placeholders that CPython's AppleFrameworkLoader resolves
# Without a runtime (IDJ_PYTHON=0, offline) it removes what an earlier build left behind.
#   IDJ_PYTHON_SSL=1        also ship _ssl / _hashlib (OpenSSL); by default TLS and digests come from the host
#   IDJ_HOST_PYTHON=<path>  Python 3.13 used to compile the standard library to .pyc (default: search; .py if none)
set -euo pipefail

APP="$TARGET_BUILD_DIR/$WRAPPER_NAME"
SRC="$SRCROOT/third_party/python-ios"
WORK="$DERIVED_FILE_DIR/idj-python"
STAGE="$WORK/stage"
HOME_DIR=python
DYNLOAD="$HOME_DIR/lib/python3.13/lib-dynload"

# Only the shared script libraries ship, not their tests.
if [ -d "$APP/tvbox" ]; then
  rm -rf "$APP/tvbox/py/ios_site/tests"
  find "$APP/tvbox" -name __pycache__ -type d -prune -exec rm -rf {} +
fi

remove_installed() {
  if [ -f "$WORK/installed" ]; then
    while read -r name; do rm -rf "${APP:?}/Frameworks/$name.framework"; done < "$WORK/installed"
    rm -rf "${APP:?}/$HOME_DIR" "$WORK/installed"
  fi
}

if [ "${IDJ_PYTHON:-1}" = 0 ] || [ ! -f "$SRC/.stamp" ]; then
  remove_installed
  rm -rf "$WORK"
  echo "note: no Python runtime in this build"
  exit 0
fi

XCF="$SRC/Python.xcframework"
SUPPORTED=iPhoneOS
SLICE="$XCF/ios-arm64"
if [ "$PLATFORM_NAME" = iphonesimulator ]; then
  SUPPORTED=iPhoneSimulator
  SLICE=$(echo "$XCF"/ios-*-simulator)
fi
LIB="$XCF/lib/python3.13"

IDENTITY=
if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  IDENTITY="$EXPANDED_CODE_SIGN_IDENTITY"
elif [ "$PLATFORM_NAME" = iphonesimulator ]; then
  IDENTITY=-
fi

MODULES="_asyncio _bisect _blake2 _bz2 _codecs_cn _codecs_tw _contextvars _csv _ctypes _datetime _decimal _elementtree
  _heapq _json _lzma _md5 _multibytecodec _opcode _pickle _queue _random _sha1 _sha2 _sha3 _socket _statistics _struct
  _uuid _zoneinfo array binascii cmath fcntl math pyexpat select unicodedata zlib"
if [ "${IDJ_PYTHON_SSL:-0}" = 1 ]; then MODULES="$MODULES _hashlib _ssl"; fi

# .pyc files only load with the magic number of this Python, so the compiler must be the same minor version.
MAGIC=$(sed -nE 's/^MAGIC_NUMBER = \(([0-9]+)\).*/\1/p' "$LIB/importlib/_bootstrap_external.py" | head -1)
HOST_PYTHON=
find_host_python() {
  local p
  for p in "${IDJ_HOST_PYTHON:-}" "$(command -v python3.13 || true)" /opt/homebrew/bin/python3.13 /usr/local/bin/python3.13 \
    /opt/homebrew/opt/python@3.13/bin/python3.13 /usr/local/opt/python@3.13/bin/python3.13 \
    /Library/Frameworks/Python.framework/Versions/3.13/bin/python3.13 "$HOME"/hostedtoolcache/Python/3.13.*/*/bin/python3.13 \
    "$HOME"/.pyenv/versions/3.13.*/bin/python3.13 "$HOME"/.local/share/uv/python/cpython-3.13*/bin/python3.13; do
    if [ -n "$p" ] && [ -x "$p" ] && [ -n "$MAGIC" ] && "$p" -I -c "import importlib.util, sys
sys.exit(int.from_bytes(importlib.util.MAGIC_NUMBER[:2], 'little') != $MAGIC)" 2>/dev/null; then
      HOST_PYTHON="$p"
      return
    fi
  done
}
find_host_python

KEY="$(cat "$SRC/.stamp")|$(shasum -a 256 "$0" | cut -d ' ' -f 1)|$PLATFORM_NAME|$ARCHS|$IPHONEOS_DEPLOYMENT_TARGET|$IDENTITY|$MODULES|$HOST_PYTHON"

# Copies a Mach-O file keeping only $ARCHS; with several inputs (one per architecture) joins them.
thin() {
  local out="$1" a f parts=()
  shift
  mkdir -p "$WORK/thin"
  for a in $ARCHS; do
    for f in "$@"; do
      if lipo "$f" -verify_arch "$a" 2>/dev/null; then
        if [ "$(lipo -archs "$f")" = "$a" ]; then cp "$f" "$WORK/thin/$a"; else lipo "$f" -thin "$a" -output "$WORK/thin/$a"; fi
        parts+=("$WORK/thin/$a")
        break
      fi
    done
  done
  [ ${#parts[@]} -gt 0 ] || { echo "error: $1 has no slice for $ARCHS" >&2; return 1; }
  if [ ${#parts[@]} -eq 1 ]; then mv "${parts[0]}" "$out"; else lipo -create "${parts[@]}" -output "$out"; fi
  rm -rf "$WORK/thin"
  chmod 755 "$out"
}

# Strips local symbols and leaves the binary unsigned (the edits above invalidate any signature it had).
finish_binary() {
  codesign --remove-signature "$1" 2>/dev/null || true
  xcrun strip -x -S "$1" 2>/dev/null || true
}

info_plist() {   # <plist> <executable> <bundle id>
  cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>$2</string>
	<key>CFBundleIdentifier</key>
	<string>$3</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$2</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>3.13</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>$SUPPORTED</string>
	</array>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>MinimumOSVersion</key>
	<string>$IPHONEOS_DEPLOYMENT_TARGET</string>
</dict>
</plist>
EOF
  plutil -convert binary1 "$1"
}

make_framework() {   # <name> <bundle id suffix>; the binary is already in place
  local dir="$STAGE/Frameworks/$1.framework"
  info_plist "$dir/Info.plist" "$1" "org.python.$2"
  finish_binary "$dir/$1"
  if [ -n "$IDENTITY" ]; then
    # shellcheck disable=SC2086
    codesign --force --sign "$IDENTITY" ${OTHER_CODE_SIGN_FLAGS:-} --timestamp=none "$dir" 2>&1 | grep -v "replacing existing signature" || true
    codesign --verify "$dir"
  fi
  echo "$1" >> "$STAGE/installed"
}

stage_frameworks() {
  local m a so name parts dir
  mkdir -p "$STAGE/Frameworks/Python.framework" "$STAGE/$DYNLOAD"
  thin "$STAGE/Frameworks/Python.framework/Python" "$SLICE/Python.framework/Python"
  install_name_tool -id @rpath/Python.framework/Python "$STAGE/Frameworks/Python.framework/Python" 2>/dev/null
  make_framework Python python
  for m in $MODULES; do
    parts=()
    so=
    for a in $ARCHS; do
      for name in "$SLICE/lib-$a/python3.13/lib-dynload/$m".*.so "$SLICE/lib-$a/python3.13/lib-dynload/$m.so"; do
        if [ -f "$name" ]; then parts+=("$name"); so=$(basename "$name" .so); fi
      done
    done
    if [ -z "$so" ]; then echo "note: $m is not an extension module of this runtime"; continue; fi
    dir="$STAGE/Frameworks/$m.framework"
    mkdir -p "$dir"
    thin "$dir/$m" "${parts[@]}"
    install_name_tool -id "@rpath/$m.framework/$m" "$dir/$m" 2>/dev/null
    printf '%s\n' "Frameworks/$m.framework/$m" > "$STAGE/$DYNLOAD/$so.fwork"
    printf '%s\n' "$DYNLOAD/$so.fwork" > "$dir/$m.origin"
    make_framework "$m" "ext.$(echo "$m" | sed -E 's/^_+/c-/; s/_/-/g')"
  done
}

stage_stdlib() {
  local pure="$WORK/pure" a exclude=()
  rm -rf "$pure"
  mkdir -p "$pure"
  # Development tools, GUIs, servers, databases, things iOS cannot do, and fallbacks for modules shipped as C.
  for a in __pycache__ '*.a' '*.txt' '*.rst' '*.ini' '*.orig' 'fetch_macholib*' README.ctypes 'config-*' lib-dynload site-packages test tests idlelib tkinter turtledemo turtle.py \
    ensurepip venv pydoc_data pydoc.py lib2to3 distutils sqlite3 curses dbm msilib multiprocessing xmlrpc wsgiref _pyrepl __phello__ \
    __hello__.py antigravity.py this.py doctest.py pdb.py bdb.py cmd.py cProfile.py profile.py pstats.py trace.py pickletools.py \
    pyclbr.py modulefinder.py tabnanny.py compileall.py zipapp.py rlcompleter.py webbrowser.py mailbox.py imaplib.py poplib.py \
    shelve.py wave.py pty.py tty.py _aix_support.py _android_support.py _osx_support.py _pyio.py _pydecimal.py _pydatetime.py \
    'encodings/mac_*' 'encodings/cp037*' 'encodings/cp1006*' 'encodings/cp1026*' 'encodings/cp1125*' 'encodings/cp1140*' \
    'encodings/cp273*' 'encodings/cp424*' 'encodings/cp500*' 'encodings/cp7*' 'encodings/cp85*' 'encodings/cp86*' 'encodings/cp87*' \
    'encodings/cp932*' 'encodings/cp949*' 'encodings/euc_*' 'encodings/iso2022*' 'encodings/shift_jis*' 'encodings/johab*' \
    'encodings/hp_roman8*' 'encodings/kz1048*' 'encodings/ptcp154*' 'encodings/palmos*' 'encodings/tis_620*' 'encodings/koi8_t*' \
    'encodings/big5hkscs*' 'encodings/mbcs*' 'encodings/oem*'; do
    exclude+=(--exclude "$a")
  done
  # Without _ssl the standard module cannot be imported anyway; leaving it out lets ios_site provide a stand-in.
  if [ "${IDJ_PYTHON_SSL:-0}" != 1 ]; then exclude+=(--exclude ssl.py); fi
  rsync -a "${exclude[@]}" "$LIB/" "$pure/"
  for a in $ARCHS; do cp "$SLICE/lib-$a/python3.13"/_sysconfigdata__*.py "$pure/" 2>/dev/null || true; done
  if [ -n "$HOST_PYTHON" ]; then
    "$HOST_PYTHON" -I -m compileall -q -b -o 2 --invalidation-mode unchecked-hash -s "$pure" -p python3.13 "$pure"
    find "$pure" -name '*.py' -delete
  else
    echo "note: no Python 3.13 on this Mac, shipping the standard library as source"
  fi
  find "$pure" -exec touch -h -t 198001020000 {} +
  mkdir -p "$STAGE/$HOME_DIR/lib"
  (cd "$pure" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | zip -0 -X -q -@ "$STAGE/$HOME_DIR/lib/stdlib.pyz")
  rm -rf "$pure"
}

up_to_date() {
  [ "$(cat "$WORK/installed.key" 2>/dev/null)" = "$KEY" ] && [ -f "$APP/$HOME_DIR/lib/stdlib.pyz" ] || return 1
  while read -r name; do [ -f "$APP/Frameworks/$name.framework/$name" ] || return 1; done < "$WORK/installed"
}
if up_to_date; then
  echo "note: Python runtime is up to date"
  exit 0
fi

if [ "$(cat "$WORK/key" 2>/dev/null)" != "$KEY" ]; then
  rm -rf "$STAGE" "$WORK/key"
  mkdir -p "$STAGE"
  stage_frameworks
  stage_stdlib
  printf '%s' "$KEY" > "$WORK/key"
fi

rm -f "$WORK/installed.key"
if [ -f "$WORK/installed" ] && ! cmp -s "$WORK/installed" "$STAGE/installed"; then remove_installed; fi
mkdir -p "$APP/Frameworks"
while read -r name; do
  rsync -a --delete "$STAGE/Frameworks/$name.framework" "$APP/Frameworks/"
done < "$STAGE/installed"
rsync -a --delete "$STAGE/$HOME_DIR" "$APP/"
cp "$STAGE/installed" "$WORK/installed"
printf '%s' "$KEY" > "$WORK/installed.key"
echo "note: Python runtime: $(wc -l < "$STAGE/installed" | tr -d ' ') frameworks"
