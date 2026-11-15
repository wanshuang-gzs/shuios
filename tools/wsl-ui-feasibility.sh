#!/bin/bash
set -u
BR=/root/shuios/buildroot
echo "=== Buildroot 里有没有这些（都会大幅降低难度） ==="
for p in gtk-layer-shell waybar layer-shell hicolor-icon-theme adwaita-icon-theme elementary-icon-theme papirus-icon-theme lxde-icon-theme arc-theme adapta-gtk-theme python3 meson; do
	if [ -d "$BR/package/$p" ]; then echo "  ✓ $p"; else echo "  ✗ $p"; fi
done

echo
echo "=== staging 里有没有 layer-shell 协议（做真面板要用） ==="
find "$BR/output/staging" -name "*layer-shell*" 2>/dev/null | head -5
find /root/shuios/buildroot -name "wlr-layer-shell*.xml" 2>/dev/null | head -3

echo
echo "=== host 有没有 wayland-scanner（协议代码生成器） ==="
ls -l "$BR/output/host/bin/wayland-scanner" 2>/dev/null || echo "  ✗ 没有"

echo
echo "=== 我们自己的应用有多大（衡量"自研"成本） ==="
wc -l /root/shuios/br2-ext/package/shui-panel/src/shui-panel.c \
      /root/shuios/br2-ext/package/shui-store/src/shui-store.c 2>/dev/null
