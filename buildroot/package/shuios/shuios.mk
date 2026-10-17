################################################################################
# shuios (氵系统)
#
# 从我们的 GitHub 仓库拉源码，用 Buildroot 的交叉工具链编译。
################################################################################

SHUIOS_VERSION = main
SHUIOS_SITE = https://github.com/wanshuang-gzs/shuios.git
SHUIOS_SITE_METHOD = git
SHUIOS_LICENSE = GPL-3.0+
SHUIOS_REDISTRIBUTE = YES

SHUIOS_DEPENDENCIES = \
	qt6base \
	qt6declarative \
	qt6quickcontrols2 \
	qt6waylandcompositor

# 交叉编译时不需要测试（测试要在目标架构上跑）
SHUIOS_CONF_OPTS = \
	-DSHUIOS_BUILD_TESTS=OFF \
	-DCMAKE_BUILD_TYPE=Release

$(eval $(cmake-package))
