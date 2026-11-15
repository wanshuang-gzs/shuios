################################################################################
#
# iso-codes — ISO 国家 / 语言 / 货币代码数据
#
################################################################################

ISO_CODES_VERSION = 4.20.1
ISO_CODES_SITE = $(BR2_EXTERNAL_SHUIOS_PATH)/dl
ISO_CODES_SITE_METHOD = file
ISO_CODES_SOURCE = iso-codes-4.20.1.tar.xz
ISO_CODES_LICENSE = LGPL-2.1-or-later
ISO_CODES_LICENSE_FILES = LICENSES/LGPL-2.1-or-later.txt
ISO_CODES_INSTALL_STAGING = YES
ISO_CODES_DEPENDENCIES = host-pkgconf

$(eval $(meson-package))
