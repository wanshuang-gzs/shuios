#!/bin/bash
set -u
BR=/root/shuios/buildroot
echo "=== Buildroot 里的终端模拟器 ==="
for p in foot alacritty kitty wezterm st rxvt-unicode xterm terminitor sakura lxterminal; do
	if [ -d "$BR/package/$p" ]; then
		v=$(grep -hE "^$（echo)${p}_VERSION" "$BR/package/$p/$p.mk" 2>/dev/null | head -1)
		echo "  ✓ $p  $(grep -hoE 'VERSION = .*' "$BR/package/$p/$p.mk" 2>/dev/null | head -1)"
	else
		echo "  ✗ $p"
	fi
done

echo
echo "=== 我们镜像里 foot 的来源版本 ==="
grep -hoE 'FOOT_VERSION = .*' "$BR/package/foot/foot.mk" 2>/dev/null
grep -n "foot" /root/shuios/br2-ext/configs/shuios_x86_64_defconfig | head -3

echo
echo "=== mirror 里有哪些 foot 源码 ==="
ls /root/shuios-mirror 2>/dev/null | grep -i foot | head -5
