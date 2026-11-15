################################################################################
#
# opencc — 简繁转换库（librime 的硬依赖）
#
# 交叉编译的坑：OpenCC 生成词典时要在构建期**执行** opencc/opencc_dict，
# 而 target 二进制（glibc 2.41）跑不到构建机（glibc 2.39）上。
# 因此：
#   * host-opencc 用宿主机编译器正常构建，顺带生成全部 .ocd2 词典；
#   * target opencc 打补丁跳过词典生成（OPENCC_USE_PREBUILT_DATA=ON），
#     安装时直接从 $(HOST_DIR)/share/opencc 取 host 生成的那份。
# 两份源码同版本、同格式，词典完全兼容。
#
################################################################################

OPENCC_VERSION = 1.4.2
OPENCC_SITE = $(BR2_EXTERNAL_SHUIOS_PATH)/dl
OPENCC_SITE_METHOD = file
OPENCC_SOURCE = opencc-1.4.2.tar.gz
OPENCC_LICENSE = Apache-2.0
OPENCC_LICENSE_FILES = LICENSE
OPENCC_INSTALL_STAGING = YES

OPENCC_CONF_OPTS = \
	-DUSE_SYSTEM_MARISA=ON \
	-DBUILD_DOCUMENTATION=OFF \
	-DBUILD_PYTHON=OFF \
	-DENABLE_GTEST=OFF \
	-DENABLE_BENCHMARK=OFF \
	-DOPENCC_DICT_FORMAT=ocd2 \
	-DOPENCC_USE_PREBUILT_DATA=ON \
	-DOPENCC_PREBUILT_DATA_DIR=$(HOST_DIR)/share/opencc

OPENCC_DEPENDENCIES = host-opencc marisa-trie host-pkgconf

HOST_OPENCC_DEPENDENCIES = host-python3 host-pkgconf
HOST_OPENCC_CONF_OPTS = \
	-DUSE_SYSTEM_MARISA=OFF \
	-DBUILD_DOCUMENTATION=OFF \
	-DBUILD_PYTHON=OFF \
	-DENABLE_GTEST=OFF \
	-DENABLE_BENCHMARK=OFF \
	-DOPENCC_DICT_FORMAT=ocd2

$(eval $(cmake-package))
$(eval $(host-cmake-package))
