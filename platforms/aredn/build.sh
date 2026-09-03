#! /bin/sh
set -e

VER=${CROW_VERSION:-0.0.2}
if [ -n "${CROW_RELEASE:-}" ]; then
    REL=$CROW_RELEASE
else
    REL=r$(($(date +%s) - $(date -d "2026-01-01 00:00:00" +%s)))
fi
VERSION=${VER}-${REL}
BUILD_EPOCH=${SOURCE_DATE_EPOCH:-$(date +%s)}
case "$BUILD_EPOCH" in
    ''|*[!0-9]*)
        echo "SOURCE_DATE_EPOCH must be an integer: $BUILD_EPOCH" >&2
        exit 1
        ;;
esac

ROOT=/tmp/crow-build-$$
SRC=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
GO_BIN=${GO_BIN:-go}
CROW_GOARCH=${CROW_GOARCH:-mips}
CROW_GOMIPS=${CROW_GOMIPS:-softfloat}
MKAPK=${CROW_MKAPK:-$SRC/tools/mkapk.py}

trap 'rm -rf "$ROOT"' EXIT HUP INT TERM

mkdir -p "$ROOT/data/www/cgi-bin/apps/crow" \
    "$ROOT/data/www/apps/crow" \
    "$ROOT/data/usr/local/crow/platforms/aredn" "$ROOT/data/usr/local/crow/crypto" \
    "$ROOT/data/etc/init.d" \
    "$ROOT/data/etc/local/mesh-firewall" \
    "$ROOT/data/etc/arednsysupgrade.d"

cp "$SRC/platforms/aredn/firewall" "$ROOT/data/etc/local/mesh-firewall/21-crow"

