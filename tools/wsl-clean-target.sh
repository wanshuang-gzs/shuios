#!/bin/bash
# 清掉 target 里上一轮失败遗留的额外文件
set -u
TGT=/root/shuios/buildroot/output/target
for f in /usr/bin/htop \
	/usr/share/icons/hicolor/scalable/apps/htop.svg \
	/usr/share/applications/htop.desktop \
	/usr/share/pixmaps/htop.png \
	/usr/share/man/man1/htop.1; do
	rm -f "$TGT$f"
done
if [ -e "$TGT/usr/bin/htop" ]; then
	echo "! 还有残留"
else
	echo "✓ htop 残留已清理"
fi
ls "$TGT/usr/lib/" | grep -c mbedtls | sed 's/^/mbedtls 文件数: /'
