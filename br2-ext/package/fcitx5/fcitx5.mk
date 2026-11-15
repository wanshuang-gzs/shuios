################################################################################
#
# fcitx5 — 输入法框架（Wayland 前端 + classic 候选窗）
#
# 说明：
#   * 只开 Wayland，不编 X11（系统没有 X 服务器，也不需要 libxcb）。
#   * 事件循环 / D-Bus 走 systemd（sd-event / sd-bus），不额外拉 libuv。
#   * classic 候选窗需要 librsvg（默认主题的翻页箭头是 SVG）。
#     Buildroot 的 librsvg 2.50.9 需要 Rust，但 WebKitGTK 已经建好了
#     host-rustc（1.82），所以这里只多花编 librsvg 的时间。
#   * yoga（候选窗布局引擎）在 GitHub 源码包里是空子模块目录；
#     构建前把钉住的提交解压进 third_party/yoga。
#
################################################################################

FCITX5_VERSION = 5.1.23
FCITX5_SITE = $(BR2_EXTERNAL_SHUIOS_PATH)/dl
FCITX5_SITE_METHOD = file
FCITX5_SOURCE = fcitx5-5.1.23.tar.gz
FCITX5_LICENSE = LGPL-2.1-or-later
FCITX5_LICENSE_FILES = LICENSE
FCITX5_INSTALL_STAGING = YES

# 只用于配置期的存在性检查；不设的话 FindIsoCodes 会去宿主的
# /usr/share/iso-codes 找（交叉编译时是错的）。
FCITX5_CONF_OPTS = \
	-DENABLE_X11=OFF \
	-DENABLE_WAYLAND=ON \
	-DENABLE_DBUS=ON \
	-DENABLE_KEYBOARD=ON \
	-DENABLE_SERVER=ON \
	-DENABLE_LIBUUID=ON \
	-DENABLE_ENCHANT=OFF \
	-DENABLE_EMOJI=ON \
	-DENABLE_TESTING_ADDONS=OFF \
	-DENABLE_TEST=OFF \
	-DENABLE_DOC=OFF \
	-DBUILD_SPELL_DICT=OFF \
	-DUSE_SYSTEMD=ON \
	-DUSE_SYSTEM_YOGA=OFF \
	-DUSE_SYSTEM_PLASMA_WAYLAND_PROTOCOLS=OFF \
	-DISOCODES_ISO639_JSON=$(STAGING_DIR)/usr/share/iso-codes/json/iso_639-3.json

FCITX5_DEPENDENCIES = \
	cairo \
	expat \
	extra-cmake-modules \
	gdk-pixbuf \
	host-gettext \
	host-pkgconf \
	host-wayland \
	iso-codes \
	json-for-modern-cpp \
	libglib2 \
	librsvg \
	libxkbcommon \
	pango \
	systemd \
	util-linux \
	wayland \
	wayland-protocols \
	xkeyboard-config \
	zlib

# fcitx5 的 third_party/yoga 是 git 子模块，源码包里是空的。
# 042f5013 是 fcitx5 5.1.23 钉住的 facebook/yoga 提交。
define FCITX5_EXTRACT_YOGA
	mkdir -p $(@D)/third_party/yoga
	tar -xzf $(BR2_EXTERNAL_SHUIOS_PATH)/dl/yoga-042f5013.tar.gz \
		-C $(@D)/third_party/yoga --strip-components=1
endef
FCITX5_POST_EXTRACT_HOOKS += FCITX5_EXTRACT_YOGA

$(eval $(cmake-package))
