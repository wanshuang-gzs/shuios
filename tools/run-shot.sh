#!/bin/bash
# 一键：清理残留 QEMU → 启动 → 截图 → 汇报。
# 用法：wsl -d shui-build -u root -- bash /mnt/d/shuios/tools/run-shot.sh [镜像] [等待秒]
set -u

IMG="${1:-/root/test.img}"
WAIT="${2:-150}"
PNG=/mnt/d/shuios/shuios-desktop.png

pkill -9 -f qemu-system 2>/dev/null || true
sleep 1
rm -f /tmp/shuios-shot.ppm /tmp/shuios-mon.sock /tmp/shuios-serial.log /tmp/qs.out

cp -f /mnt/d/shuios/tools/qemu-screenshot-v2.sh /tmp/qs.sh

timeout 400 bash /tmp/qs.sh "$IMG" "$WAIT" "$PNG" > /tmp/qs.out 2>&1
echo "rc=$?"

echo "=== qs.out 尾部 ==="
tail -n 12 /tmp/qs.out

echo "=== 串口关键行 ==="
grep -a 'Started shuios' /tmp/shuios-serial.log 2>/dev/null | tail -6
grep -a 'login:' /tmp/shuios-serial.log 2>/dev/null | tail -2

echo "=== 截图文件 ==="
ls -l "$PNG" /tmp/shuios-shot.ppm 2>/dev/null

echo "=== 像素分析 ==="
[ -f /tmp/shuios-shot.ppm ] && python3 /tmp/an.py 2>/dev/null || echo "(没有 PPM)"
