#!/bin/bash
# 交叉编译 IME 验收工具（在 WSL shui-build 里跑，需要镜像已至少构建过一次）。
# 产物放到 /mnt/d/shuios/.cache/ime-test/，再 scp 进 VM。
set -euo pipefail

BR=/root/shuios/buildroot
HOST=$BR/output/host
SYSROOT=$HOST/x86_64-buildroot-linux-gnu/sysroot
CROSS=$HOST/bin/x86_64-buildroot-linux-gnu
SRC=/mnt/d/shuios/tools/ime-test
OUT=/mnt/d/shuios/.cache/ime-test
GEN=/tmp/ime-test-build

[ -x "$CROSS-gcc" ] || { echo "缺少交叉 gcc：$CROSS-gcc"; exit 1; }
mkdir -p "$OUT" "$GEN"

# ---- vkbd-inject：Wayland 虚拟键盘注入 --------------------------------------
# 用 wlroots 自带的协议 XML 生成客户端绑定，避免依赖已安装的 wayland-protocols。
XML=$BR/output/build/wlroots-0.20.0/protocol/virtual-keyboard-unstable-v1.xml
[ -f "$XML" ] || { echo "缺少 $XML"; exit 1; }
"$HOST/bin/wayland-scanner" client-header "$XML" \
	"$GEN/virtual-keyboard-unstable-v1-client-protocol.h"
"$HOST/bin/wayland-scanner" private-code "$XML" \
	"$GEN/virtual-keyboard-unstable-v1-protocol.c"

"$CROSS-gcc" -O2 -Wall -o "$OUT/vkbd-inject" \
	"$SRC/vkbd-inject.c" "$GEN/virtual-keyboard-unstable-v1-protocol.c" \
	-I"$GEN" -L"$SYSROOT/usr/lib" -lwayland-client -lxkbcommon
echo "built $OUT/vkbd-inject"

# ---- gtk-ime-test：GTK3 immodule 链路 ---------------------------------------
# Buildroot 的 host pkg-config 是指向 staging 的包装脚本。
PKG=$HOST/bin/pkg-config
[ -x "$PKG" ] || { echo "缺少 $PKG"; exit 1; }
"$CROSS-gcc" -O2 -Wall -Wno-deprecated-declarations -o "$OUT/gtk-ime-test" \
	"$SRC/gtk-ime-test.c" \
	$("$PKG" --cflags gtk+-3.0) $("$PKG" --libs gtk+-3.0)
echo "built $OUT/gtk-ime-test"

"$CROSS-strip" "$OUT/vkbd-inject" "$OUT/gtk-ime-test" 2>/dev/null || true
ls -l "$OUT"
