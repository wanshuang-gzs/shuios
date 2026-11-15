#!/bin/bash
set -u
BR=/root/shuios/buildroot
echo "=== pcmanfm Config.in ==="
cat "$BR/package/pcmanfm/Config.in" 2>/dev/null
echo
echo "=== libfm Config.in ==="
cat "$BR/package/libfm/Config.in" 2>/dev/null
echo
echo "=== pcmanfm.mk 关键行 ==="
grep -E 'GTK|DEPENDENCIES|CONF_OPTS' "$BR/package/pcmanfm/pcmanfm.mk" 2>/dev/null
