#!/bin/bash
set -u
S=/root/shuios/buildroot/output/build/waybar-0.10.4
echo "=== meson 里有没有 HAVE_XKBREGISTRY 宏 ==="
grep -n "XKBREGISTRY\|xkbregistry" "$S/meson.build" | head -10

echo
echo "=== language.hpp 的内容 ==="
sed -n '1,20p' "$S/include/modules/sway/language.hpp" 2>/dev/null

echo
echo "=== factory.cpp 里 language 的注册 ==="
grep -n "language" "$S/src/factory.cpp" | head -5

echo
echo "=== language.cpp 开头 ==="
sed -n '1,12p' "$S/src/modules/sway/language.cpp" 2>/dev/null
