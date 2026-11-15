################################################################################
#
# shui-files — 氵 文件管理器（GTK3）
#
################################################################################

SHUI_FILES_VERSION = 0.1.0
SHUI_FILES_SITE = $(BR2_EXTERNAL_SHUIOS_PATH)/package/shui-files/src
SHUI_FILES_SITE_METHOD = local
SHUI_FILES_LICENSE = Apache-2.0
SHUI_FILES_DEPENDENCIES = host-pkgconf libgtk3

# 没有 configure/Makefile，直接调交叉编译器。
# -I 指向 board/.../ui：设计令牌与 shui-store / shui-panel 共用一份。
define SHUI_FILES_BUILD_CMDS
	$(TARGET_CONFIGURE_OPTS) $(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) \
		-I$(BR2_EXTERNAL_SHUIOS_PATH)/board/shuios/common/ui \
		-o $(@D)/shui-files $(@D)/shui-files.c \
		`$(PKG_CONFIG_HOST_BINARY) --cflags --libs gtk+-3.0` \
		-lm
endef

define SHUI_FILES_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/shui-files $(TARGET_DIR)/usr/bin/shui-files
	$(INSTALL) -D -m 0644 $(SHUI_FILES_PKGDIR)/files/shui-files.desktop \
		$(TARGET_DIR)/usr/share/applications/shui-files.desktop
endef

$(eval $(generic-package))
