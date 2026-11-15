#!/bin/bash
set -u
cd /tmp || exit 1
rm -rf waybar-src gls-src
mkdir -p waybar-src gls-src
tar -xzf /root/shuios-mirror/waybar-0.10.4.tar.gz -C waybar-src --strip-components=1
tar -xzf /root/shuios-mirror/gtk-layer-shell-0.9.0.tar.gz -C gls-src --strip-components=1

echo "########## waybar: meson_options.txt ##########"
cat waybar-src/meson_options.txt 2>/dev/null | head -50

echo
echo "########## waybar: meson.build 里的依赖 ##########"
grep -nE "dependency\(|meson.get_compiler|subproject" waybar-src/meson.build 2>/dev/null | head -30

echo
echo "########## gtk-layer-shell: 依赖 ##########"
grep -nE "dependency\(|pkg_check|wayland_scanner" gls-src/meson.build 2>/dev/null | head -15
echo "--- 协议文件在不在 ---"
ls gls-src/protocol 2>/dev/null | head -5
