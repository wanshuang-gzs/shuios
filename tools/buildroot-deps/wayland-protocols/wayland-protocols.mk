################################################################################
#
# wayland-protocols 1.48 —— 由 tools/patch-buildroot-deps.sh 复制进 Buildroot 树，
# 替换掉 Buildroot 2025.02 自带的 1.39。
#
# wlroots 0.20.0 的 meson.build 要求 wayland-protocols >= 1.47，
# swayfx 0.6 要求 >= 1.41，取较高者。
#
################################################################################

WAYLAND_PROTOCOLS_VERSION = 1.48
WAYLAND_PROTOCOLS_SITE = $(BR2_EXTERNAL_SHUIOS_PATH)/dl
WAYLAND_PROTOCOLS_SITE_METHOD = file
WAYLAND_PROTOCOLS_SOURCE = wayland-protocols-$(WAYLAND_PROTOCOLS_VERSION).tar.xz
WAYLAND_PROTOCOLS_LICENSE = MIT
WAYLAND_PROTOCOLS_LICENSE_FILES = COPYING
WAYLAND_PROTOCOLS_INSTALL_STAGING = YES
WAYLAND_PROTOCOLS_INSTALL_TARGET = NO
# 需要 wayland-scanner
WAYLAND_PROTOCOLS_DEPENDENCIES = host-wayland

WAYLAND_PROTOCOLS_CONF_OPTS = -Dtests=false

$(eval $(meson-package))
