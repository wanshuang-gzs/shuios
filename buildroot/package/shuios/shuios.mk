################################################################################
# shuios (氵系统)
#
# 从 GitHub 拉源码，用 Buildroot 交叉工具链编译。
#
# 依赖说明:
#   qt6base         —— Core / Gui / Network / EGLFS 平台插件
#   qt6declarative  —— QML / Quick（Qt6 的 QuickControls2 已并入此模块）
#   qt6wayland      —— Wayland 支持（compositor 选项由 defconfig 控制）
#   qt6svg          —— 图标渲染
################################################################################

SHUIOS_VERSION = main
SHUIOS_SITE = https://github.com/wanshuang-gzs/shuios.git
SHUIOS_SITE_METHOD = git
SHUIOS_LICENSE = GPL-3.0+
SHUIOS_REDISTRIBUTE = YES

SHUIOS_DEPENDENCIES = \
	qt6base \
	qt6declarative \
	qt6wayland \
	qt6svg

# 交叉编译时关闭单元测试（测试要在目标架构上跑，不是构建机）
#
# QT_HOST_PATH 是交叉编译的必需项：
# Qt6 的 CMake 脚本要从这里找 moc / rcc / qmlcachegen 等宿主工具。
# 少了它，configure 阶段会直接报 "Qt6 requires QT_HOST_PATH"。
# Buildroot 里宿主工具装在 $(HOST_DIR)。
SHUIOS_CONF_OPTS = \
	-DSHUIOS_BUILD_TESTS=OFF \
	-DCMAKE_BUILD_TYPE=Release \
	-DQT_HOST_PATH=$(HOST_DIR)

$(eval $(cmake-package))
