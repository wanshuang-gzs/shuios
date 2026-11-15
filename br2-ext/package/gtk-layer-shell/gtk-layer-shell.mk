################################################################################
#
# gtk-layer-shell — GTK3 的 Wayland layer-shell 支持
#
################################################################################

GTK_LAYER_SHELL_VERSION = 0.9.0
GTK_LAYER_SHELL_SITE = $(BR2_EXTERNAL_SHUIOS_PATH)/dl
GTK_LAYER_SHELL_SITE_METHOD = file
GTK_LAYER_SHELL_SOURCE = gtk-layer-shell-0.9.0.tar.gz
GTK_LAYER_SHELL_LICENSE = MIT
GTK_LAYER_SHELL_LICENSE_FILES = LICENSE.md
GTK_LAYER_SHELL_INSTALL_STAGING = YES
GTK_LAYER_SHELL_DEPENDENCIES = \
	host-pkgconf host-wayland libgtk3 wayland wayland-protocols

# 只要库本体：introspection / 示例 / 文档 / 测试都不需要
GTK_LAYER_SHELL_CONF_OPTS = \
	-Dintrospection=false \
	-Dexamples=false \
	-Ddocs=false \
	-Dtests=false

$(eval $(meson-package))
