################################################################################
#
# wlroots 0.20 —— 由 tools/patch-buildroot-deps.sh 复制进 Buildroot 树，
# 替换掉 Buildroot 2025.02 自带的 0.18.2。
#
# 为什么要升：swayfx 0.6 / scenefx 0.5 硬绑 wlroots 0.20
# （pkg-config 名从 wlroots 变成 wlroots-0.20，API 也变了，0.18 编不过）。
#
# 0.20 相对 0.18 的实际收益（这正是我们升级的目的）：
#   * 新增 udmabuf allocator（render/allocator/udmabuf.c）——软件渲染下能
#     少一次 GBM 影子拷贝，正是 llvmpipe 场景的痛点
#   * damage ring / swapchain 重写（bfcaa4bc、f9de8591、bcba7cb1）
#   * explicit sync 支持
#
################################################################################

WLROOTS_VERSION = 0.20.0
WLROOTS_SITE = $(BR2_EXTERNAL_SHUIOS_PATH)/dl
WLROOTS_SITE_METHOD = file
WLROOTS_SOURCE = wlroots-0.20.0.tar.gz
WLROOTS_LICENSE = MIT
WLROOTS_LICENSE_FILES = LICENSE
WLROOTS_INSTALL_STAGING = YES

WLROOTS_DEPENDENCIES = \
	host-pkgconf \
	host-wayland \
	hwdata \
	libdisplay-info \
	libinput \
	libxkbcommon \
	libegl \
	libgles \
	libgbm \
	pixman \
	seatd \
	udev \
	wayland \
	wayland-protocols

# 0.20 的 renderers 只接受 auto/gles2/vulkan（pixman renderer 已移除），
# backends 只接受 auto/drm/libinput/x11
WLROOTS_CONF_OPTS = \
	-Dexamples=false \
	-Dxcb-errors=disabled \
	-Dbackends=drm,libinput \
	-Drenderers=gles2

# XWayland：闭源 Linux 软件（微信 / 钉钉 / 飞书 / VS Code）都是 X11 程序，
# 没有它连窗口都创建不出来。关闭时是默认路径，打开时按上游 recipe 的写法
# 补依赖（xcb-icccm/ewmh 来自 xcb-util-wm，xcb-composite/res/xfixes 由
# libxcb 本体提供）。
ifeq ($(BR2_PACKAGE_WLROOTS_XWAYLAND),y)
WLROOTS_CONF_OPTS += -Dxwayland=enabled
WLROOTS_DEPENDENCIES += libxcb xcb-util-wm xwayland
else
WLROOTS_CONF_OPTS += -Dxwayland=disabled
endif

$(eval $(meson-package))
