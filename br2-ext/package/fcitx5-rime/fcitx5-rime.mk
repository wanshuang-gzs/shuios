################################################################################
#
# fcitx5-rime — fcitx5 的 Rime 引擎
#
################################################################################

FCITX5_RIME_VERSION = 5.1.16
FCITX5_RIME_SITE = $(BR2_EXTERNAL_SHUIOS_PATH)/dl
FCITX5_RIME_SITE_METHOD = file
FCITX5_RIME_SOURCE = fcitx5-rime-5.1.16.tar.gz
FCITX5_RIME_LICENSE = LGPL-2.1-or-later
FCITX5_RIME_INSTALL_STAGING = NO

# 共享数据在 rime-data 包安装的 /usr/share/rime-data；用户词典落在
# $XDG_DATA_HOME/fcitx5/rime（会话里 XDG_DATA_HOME 指向数据分区）。
FCITX5_RIME_CONF_OPTS = -DRIME_DATA_DIR=/usr/share/rime-data

FCITX5_RIME_DEPENDENCIES = \
	extra-cmake-modules \
	fcitx5 \
	host-gettext \
	host-pkgconf \
	librime \
	rime-data

$(eval $(cmake-package))
