#!/bin/sh
# ═══════════════════════════════════════════════════════════
#  shuios post-image 脚本
#  镜像生成后执行：改名、输出使用说明
# ═══════════════════════════════════════════════════════════

set -e
BINARIES_DIR="$1"

echo "── post-image: 整理氵系统镜像 ──"

cd "$BINARIES_DIR"

VERSION=$(date -u '+%Y%m%d')

# ── 重命名 ISO ────────────────────────────────────────────
if [ -f rootfs.iso9660 ]; then
    NEW="shuios-${VERSION}-x86_64.iso"
    mv rootfs.iso9660 "$NEW"
    echo "   ISO: $NEW"
    echo "   大小: $(du -h "$NEW" | cut -f1)"
fi

# ── 重命名磁盘镜像 ────────────────────────────────────────
if [ -f sdcard.img ]; then
    mv sdcard.img "shuios-${VERSION}-x86_64.img"
    echo "   IMG: shuios-${VERSION}-x86_64.img"
fi

# ── 使用说明 ──────────────────────────────────────────────
cat > 使用说明.txt <<'EOF'
氵系统 shuios
═════════════════════════════

【怎么装到 U 盘】
  Linux/macOS:
    sudo dd if=shuios-*.iso of=/dev/sdX bs=4M status=progress oflag=sync

  Windows:
    用 Rufus 或 balenaEtcher 写入 U 盘

  注意: /dev/sdX 换成你 U 盘的实际设备名，写错会毁掉你的硬盘。

【怎么启动】
  插上 U 盘，开机按 F12/F2/ESC 选 USB 启动。
  会直接进入氵系统，没有登录界面。

【配置 AI 大脑】
  首次开机前，把 DeepSeek API Key 写进去：
    mount /dev/sdX1 /mnt
    echo "sk-your-key" > /mnt/etc/shuios/key

  或者开机后按 Ctrl+Alt+F2 进终端配置。

【调试】
  Ctrl+Alt+F2  终端
  Ctrl+Alt+Del 重启
EOF

echo "── post-image 完成 ──"
ls -lh *.iso *.img 2>/dev/null || true
