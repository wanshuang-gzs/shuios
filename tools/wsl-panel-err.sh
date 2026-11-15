#!/bin/bash
set -u
grep -nE "error|warning" /tmp/shui-panel-rebuild.log 2>/dev/null | head -20
echo "----- 上下文 -----"
sed -n '250,275p' /root/shuios/br2-ext/package/shui-panel/src/shui-panel.c 2>/dev/null
