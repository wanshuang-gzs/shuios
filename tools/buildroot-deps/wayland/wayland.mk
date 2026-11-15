################################################################################
#
# wayland 1.24.0 —— 由 tools/patch-buildroot-deps.sh 复制进 Buildroot 树，
# 替换掉 Buildroot 2025.02 自带的 1.23.1。
#
# 为什么必须升：wlroots 0.20 的 meson.build 要求 wayland-server >= 1.24.0，
# scenefx 0.5 同样。1.23 直接 configure 就失败。
#
# host-wayland 也在这里一起重定义（wayland-scanner 版本要跟运行库一致）。
#
################################################################################

WAYLAND_VERSION = 1.24.0
WAYLAND_SITE = $(BR2_EXTERNAL_SHUIOS_PATH)/dl
WAYLAND_SITE_METHOD = file
WAYLAND_SOURCE = wayland-$(WAYLAND_VERSION).tar.xz
WAYLAND_LICENSE = MIT
WAYLAND_LICENSE_FILES = COPYING
WAYLAND_CPE_ID_VENDOR = wayland
WAYLAND_INSTALL_STAGING = YES
WAYLAND_DEPENDENCIES = host-pkgconf host-wayland expat libffi libxml2
HOST_WAYLAND_DEPENDENCIES = host-pkgconf host-expat host-libffi host-libxml2

WAYLAND_CONF_OPTS = -Dtests=false -Ddocumentation=false
HOST_WAYLAND_CONF_OPTS = -Dtests=false -Ddocumentation=false

# 目标机上不需要 DTD
define WAYLAND_TARGET_CLEANUP
	rm -rf $(TARGET_DIR)/usr/share/wayland
endef
WAYLAND_POST_INSTALL_TARGET_HOOKS += WAYLAND_TARGET_CLEANUP

$(eval $(meson-package))
$(eval $(host-meson-package))
