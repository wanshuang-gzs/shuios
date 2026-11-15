################################################################################
#
# marisa-trie — Rime / OpenCC 的字典树库（0.3.1，要求 C++20）
#
################################################################################

MARISA_TRIE_VERSION = 0.3.1
MARISA_TRIE_SITE = $(BR2_EXTERNAL_SHUIOS_PATH)/dl
MARISA_TRIE_SITE_METHOD = file
MARISA_TRIE_SOURCE = marisa-trie-0.3.1.tar.gz
MARISA_TRIE_LICENSE = BSD-2-Clause, LGPL-2.1-or-later
MARISA_TRIE_LICENSE_FILES = COPYING.md
MARISA_TRIE_INSTALL_STAGING = YES

MARISA_TRIE_CONF_OPTS = \
	-DENABLE_TOOLS=OFF \
	-DBUILD_TESTING=OFF \
	-DBUILD_SHARED_LIBS=ON

$(eval $(cmake-package))
