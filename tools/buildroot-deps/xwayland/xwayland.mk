################################################################################
#
# xwayland —— VMware / 软件渲染环境下的关 glamor 变体
#
# 为什么改：Xwayland 默认用 glamor（EGL + GBM）画 X 窗口，在 vmwgfx 上
# 走到 dmabuf 导入就失败：
#   wlr_linux_dmabuf_v1: Failed to close buffer handle for plane 0
#   XWAYLAND: error 7: importing the supplied dmabufs failed
#   (EE) failed to dispatch Wayland events: Protocol error
# 结果是 Xwayland 一起来就死，所有 X11 程序（微信等）连不上 :0。
#
# 关掉 glamor 后 X 走软件渲染：慢一点，但 X11 应用能正常出窗口。
# 桌面本身不受影响（Wayland 客户端不经过 Xwayland）。
#
################################################################################
#
# xwayland
#
################################################################################

XWAYLAND_VERSION = 24.1.8
XWAYLAND_SOURCE = xwayland-$(XWAYLAND_VERSION).tar.xz
XWAYLAND_SITE = https://xorg.freedesktop.org/archive/individual/xserver
XWAYLAND_LICENSE = MIT
XWAYLAND_LICENSE_FILES = COPYING
XWAYLAND_CPE_ID_VENDOR = x.org
XWAYLAND_INSTALL_STAGING = YES
XWAYLAND_DEPENDENCIES = \
	libdrm \
	pixman \
	wayland \
	wayland-protocols \
	xlib_libxcvt \
	xlib_libXfont2 \
	xlib_libxkbfile \
	xlib_libXrandr \
	xlib_libxshmfence \
	xlib_xtrans \
	xorgproto
XWAYLAND_CONF_OPTS = \
	-Ddri3=true \
	-Dxvfb=false \
	-Ddefault_font_path=/usr/share/fonts/X11/ \
	-Ddtrace=false \
	-Ddocs=false

# 无条件关掉 glamor：见文件头注释（vmwgfx 上 dmabuf 导入失败会让 Xwayland 崩）
XWAYLAND_CONF_OPTS += -Dglamor=false

ifeq ($(BR2_PACKAGE_HAS_LIBGL),y)
XWAYLAND_CONF_OPTS += -Dglx=true
XWAYLAND_DEPENDENCIES += libgl
else
XWAYLAND_CONF_OPTS += -Dglx=false
endif

ifeq ($(BR2_PACKAGE_XLIB_LIBXDMCP),y)
XWAYLAND_CONF_OPTS += \
	-Dxdmcp=true \
	-Dxdm-auth-1=true
XWAYLAND_DEPENDENCIES += xlib_libXdmcp
else
XWAYLAND_CONF_OPTS += \
	-Dxdmcp=false \
	-Dxdm-auth-1=false
endif

ifeq ($(BR2_PACKAGE_LIBTIRPC),y)
XWAYLAND_CONF_OPTS += -Dsecure-rpc=true
XWAYLAND_DEPENDENCIES += libtirpc
else
XWAYLAND_CONF_OPTS += -Dsecure-rpc=false
endif

ifeq ($(BR2_PACKAGE_LIBSELINUX)$(BR2_PACKAGE_AUDIT),yy)
XWAYLAND_CONF_OPTS += -Dxselinux=true
XWAYLAND_DEPENDENCIES += libselinux audit
else
XWAYLAND_CONF_OPTS += -Dxselinux=false
endif

ifeq ($(BR2_PACKAGE_OPENSSL),y)
XWAYLAND_CONF_OPTS += -Dsha1=libcrypto
XWAYLAND_DEPENDENCIES += openssl
else ifeq ($(BR2_PACKAGE_LIBGCRYPT),y)
XWAYLAND_CONF_OPTS += -Dsha1=libgcrypt
XWAYLAND_DEPENDENCIES += libgcrypt
else
XWAYLAND_CONF_OPTS += -Dsha1=libsha1
XWAYLAND_DEPENDENCIES += libsha1
endif

ifeq ($(BR2_PACKAGE_LIBUNWIND),y)
XWAYLAND_CONF_OPTS += -Dlibunwind=true
XWAYLAND_DEPENDENCIES += libunwind
else
XWAYLAND_CONF_OPTS += -Dlibunwind=false
endif

$(eval $(meson-package))
