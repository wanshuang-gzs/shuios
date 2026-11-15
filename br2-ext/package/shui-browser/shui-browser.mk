################################################################################
#
# shui-browser — WebKitGTK 图形浏览器（GTK3 + WebKit2GTK 4.1）
#
################################################################################

SHUI_BROWSER_VERSION = 0.1.0
SHUI_BROWSER_SITE = $(BR2_EXTERNAL_SHUIOS_PATH)/package/shui-browser/src
SHUI_BROWSER_SITE_METHOD = local
SHUI_BROWSER_LICENSE = Apache-2.0
SHUI_BROWSER_DEPENDENCIES = host-pkgconf libgtk3 webkitgtk

define SHUI_BROWSER_BUILD_CMDS
	$(TARGET_CONFIGURE_OPTS) $(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) \
		-o $(@D)/shui-browser-bin $(@D)/shui-browser.c \
		`$(PKG_CONFIG_HOST_BINARY) --cflags --libs webkit2gtk-4.1`
endef

define SHUI_BROWSER_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/shui-browser-bin \
		$(TARGET_DIR)/usr/bin/shui-browser-bin
	$(INSTALL) -D -m 0755 $(@D)/shui-browser.sh \
		$(TARGET_DIR)/usr/bin/shui-browser
	$(INSTALL) -D -m 0644 $(@D)/browser-home.html \
		$(TARGET_DIR)/usr/share/shuios/browser-home.html
endef

$(eval $(generic-package))
