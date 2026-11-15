################################################################################
#
# shui-store — 氵 软件商店（GTK3 + Cairo 自绘图标）
#
################################################################################

SHUI_STORE_VERSION = 0.1.0
SHUI_STORE_SITE = $(BR2_EXTERNAL_SHUIOS_PATH)/package/shui-store/src
SHUI_STORE_SITE_METHOD = local
SHUI_STORE_LICENSE = Apache-2.0
SHUI_STORE_DEPENDENCIES = host-pkgconf libgtk3

# 没有 configure/Makefile，直接调交叉编译器。
# TARGET_CONFIGURE_OPTS 会把 PKG_CONFIG_SYSROOT_DIR / PKG_CONFIG_PATH 指到
# output/staging，否则 pkg-config 会去拿主机的 GTK 头文件。
# 设计令牌（唯一色源）在 board/shuios/common/ui/shuios-ui.h，用 -I 共享给所有自研界面。
define SHUI_STORE_BUILD_CMDS
	$(TARGET_CONFIGURE_OPTS) $(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) \
		-I$(BR2_EXTERNAL_SHUIOS_PATH)/board/shuios/common/ui \
		-o $(@D)/shui-store $(@D)/shui-store.c \
		`$(PKG_CONFIG_HOST_BINARY) --cflags --libs gtk+-3.0` \
		-lm
endef

define SHUI_STORE_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/shui-store $(TARGET_DIR)/usr/bin/shui-store
	$(INSTALL) -D -m 0644 $(SHUI_STORE_PKGDIR)/files/shui-store.desktop \
		$(TARGET_DIR)/usr/share/applications/shui-store.desktop
endef

$(eval $(generic-package))
