#!/bin/bash
set -u
BR=/root/shuios/buildroot
echo "=== defconfig 里的 GTK/桌面相关 ==="
grep -E '^BR2_PACKAGE_(LIBGTK3|LIBGLIB2|HICOLOR|LIBRSVG|PANGO|FREETYPE|FONTCONFIG|ADWAITA)' \
	/root/shuios/br2-ext/configs/shuios_x86_64_defconfig || echo "(无)"
echo
echo "=== staging 里的 gtk 开发文件 ==="
ls "$BR/output/staging/usr/lib/pkgconfig/" 2>/dev/null | grep -iE 'gtk|glib|pango|cairo' || echo "(没有 pkgconfig 目录)"
echo
echo "=== 镜像 target 里有没有 GTK 运行库与图标主题 ==="
for f in /usr/lib/libgtk-3.so.0 /usr/share/icons/hicolor/index.theme /usr/lib/libgdk-3.so.0; do
	if [ -e "$BR/output/target$f" ]; then echo "$f: 有"; else echo "$f: 无"; fi
done
ls "$BR/output/target/usr/share/icons/" 2>/dev/null || echo "(没有 icons 目录)"
