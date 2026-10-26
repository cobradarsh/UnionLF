#!/bin/bash
set -e
# Wingman — RootHide / ElleKit build (the script that built 1.6.0)
# Usage: THEOS=~/theos bash tools/build_roothide_linux.sh
#  - tweak dylib: arm64 (App Store chat apps are arm64), .jbroot install_name, real ldid
#  - settings: plist-only PreferenceLoader page (no executable -> no arm64e issue)

T="${THEOS:-$HOME/theos}"
SDK=$T/sdks/iPhoneOS16.5.sdk
PF=$SDK/System/Library/PrivateFrameworks
SRC="$(cd "$(dirname "$0")/.." && pwd)"
BUILD=$SRC/build_rh
CLANG="${CLANG:-$T/toolchain/linux/iphone/bin/clang}"
VER=$(grep '^Version:' $SRC/control | cut -d' ' -f2)

rm -rf "$BUILD"; mkdir -p "$BUILD/obj"
CFLAGS="-target arm64-apple-ios15.0 -isysroot $SDK -fobjc-arc -fno-modules -Wno-deprecated-declarations -I$T/vendor/include -I$SRC"

echo "== Logos =="
perl $T/bin/logos.pl "$SRC/Tweak.x" > "$BUILD/obj/Tweak_logos.m"

echo "== Compile =="
OBJS=()
for f in "$BUILD/obj/Tweak_logos.m" $SRC/WMBubble.m $SRC/WMCapture.m $SRC/WMSheet.m $SRC/WMAPIClient.m $SRC/WMPrompts.m $SRC/WMSettings.m $SRC/WMApps.m $SRC/WMQuickReplies.m $SRC/WMOCR.m $SRC/WMModels.m $SRC/WMContacts.m; do
  o="$BUILD/obj/$(basename $f).o"; $CLANG $CFLAGS -c "$f" -o "$o"; OBJS+=("$o"); echo "   $(basename $f)"
done

echo "== Link + sign =="
"${LD64:-ld64.lld-18}" -dylib -arch arm64 \
  -install_name "@loader_path/.jbroot/Library/MobileSubstrate/DynamicLibraries/Wingman.dylib" \
  -platform_version ios 15.0.0 16.5.0 -syslibroot "$SDK" \
  -L"$SDK/usr/lib" -F"$SDK/System/Library/Frameworks" -F"$PF" \
  -lobjc -lSystem -framework Foundation -framework CoreFoundation \
  -framework UIKit -framework CoreGraphics -framework QuartzCore -framework Vision \
  -o "$BUILD/Wingman.dylib" "${OBJS[@]}"
ldid -S "$BUILD/Wingman.dylib"

echo "== Icons =="
python3 - "$BUILD" << 'PY'
import sys
from PIL import Image, ImageDraw, ImageFont
out = sys.argv[1]
def icon(stem, glyph, rgb):
    for suffix, sz in (("", 29), ("@2x", 58), ("@3x", 87)):
        s = sz * 4
        im = Image.new("RGBA", (s, s), (0, 0, 0, 0)); d = ImageDraw.Draw(im)
        d.rounded_rectangle([0, 0, s-1, s-1], radius=int(s*0.22), fill=rgb + (255,))
        try: f = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", int(s*0.60))
        except Exception: f = ImageFont.load_default()
        b = d.textbbox((0, 0), glyph, font=f); w, h = b[2]-b[0], b[3]-b[1]
        d.text(((s-w)/2 - b[0], (s-h)/2 - b[1]), glyph, font=f, fill="white")
        im.resize((sz, sz), Image.LANCZOS).save(f"{out}/{stem}{suffix}.png")
icon("Wingman", "W", (77, 140, 255))
icon("WingmanApps", "A", (52, 160, 100))
PY

echo "== Package =="
PKG="$BUILD/pkg"
mkdir -p "$PKG/DEBIAN" "$PKG/Library/MobileSubstrate/DynamicLibraries" "$PKG/Library/PreferenceLoader/Preferences"
cp "$BUILD/Wingman.dylib" "$SRC/Wingman.plist" "$PKG/Library/MobileSubstrate/DynamicLibraries/"
cp "$SRC"/layout/Library/PreferenceLoader/Preferences/*.plist "$PKG/Library/PreferenceLoader/Preferences/"
cp "$BUILD"/Wingman*.png "$PKG/Library/PreferenceLoader/Preferences/"
python3 - "$PKG/Library/PreferenceLoader/Preferences" << 'PY'
import plistlib, glob, os, sys
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.plist"))):
    plistlib.load(open(f, "rb"))
    print("   plist OK:", os.path.basename(f))
PY

grep -v '^Installed-Size' "$SRC/control" > "$PKG/DEBIAN/control"
echo "Installed-Size: $(du -ks "$PKG/Library" | cut -f1)" >> "$PKG/DEBIAN/control"
find "$PKG" -type d -exec chmod 755 {} \; ; find "$PKG" -type f -exec chmod 644 {} \;
chmod 755 "$PKG/Library/MobileSubstrate/DynamicLibraries/Wingman.dylib"

DEB=$SRC/com.adarsh.wingman_${VER}_iphoneos-arm64e.deb
rm -f $SRC/*.deb
dpkg-deb --root-owner-group -Zxz -b "$PKG" "$DEB"
echo; file "$BUILD/Wingman.dylib"; dpkg-deb -I "$DEB" | grep -E 'Version|Architecture|Depends'; dpkg-deb -c "$DEB"
