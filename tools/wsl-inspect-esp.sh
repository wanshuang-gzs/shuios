#!/bin/bash
# 挂载镜像检查 ESP：内核在不在、grub.cfg 是什么
set -u
IMG=/root/test.img
MNT=/mnt/imgcheck
mkdir -p "$MNT"
LOOP=$(losetup --find --show --partscan "$IMG") || { echo "losetup 失败"; exit 1; }
echo "loop=$LOOP"
ls -l "${LOOP}"* 2>/dev/null
sleep 1
mount "${LOOP}p1" "$MNT" 2>/dev/null || { echo "挂载 ESP 失败"; losetup -d "$LOOP"; exit 1; }

echo "=== ESP 内容 ==="
ls -l "$MNT" | head -8
echo "--- /EFI/BOOT ---"
ls -l "$MNT/EFI/BOOT" | head -10
echo "--- 内核大小 ---"
ls -l "$MNT/Image" 2>/dev/null || echo "(没有 /Image)"
echo "--- 剩余空间 ---"
df -h "$MNT" | tail -1
echo "--- grub.cfg 前 20 行 ---"
sed -n '1,20p' "$MNT/EFI/BOOT/grub.cfg" 2>/dev/null

umount "$MNT"
losetup -d "$LOOP"
echo "已卸载"
