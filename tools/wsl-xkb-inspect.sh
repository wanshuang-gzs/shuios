#!/bin/bash
set -u
BR=/root/shuios/buildroot
echo "=== libxkbcommon.mk ==="
grep -nE "DEPENDENCIES|CONF_OPTS|xkbregistry|XML" "$BR/package/libxkbcommon/libxkbcommon.mk" | head -20
echo
echo "=== Config.in ==="
cat "$BR/package/libxkbcommon/Config.in"
