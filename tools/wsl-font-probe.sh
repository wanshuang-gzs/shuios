#!/bin/bash
set -u
BR=/root/shuios/buildroot
echo "=== 名字里带 font/noto/wqy/liberation/dejavu/sazanami 的包 ==="
for d in "$BR"/package/*/; do
	n=$(basename "$d")
	case "$n" in
		*font*|noto*|wqy*|liberation*|dejavu*|sazanami*|*cjk*) echo "  $n" ;;
	esac
done
echo
echo "=== Config.in 里出现 CJK 字样的包 ==="
grep -ril "cjk" "$BR"/package/*/Config.in 2>/dev/null | sed 's#.*/package/##; s#/Config.in##'
echo
echo "=== fontconfig 相关的 target 目录 ==="
ls "$BR/output/target/usr/share/fonts/" 2>/dev/null
echo
echo "=== 已启用的字体相关配置项 ==="
grep -E '^BR2_PACKAGE_(DEJAVU|LIBERATION|NOTO|WQY|SAZANAMI|FONTCONFIG)' "$BR/.config" || echo "(无)"
