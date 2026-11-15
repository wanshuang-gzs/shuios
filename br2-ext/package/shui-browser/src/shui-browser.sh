#!/bin/sh
# shui-browser 启动包装：给 WebKit 选对可写目录和渲染路径。
#
# vmwgfx/bochs/virtio-gpu 上 WebKit 的 DMA-BUF 渲染器会导入失败（见 docs V17），
# 硬件合成在 llvmpipe 下也不稳，所以虚拟 GPU 统一退回软件渲染。
# 镜像里只有 Mesa 的 EGL/GLES，没有 libGL，GTK 的 GL 初始化会在启动时直接 abort，
# 因此虚拟 GPU 上还要关掉 GDK 的 GL（GTK 自动退回软件绘制）。
# 真机（Intel/AMD 核显）保持 WebKit 默认的加速路径。
set -u

vendor=$(cat /sys/class/drm/card0/device/vendor 2>/dev/null || true)
case "$vendor" in
	0x15ad|0x1234|0x1af4)
		export GDK_GL=disable
		export WEBKIT_DISABLE_DMABUF_RENDERER=1
		export WEBKIT_DISABLE_COMPOSITING_MODE=1
		;;
esac

# 根分区是只读 squashfs：缓存/网站数据必须落到数据分区
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/var/lib/shuios/cache}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-/var/lib/shuios/browser-data}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/var/lib/shuios/browser-config}"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" 2>/dev/null || true

# 开发闭环：dev-deploy 推进来的二进制优先（存在就用）
BIN=/usr/bin/shui-browser-bin
[ -x /var/lib/shuios/dev/shui-browser-bin ] && BIN=/var/lib/shuios/dev/shui-browser-bin
exec "$BIN" "$@"
