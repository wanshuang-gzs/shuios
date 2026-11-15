################################################################################
#
# shui-lock — 锁屏 + 空闲锁定 + 按键注入
#
################################################################################

SHUI_LOCK_VERSION = 0.1.0
SHUI_LOCK_SITE = $(BR2_EXTERNAL_SHUIOS_PATH)/package/shui-lock/src
SHUI_LOCK_SITE_METHOD = local
SHUI_LOCK_LICENSE = Apache-2.0
SHUI_LOCK_DEPENDENCIES = host-pkgconf host-wayland libgtk3 gtk-layer-shell \
	libxcrypt wayland libxkbcommon

# shui-key 需要 wlroots 的 virtual-keyboard 协议；XML 随包自带，
# 构建时用 host wayland-scanner 生成 C 绑定（Buildroot 不提供 wtype）。
define SHUI_LOCK_BUILD_CMDS
	$(HOST_DIR)/bin/wayland-scanner client-header \
		$(@D)/virtual-keyboard-unstable-v1.xml \
		$(@D)/virtual-keyboard-client-protocol.h
	$(HOST_DIR)/bin/wayland-scanner private-code \
		$(@D)/virtual-keyboard-unstable-v1.xml \
		$(@D)/virtual-keyboard-protocol.c
	$(TARGET_CONFIGURE_OPTS) $(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) \
		-I$(BR2_EXTERNAL_SHUIOS_PATH)/board/shuios/common/ui \
		-o $(@D)/shui-lock $(@D)/shui-lock.c \
		`$(PKG_CONFIG_HOST_BINARY) --cflags --libs gtk+-3.0 gtk-layer-shell-0` \
		-lcrypt -lm
	$(TARGET_CONFIGURE_OPTS) $(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) \
		-o $(@D)/shui-idle $(@D)/shui-idle.c
	$(TARGET_CONFIGURE_OPTS) $(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) \
		-I$(@D) -o $(@D)/shui-key $(@D)/shui-key.c \
		$(@D)/virtual-keyboard-protocol.c \
		`$(PKG_CONFIG_HOST_BINARY) --cflags --libs wayland-client xkbcommon`
endef

define SHUI_LOCK_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/shui-lock $(TARGET_DIR)/usr/bin/shui-lock
	$(INSTALL) -D -m 0755 $(@D)/shui-idle $(TARGET_DIR)/usr/bin/shui-idle
	$(INSTALL) -D -m 0755 $(@D)/shui-key $(TARGET_DIR)/usr/bin/shui-key
	$(INSTALL) -D -m 0644 $(SHUI_LOCK_PKGDIR)/files/idle.conf \
		$(TARGET_DIR)/etc/shuios/idle.conf
endef

$(eval $(generic-package))
