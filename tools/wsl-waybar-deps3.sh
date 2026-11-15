#!/bin/bash
set -u
BR=/root/shuios/buildroot
echo "=== waybar 里 xkbregistry 的用法 ==="
grep -n "xkbregistry" /tmp/waybar-src/meson.build | head -10

echo
echo "=== wayland-protocols 装到哪了 ==="
ls "$BR/output/staging/usr/share/wayland-protocols" 2>/dev/null | head -4
find "$BR/output/staging" -name "wayland-protocols*.pc" 2>/dev/null | head -3
grep -c "BR2_PACKAGE_WAYLAND_PROTOCOLS=y" "$BR/.config"

echo
echo "=== waybar 用到的 wayland 协议（需要 wayland-scanner） ==="
grep -nE "wayland_scanner|protocols" /tmp/waybar-src/meson.build | head -8
