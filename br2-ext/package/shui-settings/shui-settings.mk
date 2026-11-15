################################################################################
#
# shui-settings — 氵 设置中心（GTK3）
#
################################################################################

SHUI_SETTINGS_VERSION = 0.1.0
SHUI_SETTINGS_SITE = $(BR2_EXTERNAL_SHUIOS_PATH)/package/shui-settings/src
SHUI_SETTINGS_SITE_METHOD = local
SHUI_SETTINGS_LICENSE = Apache-2.0
SHUI_SETTINGS_DEPENDENCIES = host-pkgconf libgtk3

define SHUI_SETTINGS_BUILD_CMDS
	$(TARGET_CONFIGURE_OPTS) $(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) \
		-I$(BR2_EXTERNAL_SHUIOS_PATH)/board/shuios/common/ui \
		-o $(@D)/shui-settings $(@D)/shui-settings.c \
		`$(PKG_CONFIG_HOST_BINARY) --cflags --libs gtk+-3.0`
endef

define SHUI_SETTINGS_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/shui-settings $(TARGET_DIR)/usr/bin/shui-settings
	$(INSTALL) -D -m 0644 $(SHUI_SETTINGS_PKGDIR)/files/shui-settings.desktop \
		$(TARGET_DIR)/usr/share/applications/shui-settings.desktop
endef

$(eval $(generic-package))
