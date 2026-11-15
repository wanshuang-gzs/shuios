#!/bin/bash
set -u
BR=/root/shuios/buildroot
echo "=== 候选浏览器 / 引擎 ==="
for p in netsurf netsurf-fb wpewebkit wpebackend-fdo cog webkitgtk webkit2gtk epiphany midori dillo links links2 w3m lynx elinks chromium firefox qutebrowser luakit surf; do
	if [ -d "$BR/package/$p" ]; then
		v=$(grep -hoE '^[A-Z0-9_]+_VERSION = .*' "$BR/package/$p/$p.mk" 2>/dev/null | head -1)
		echo "  ✓ $p   $v"
	else
		echo "  ✗ $p"
	fi
done

echo
echo "=== netsurf 上次失败的那步（gresource） ==="
grep -rn "gresource" "$BR/package/netsurf/netsurf.mk" 2>/dev/null | head -5
ls "$BR/output/build/netsurf-"*/ 2>/dev/null | head -3
