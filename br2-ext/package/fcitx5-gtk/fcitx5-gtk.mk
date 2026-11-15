################################################################################
#
# fcitx5-gtk — GTK3 输入法模块
#
# 模块装到 /usr/lib/gtk-3.0/3.0.0/immodules/im-fcitx5.so。
# GTK3 不会自己生成 immodules.cache，所以镜像里带了一份手写的
# /etc/shuios/gtk-immodules.cache，会话用 GTK_IM_MODULE_FILE 指过去。
#
################################################################################

FCITX5_GTK_VERSION = 5.1.7
FCITX5_GTK_SITE = $(BR2_EXTERNAL_SHUIOS_PATH)/dl
FCITX5_GTK_SITE_METHOD = file
FCITX5_GTK_SOURCE = fcitx5-gtk-5.1.7.tar.gz
FCITX5_GTK_LICENSE = LGPL-2.1-or-later
FCITX5_GTK_INSTALL_STAGING = NO

FCITX5_GTK_CONF_OPTS = \
	-DENABLE_GIR=OFF \
	-DENABLE_GTK2_IM_MODULE=OFF \
	-DENABLE_GTK3_IM_MODULE=ON \
	-DENABLE_GTK4_IM_MODULE=OFF \
	-DENABLE_SNOOPER=ON

FCITX5_GTK_DEPENDENCIES = \
	extra-cmake-modules \
	fcitx5 \
	host-pkgconf \
	libglib2 \
	libgtk3 \
	libxkbcommon

$(eval $(cmake-package))
