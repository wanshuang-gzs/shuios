#!/bin/sh
# 检查 sway 及其依赖在 .config 里的实际状态
set -u
C=/root/shuios/buildroot/.config

for k in BR2_PACKAGE_SWAY BR2_PACKAGE_SWAY_SWAYBAR BR2_PACKAGE_SWAY_SWAYBAR_TRAY \
         BR2_PACKAGE_SWAYBG BR2_PACKAGE_WLROOTS BR2_PACKAGE_HAS_LIBEGL \
         BR2_PACKAGE_HAS_LIBGLES BR2_PACKAGE_HAS_UDEV BR2_PACKAGE_JSON_C \
         BR2_PACKAGE_PCRE2 BR2_PACKAGE_PCRE BR2_PACKAGE_PANGO BR2_PACKAGE_CAIRO \
         BR2_PACKAGE_DMENU_WAYLAND BR2_PACKAGE_MESA3D_OPENGL_ES; do
	v="$(grep -E "^${k}=" "$C" 2>/dev/null || true)"
	if [ -n "$v" ]; then echo "  $v"; else echo "  ${k}  (未设置)"; fi
done

echo
echo "===== 依赖不满足的提示行 ====="
grep -a -i "sway" /tmp/repack4.log 2>/dev/null | head -5
make -s -C /root/shuios/buildroot BR2_EXTERNAL=/root/shuios/br2-ext show-info 2>/dev/null | sed -n '/^{/,$p' | python3 -c '
import json,sys
d=json.load(sys.stdin)
for name in ("sway","wlroots","swaybg"):
    v=d.get(name)
    if not v:
        print(f"  {name}: 不在 show-info（未启用）")
    else:
        print(f"  {name}: version={v.get(\"version\")} dependencies={v.get(\"dependencies\")}")
'
