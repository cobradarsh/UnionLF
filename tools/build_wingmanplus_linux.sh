#!/bin/bash
set -e
# Wingman Plus — RootHide / ElleKit build (Linux, no macOS needed).
# SpringBoard-only tweak: one dylib, injected via WingmanPlus.plist into
# com.apple.springboard. No PreferenceLoader bundle (settings live in-app).
# Usage: THEOS=~/theos bash tools/build_wingmanplus_linux.sh

T="${THEOS:-$HOME/theos}"
SDK=$T/sdks/iPhoneOS16.5.sdk
PF=$SDK/System/Library/PrivateFrameworks
SRC="$(cd "$(dirname "$0")/.." && pwd)"
BUILD=$SRC/build_rh
CLANG="${CLANG:-$T/toolchain/linux/iphone/bin/clang}"
VER=$(grep '^Version:' $SRC/control | cut -d' ' -f2)

rm -rf "$BUILD"; mkdir -p "$BUILD/obj"
# SpringBoard (our only injection target) is an arm64e platform binary on A12+.
# An arm64 dylib cannot load into an arm64e process, so we build arm64e.
CFLAGS="-target arm64e-apple-ios15.0 -isysroot $SDK -fobjc-arc -fno-modules -Wno-deprecated-declarations -I$T/vendor/include -I$SRC"

echo "== Logos =="
perl $T/bin/logos.pl "$SRC/Tweak.x" > "$BUILD/obj/Tweak_logos.m"

echo "== Compile =="
OBJS=()
for f in "$BUILD/obj/Tweak_logos.m" \
         $SRC/WPBubble.m $SRC/WPCapture.m $SRC/WPHost.m $SRC/WPSheet.m \
         $SRC/WMAPIClient.m $SRC/WMPrompts.m $SRC/WMSettings.m $SRC/WMApps.m $SRC/WMOCR.m $SRC/WMModels.m; do
  o="$BUILD/obj/$(basename $f).o"; $CLANG $CFLAGS -c "$f" -o "$o"; OBJS+=("$o"); echo "   $(basename $f)"
done

echo "== Link + sign =="
# Link through the roothide toolchain's clang driver (NOT system ld64.lld-18):
# lld can't emit arm64e authenticated-pointer relocations, but the toolchain's
# own linker can. clang auto-links libobjc/libSystem.
"$CLANG" -dynamiclib -target arm64e-apple-ios15.0 -isysroot "$SDK" \
  -install_name "@loader_path/.jbroot/Library/MobileSubstrate/DynamicLibraries/WingmanPlus.dylib" \
  -F"$SDK/System/Library/Frameworks" -F"$PF" \
  -framework Foundation -framework CoreFoundation \
  -framework UIKit -framework CoreGraphics -framework QuartzCore -framework Vision \
  -o "$BUILD/WingmanPlus.dylib" "${OBJS[@]}"
ldid -S "$BUILD/WingmanPlus.dylib"

echo "== Package =="
PKG="$BUILD/pkg"
mkdir -p "$PKG/DEBIAN" "$PKG/Library/MobileSubstrate/DynamicLibraries"
cp "$BUILD/WingmanPlus.dylib" "$SRC/WingmanPlus.plist" "$PKG/Library/MobileSubstrate/DynamicLibraries/"

grep -v '^Installed-Size' "$SRC/control" > "$PKG/DEBIAN/control"
echo "Installed-Size: $(du -ks "$PKG/Library" | cut -f1)" >> "$PKG/DEBIAN/control"
find "$PKG" -type d -exec chmod 755 {} \; ; find "$PKG" -type f -exec chmod 644 {} \;
chmod 755 "$PKG/Library/MobileSubstrate/DynamicLibraries/WingmanPlus.dylib"

DEB=$SRC/com.adarsh.wingmanplus_${VER}_iphoneos-arm64e.deb
rm -f $SRC/*.deb
dpkg-deb --root-owner-group -Zxz -b "$PKG" "$DEB"
echo; file "$BUILD/WingmanPlus.dylib"; dpkg-deb -I "$DEB" | grep -E 'Version|Architecture|Depends'; dpkg-deb -c "$DEB"
