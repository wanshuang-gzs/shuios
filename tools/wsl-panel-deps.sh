#!/bin/bash
set -u
BR=/root/shuios/buildroot
echo "=== 现成面板 / 任务栏 ==="
for p in waybar yambar sfwbar nwg-panel nwg-bar swaybar swaybg wlogout nwg-drawer; do
	if [ -d "$BR/package/$p" ]; then echo "  ✓ $p  $(grep -hoE 'VERSION = [^ ]+' "$BR/package/$p/$p.mk" 2>/dev/null | head -1)"; else echo "  ✗ $p"; fi
done

echo
echo "=== waybar 的依赖链（逐项看有没有） ==="
for p in gtkmm3 glibmm cairomm pangomm atkmm libsigc libsigcxx fmt spdlog jsoncpp nlohmann-json gtk-layer-shell wayland-protocols libnl pulseaudio libmpdclient playerctl libdbusmenu; do
	if [ -d "$BR/package/$p" ]; then echo "  ✓ $p"; else echo "  ✗ $p"; fi
done

echo
echo "=== yambar 的依赖 ==="
for p in libyaml fcft pixman libxkbcommon wayland wayland-protocols; do
	if [ -d "$BR/package/$p" ]; then echo "  ✓ $p"; else echo "  ✗ $p"; fi
done
