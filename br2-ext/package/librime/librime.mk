################################################################################
#
# librime — Rime 输入法引擎
#
################################################################################

LIBRIME_VERSION = 1.17.0
LIBRIME_SITE = $(BR2_EXTERNAL_SHUIOS_PATH)/dl
LIBRIME_SITE_METHOD = file
LIBRIME_SOURCE = librime-1.17.0.tar.gz
LIBRIME_LICENSE = BSD-3-Clause
LIBRIME_LICENSE_FILES = LICENSE
LIBRIME_INSTALL_STAGING = YES

LIBRIME_CONF_OPTS = \
	-DBUILD_TEST=OFF \
	-DBUILD_SAMPLE=OFF \
	-DBUILD_STATIC=OFF \
	-DENABLE_LOGGING=ON \
	-DRIME_DATA_DIR=rime-data

LIBRIME_DEPENDENCIES = \
	boost \
	gflags \
	glog \
	host-pkgconf \
	leveldb \
	marisa-trie \
	opencc \
	yaml-cpp

$(eval $(cmake-package))
