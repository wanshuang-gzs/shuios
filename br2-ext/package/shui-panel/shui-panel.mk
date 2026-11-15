################################################################################
#
# shui-panel — Windows 风格底部任务栏（GTK3 + Cairo）
#
################################################################################

SHUI_PANEL_VERSION = 0.1.0
SHUI_PANEL_SITE = $(BR2_EXTERNAL_SHUIOS_PATH)/package/shui-panel/src
SHUI_PANEL_SITE_METHOD = local
SHUI_PANEL_LICENSE = Apache-2.0
SHUI_PANEL_DEPENDENCIES = host-pkgconf libgtk3 gtk-layer-shell

# 设计令牌（唯一色源）在 board/shuios/common/ui/shuios-ui.h，用 -I 共享给所有自研界面。
define SHUI_PANEL_BUILD_CMDS
	$(TARGET_CONFIGURE_OPTS) $(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) \
		-I$(BR2_EXTERNAL_SHUIOS_PATH)/board/shuios/common/ui \
		-o $(@D)/shui-panel $(@D)/shui-panel.c \
		`$(PKG_CONFIG_HOST_BINARY) --cflags --libs gtk+-3.0 gtk-layer-shell-0` \
		-lm
endef

define SHUI_PANEL_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/shui-panel $(TARGET_DIR)/usr/bin/shui-panel
endef

$(eval $(generic-package))
