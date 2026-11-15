#!/bin/bash
# 把 waybar / gtk-layer-shell 源码放进仓库的 br2-ext/dl（用 file:// 站点，离线可复现）
set -u
mkdir -p /mnt/d/shuios/br2-ext/dl
cp -f /root/shuios-mirror/waybar-0.10.4.tar.gz /mnt/d/shuios/br2-ext/dl/ 2>/dev/null
cp -f /root/shuios-mirror/gtk-layer-shell-0.9.0.tar.gz /mnt/d/shuios/br2-ext/dl/ 2>/dev/null
ls -l /mnt/d/shuios/br2-ext/dl/
