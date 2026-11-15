#!/bin/sh
# 查看 plymouth 包的可选项与构建方式
set -u
P=/root/shuios/buildroot/package/plymouth
echo "===== Config.in ====="
cat "$P/Config.in" 2>/dev/null | head -60
echo
echo "===== plymouth.mk 关键行 ====="
grep -E 'VERSION|CONF_OPTS|INSTALL_INIT|SYSTEMD|THEME|dependencies' "$P/plymouth.mk" 2>/dev/null | head -25
echo
echo "===== 是否自带主题 ====="
ls "$P" 2>/dev/null