cp "$SRC"/*.uc "$ROOT/data/usr/local/crow/"
# Remove raven.uc (APRS app, not part of Crow LoRa router)
rm -f "$ROOT/data/usr/local/crow/raven.uc"
# Keep parser/framing hooks available to source-level tests, but do not ship
# them to constrained nodes. Marked blocks must be balanced in every module.
for module in "$ROOT/data/usr/local/crow"/*.uc; do
    stripped="$module.release"
    awk '
        /CROW_TEST_HOOKS_BEGIN/ {
            if (skip) exit 2
            skip = 1
            next
        }
        /CROW_TEST_HOOKS_END/ {
            if (!skip) exit 3
            skip = 0
            next
        }
        !skip { print }
        END { if (skip) exit 4 }
    ' "$module" > "$stripped" || {
        echo "Unbalanced test-hook markers in $module" >&2
        exit 1
    }
    mv "$stripped" "$module"
done
if grep -R -n -E 'CROW_TEST_HOOKS|export (function|const) _test_|ForTest' "$ROOT/data/usr/local/crow"; then
    echo "Development test hooks leaked into the release payload" >&2
    exit 1
fi
cp "$SRC"/crypto/*.uc "$ROOT/data/usr/local/crow/crypto/"
cp "$SRC"/platforms/aredn/*.uc "$ROOT/data/usr/local/crow/platforms/aredn/"
cp "$SRC/platforms/aredn/raven.conf" "$ROOT/data/usr/local/crow/crow.conf"
cp "$SRC/platforms/aredn/crow-migrate-raven.sh" "$ROOT/data/usr/local/crow/platforms/aredn/crow-migrate-raven.sh"
cp "$SRC/platforms/aredn/crow-runner.sh" "$ROOT/data/usr/local/crow/platforms/aredn/crow-runner.sh"
cp "$SRC/platforms/aredn/crow-watchdog.sh" "$ROOT/data/usr/local/crow/platforms/aredn/crow-watchdog.sh"
if ! command -v "$GO_BIN" >/dev/null 2>&1; then
    echo "Go is required to build the AREDN crow-rawtty helper (set GO_BIN or install go)." >&2
    exit 1
fi
(cd "$SRC" && GO111MODULE=off GOOS=linux GOARCH="$CROW_GOARCH" GOMIPS="$CROW_GOMIPS" CGO_ENABLED=0 "$GO_BIN" build \
    -trimpath -ldflags='-s -w' \
    -o "$ROOT/data/usr/local/crow/crow-rawtty" \
    ./tools/crow-rawtty)
chmod 755 "$ROOT/data/usr/local/crow/crow-rawtty"
printf "export const version = '%s';\n" "$VERSION" > "$ROOT/data/usr/local/crow/version.uc"

cp "$SRC/ui/ui.js" "$SRC/ui/ui.css" "$SRC/ui/crow.svg" "$ROOT/data/www/apps/crow/"
sed "s:0.0.0-r0:${VERSION}:" "$SRC/ui/index.html" > "$ROOT/data/www/apps/crow/index.html"
cp "$SRC/ui/crow.svg" "$ROOT/data/www/apps/crow/icon.svg"
cp "$SRC/ui/crow.png" "$ROOT/data/www/apps/crow/ix.png"
cp "$SRC/platforms/aredn/admin.sh" "$ROOT/data/www/cgi-bin/apps/crow/admin"
cp "$SRC/platforms/aredn/image.uc" "$ROOT/data/www/cgi-bin/apps/crow/image"

cp "$SRC/platforms/aredn/crow.init" "$ROOT/data/etc/init.d/crow"
cp "$SRC/platforms/aredn/crow-watchdog.init" "$ROOT/data/etc/init.d/crow-watchdog"

cp "$SRC/platforms/aredn/upgrade.conf" "$ROOT/data/etc/arednsysupgrade.d/crow.conf"

chmod 755 "$ROOT/data/etc/local/mesh-firewall/21-crow" "$ROOT/data/etc/init.d/crow" "$ROOT/data/etc/init.d/crow-watchdog"
chmod 755 "$ROOT/data/www/apps/crow"/* "$ROOT/data/www/cgi-bin/apps/crow/admin" "$ROOT/data/www/cgi-bin/apps/crow/image"
chmod 755 "$ROOT/data/usr/local/crow/platforms/aredn/crow-runner.sh" "$ROOT/data/usr/local/crow/platforms/aredn/crow-migrate-raven.sh" "$ROOT/data/usr/local/crow/platforms/aredn/crow-watchdog.sh"

mkdir -p "$ROOT/data/usr/local/crow/winlink/forms"
cp -R "$SRC/winlink/forms"/* "$ROOT/data/usr/local/crow/winlink/forms"

cp "$SRC/platforms/aredn/usb-setup.sh" "$ROOT/data/usr/local/crow/platforms/aredn/usb-setup.sh"
chmod 755 "$ROOT/data/usr/local/crow/platforms/aredn/usb-setup.sh"
chmod 755 "$ROOT/data/usr/local/crow/platforms/aredn/crow-migrate-raven.sh"


#
# Make IPKG
#
mkdir -p "$ROOT/control"
cat > "$ROOT/debian-binary" <<__EOF__
2.0
__EOF__
cat > "$ROOT/control/control" <<__EOF__
Package: crow
Version: ${VERSION}
Depends: ucode, curl
Provides:
Source: package/crow
Section: net
Priority: optional
Maintainer: Crow Contributors
Architecture: all
Description: Crow Mesh Messaging
__EOF__
cp "$SRC/platforms/aredn/postinst" "$ROOT/control/postinst"
cp "$SRC/platforms/aredn/prerm" "$ROOT/control/prerm"
printf '%s\n' '/usr/local/crow/crow.conf' > "$ROOT/control/conffiles"
chmod 755 "$ROOT/control/postinst" "$ROOT/control/prerm"

(cd "$ROOT/control" && tar --sort=name --mtime="@${BUILD_EPOCH}" --owner=0 --group=0 --numeric-owner -czf ../control.tar.gz .)
(cd "$ROOT/data" && tar --sort=name --mtime="@${BUILD_EPOCH}" --owner=0 --group=0 --numeric-owner -czf ../data.tar.gz .)
(cd "$ROOT" && tar --sort=name --mtime="@${BUILD_EPOCH}" --owner=0 --group=0 --numeric-owner -czf "crow_${VERSION}_all.ipk" control.tar.gz data.tar.gz debian-binary)

rm -f "./crow_${VERSION}_all.ipk"
mv "$ROOT/crow_${VERSION}_all.ipk" .

#
# Make APK
#
rm -f "./crow-${VERSION}.apk"
if [ ! -x "$MKAPK" ]; then
    echo "mkapk.py not found and vendored fallback is not executable: $MKAPK" >&2
    exit 1
fi
cp "$SRC/platforms/aredn/postinstall" "$ROOT/data/.post-install"
cp "$SRC/platforms/aredn/prerm" "$ROOT/data/.pre-deinstall"
cp "$SRC/platforms/aredn/preupgrade" "$ROOT/data/.pre-upgrade"
cp "$SRC/platforms/aredn/postupgrade" "$ROOT/data/.post-upgrade"
chmod 755 "$ROOT/data/.post-install" "$ROOT/data/.pre-deinstall" "$ROOT/data/.pre-upgrade" "$ROOT/data/.post-upgrade"
"$MKAPK" \
    -n crow \
    -v "$VER" \
    -d "$ROOT/data" \
    -a noarch \
    -r "$REL" \
    -D 'Crow Mesh Messaging' \
    -u 'https://github.com/mathisono/Crow' \
    -l 'MIT' \
    -m 'crow@localhost' \
    -p ucode,curl \
    -o .

rm -f ./crow_alpha.ipk ./crow-alpha.apk
cp "crow_${VERSION}_all.ipk" crow_alpha.ipk
cp "crow-${VERSION}.apk" crow-alpha.apk
