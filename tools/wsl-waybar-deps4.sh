#!/bin/bash
set -u
BR=/root/shuios/buildroot
echo "=== wayland-protocols 的 .pc 在哪 ==="
find "$BR/output" -name "wayland-protocols.pc" 2>/dev/null | head -5
echo "--- host 里的 pkgconfig 目录 ---"
ls "$BR/output/host/share/pkgconfig" 2>/dev/null | head -10

echo
echo "=== waybar meson.build 第 505-525 行 ==="
sed -n '505,525p' /tmp/waybar-src/meson.build

echo
echo "=== waybar 里 deps 列表的定义（看 518 行属于哪个变量） ==="
sed -n '495,520p' /tmp/waybar-src/meson.build
