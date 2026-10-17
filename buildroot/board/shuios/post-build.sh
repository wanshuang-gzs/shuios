#!/bin/sh
# ═══════════════════════════════════════════════════════════
#  shuios post-build 脚本
#  在 rootfs 生成后、镜像打包前执行
# ═══════════════════════════════════════════════════════════

set -e
TARGET_DIR="$1"

echo "── post-build: 配置氵系统 rootfs ──"

# ── 可执行权限 ────────────────────────────────────────────
chmod 0755 "$TARGET_DIR/usr/bin/shuios-session" 2>/dev/null || true
chmod 0755 "$TARGET_DIR"/etc/init.d/S* 2>/dev/null || true

# ── 大脑密钥目录（首次开机可从 U 盘写入）─────────────────
mkdir -p "$TARGET_DIR/etc/shuios"
chmod 0700 "$TARGET_DIR/etc/shuios"

# 如果构建环境提供了 key，就写进去（CI 用 secret）
if [ -n "$SHUIOS_DEEPSEEK_KEY" ]; then
    echo "$SHUIOS_DEEPSEEK_KEY" > "$TARGET_DIR/etc/shuios/key"
    chmod 0600 "$TARGET_DIR/etc/shuios/key"
    echo "   已写入 DeepSeek Key"
fi

# ── 字体检查 ──────────────────────────────────────────────
FONT_DIR="$TARGET_DIR/usr/share/fonts"
mkdir -p "$FONT_DIR"
CJK_COUNT=$(find "$FONT_DIR" -iname '*wqy*' -o -iname '*noto*cjk*' -o -iname '*cjk*' 2>/dev/null | wc -l)
if [ "$CJK_COUNT" -eq 0 ]; then
    echo "   ⚠ 警告: 未找到中文字体，界面中文会显示为方块"
    echo "     请确认 BR2_PACKAGE_WQY_ZENHEI 是否生效"
else
    echo "   中文字体: $CJK_COUNT 个文件"
fi

# ── 状态目录（权限内核 + 账本会写这里）───────────────────
mkdir -p "$TARGET_DIR/var/lib/shuios/state"
chmod 0700 "$TARGET_DIR/var/lib/shuios/state"

# ── 首次开机标记 ──────────────────────────────────────────
cat > "$TARGET_DIR/etc/shuios/version" <<EOF
氵系统 shuios v0.1.0
构建时间: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
构建主机: $(uname -n)
EOF

# ── 清理（减小镜像体积）───────────────────────────────────
rm -rf "$TARGET_DIR/usr/share/man" 2>/dev/null || true
rm -rf "$TARGET_DIR/usr/share/doc" 2>/dev/null || true
find "$TARGET_DIR/usr/lib" -name '*.a' -delete 2>/dev/null || true

echo "── post-build 完成 ──"
