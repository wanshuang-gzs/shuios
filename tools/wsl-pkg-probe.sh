#!/bin/bash
set -u
BR=/root/shuios/buildroot
echo "=== Buildroot 里有没有这些包 ==="
for p in libcurl curl mousepad galculator galculator2 gpicview leafpad xarchiver pcmanfm libfm nano; do
	if [ -d "$BR/package/$p" ]; then echo "$p: 有"; else echo "$p: 无"; fi
done
echo
echo "=== mousepad 的 Kconfig 依赖 ==="
sed -n '1,20p' "$BR/package/mousepad/Config.in" 2>/dev/null
echo
echo "=== galculator 的 Kconfig 依赖 ==="
sed -n '1,20p' "$BR/package/galculator/Config.in" 2>/dev/null
echo
echo "=== libcurl 的 curl 工具开关 ==="
grep -A4 'config BR2_PACKAGE_LIBCURL_CURL' "$BR/package/libcurl/Config.in" 2>/dev/null
