#! /bin/sh

VER=0.0.1
REL=r$(($(date +%s) - $(date -d "2026-01-01 00:00:00" +%s)))
VERSION=${VER}-${REL}

ROOT=/tmp/crow-build-$$
SRC=$(dirname $0)/../..

rm -rf $ROOT/

mkdir -p $ROOT/data/www/cgi-bin/apps/crow \
    $ROOT/data/www/apps/crow \
    $ROOT/data/usr/local/crow/platforms/aredn $ROOT/data/usr/local/crow/crypto \
    $ROOT/data/etc/init.d \
    $ROOT/data/etc/local/mesh-firewall \
    $ROOT/data/etc/arednsysupgrade.d

cp $SRC/platforms/aredn/firewall $ROOT/data/etc/local/mesh-firewall/21-crow

cp $SRC/*.uc $ROOT/data/usr/local/crow/
cp $SRC/crypto/*.uc $ROOT/data/usr/local/crow/crypto/
cp $SRC/platforms/aredn/*.uc $ROOT/data/usr/local/crow/platforms/aredn/
cp $SRC/platforms/aredn/raven.conf $ROOT/data/usr/local/crow/crow.conf
cp $SRC/platforms/aredn/crow-migrate-raven.sh $ROOT/data/usr/local/crow/platforms/aredn/crow-migrate-raven.sh
echo "export const version = '${VERSION}';" > $ROOT/data/usr/local/crow/version.uc

cp $SRC/ui/ui.js $SRC/ui/ui.css $SRC/ui/crow.svg $ROOT/data/www/apps/crow/
cat $SRC/ui/index.html | sed s:0.0.0-r0:${VERSION}: > $ROOT/data/www/apps/crow/index.html
cp $SRC/ui/crow.svg $ROOT/data/www/apps/crow/icon.svg
cp $SRC/ui/crow.png $ROOT/data/www/apps/crow/ix.png
cp $SRC/platforms/aredn/admin.sh $ROOT/data/www/cgi-bin/apps/crow/admin
cp $SRC/platforms/aredn/image.uc $ROOT/data/www/cgi-bin/apps/crow/image

cp $SRC/platforms/aredn/raven.init $ROOT/data/etc/init.d/crow

cp $SRC/platforms/aredn/upgrade.conf $ROOT/data/etc/arednsysupgrade.d/KJ6DZB.crow.conf

chmod 755 $ROOT/data/etc/local/mesh-firewall/21-crow
chmod 755 $ROOT/data/www/apps/crow/* $ROOT/data/www/cgi-bin/apps/crow/admin $ROOT/data/www/cgi-bin/apps/crow/image

mkdir -p $ROOT/data/usr/local/crow/winlink/forms
cp -R $SRC/winlink/forms/* $ROOT/data/usr/local/crow/winlink/forms

cp $SRC/platforms/aredn/usb-setup.sh $ROOT/data/usr/local/crow/platforms/aredn/usb-setup.sh
chmod 755 $ROOT/data/usr/local/crow/platforms/aredn/usb-setup.sh
chmod 755 $ROOT/data/usr/local/crow/platforms/aredn/crow-migrate-raven.sh


#
# Make IPKG
#
mkdir -p $ROOT/control
cat > $ROOT/debian-binary <<__EOF__
2.0
__EOF__
cat > $ROOT/control/control <<__EOF__
Package: crow
Version: ${VERSION}
Depends: ucode, curl
Provides:
Source: package/crow
Section: net
Priority: optional
Maintainer: Mathison Ott (KJ6DZB)
Architecture: all
Description: Crow Mesh Messaging
__EOF__
cp $SRC/platforms/aredn/postinst $ROOT/control/postinst
cp $SRC/platforms/aredn/prerm $ROOT/control/prerm
chmod 755 $ROOT/control/postinst $ROOT/control/prerm

(cd $ROOT/control ; tar cfz ../control.tar.gz .)
(cd $ROOT/data ; tar cfz ../data.tar.gz .)
(cd $ROOT ; tar cfz crow_${VERSION}_all.ipk control.tar.gz data.tar.gz debian-binary)

rm -f ./crow_*_all.ipk
mv $ROOT/crow_${VERSION}_all.ipk .

#
# Make APK
#
rm -f ./crow-*.apk
cp $SRC/platforms/aredn/postinstall $ROOT/data/.post-install
cp $SRC/platforms/aredn/prerm $ROOT/data/.pre-deinstall
cp $SRC/platforms/aredn/postupgrade $ROOT/data/.post-upgrade
chmod 755 $ROOT/data/.post-install $ROOT/data/.pre-deinstall $ROOT/data/.post-upgrade
mkapk.py \
    -n crow \
    -v ${VER} \
    -d ${ROOT}/data \
    -a noarch \
    -r ${REL} \
    -D 'Crow Mesh Messaging' \
    -u 'https://github.com/mathisono/Crow' \
    -l 'MIT' \
    -m 'mathisono@users.noreply.github.com' \
    -p ucode,curl \
    -o .

cp -r crow_${VERSION}_all.ipk crow_alpha.ipk
cp -f crow-${VERSION}.apk crow-alpha.apk

rm -rf $ROOT/
