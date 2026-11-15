################################################################################
#
# extra-cmake-modules — CMake 模块集（只装 staging，不进镜像）
#
# fcitx5 / fcitx5-gtk / fcitx5-rime 依赖 ECM 提供的
# ECMSetupVersion、ECMUninstallTarget、ecm_add_wayland_client_protocol 等模块。
# 注意必须装进 staging 而不是 host：Buildroot 的 CMake 交叉工具链只把
# staging 加入 CMAKE_FIND_ROOT_PATH，find_package(ECM) 才会命中。
# 与 Buildroot 自带 kf5-extra-cmake-modules 的做法一致。
#
################################################################################

EXTRA_CMAKE_MODULES_VERSION = 6.31.0
EXTRA_CMAKE_MODULES_SITE = $(BR2_EXTERNAL_SHUIOS_PATH)/dl
EXTRA_CMAKE_MODULES_SITE_METHOD = file
EXTRA_CMAKE_MODULES_SOURCE = extra-cmake-modules-6.31.0.tar.gz
EXTRA_CMAKE_MODULES_LICENSE = BSD-3-Clause
EXTRA_CMAKE_MODULES_LICENSE_FILES = COPYING-CMAKE-SCRIPTS
EXTRA_CMAKE_MODULES_INSTALL_STAGING = YES
EXTRA_CMAKE_MODULES_INSTALL_TARGET = NO

EXTRA_CMAKE_MODULES_CONF_OPTS = \
	-DBUILD_TESTING=OFF \
	-DBUILD_DOC=OFF \
	-DBUILD_HTML_DOCS=OFF \
	-DBUILD_MAN_DOCS=OFF \
	-DBUILD_QTHELP_DOCS=OFF

$(eval $(cmake-package))
