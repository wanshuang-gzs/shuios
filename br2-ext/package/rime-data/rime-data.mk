################################################################################
#
# rime-data — Rime 共享数据（只装数据，无编译）
#
################################################################################

RIME_DATA_VERSION = 20261031
RIME_DATA_SITE = $(BR2_EXTERNAL_SHUIOS_PATH)/dl
RIME_DATA_SITE_METHOD = file
RIME_DATA_SOURCE = rime-data-20261031.tar.gz
RIME_DATA_LICENSE = GPL-3.0-or-later, CC-BY-4.0
RIME_DATA_LICENSE_FILES = LICENSE

define RIME_DATA_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)/usr/share/rime-data
	# 上游快照的顶层目录在解包时已被 strip-components 去掉，这里按后缀收数据文件
	cd $(@D) && cp -a *.yaml *.txt LICENSE AUTHORS README.md \
		$(TARGET_DIR)/usr/share/rime-data/
endef

$(eval $(generic-package))
