#!/bin/bash
set -u
BR=/root/shuios/buildroot
PC=$BR/output/staging/usr/lib/pkgconfig
echo "=== staging 里现有的 pkg-config 文件 ==="
for n in xkbregistry xkbcommon wayland-client wayland-cursor wayland-protocols jsoncpp fmt spdlog "sigc++-2.0" "gtkmm-3.0" "gtk-layer-shell-0" "libnl-3.0" "gio-unix-2.0"; do
	f="$PC/$n.pc"
	if [ -f "$f" ]; then
		printf "  ✓ %-22s %s\n" "$n" "$(grep -m1 '^Version:' "$f" | cut -d' ' -f2)"
	else
		printf "  ✗ %-22s (缺)\n" "$n"
	fi
done

echo
echo "=== 已启用/可用的相关包（Buildroot 里是否存在） ==="
for p in libxkbcommon jsoncpp fmt spdlog libsigc gtkmm3 glibmm cairomm pangomm atkmm libnl; do
	[ -d "$BR/package/$p" ] && echo "  ✓ $p  $(grep -hoE 'VERSION = [^ ]+' "$BR/package/$p/$p.mk" 2>/dev/null | head -1)" || echo "  ✗ $p"
done

echo
echo "=== libxkbcommon 的 xkbregistry 支持 ==="
grep -nE "xkbregistry|XML|libxml" "$BR/package/libxkbcommon/libxkbcommon.mk" 2>/dev/null | head -8
