################################################################################
#
# pixman 0.46.4 —— 由 tools/patch-buildroot-deps.sh 复制进 Buildroot 树，
# 替换掉 Buildroot 2025.02 自带的 0.44.2。
#
# wlroots 0.20.0 的 render/pixman 要求 pixman-1 >= 0.46.0。
#
################################################################################

PIXMAN_VERSION = 0.46.4
PIXMAN_SOURCE = pixman-$(PIXMAN_VERSION).tar.xz
PIXMAN_SITE = $(BR2_EXTERNAL_SHUIOS_PATH)/dl
PIXMAN_SITE_METHOD = file
PIXMAN_LICENSE = MIT
PIXMAN_LICENSE_FILES = COPYING
PIXMAN_CPE_ID_VENDOR = pixman

PIXMAN_INSTALL_STAGING = YES
PIXMAN_DEPENDENCIES = host-pkgconf
HOST_PIXMAN_DEPENDENCIES = host-pkgconf

# don't build gtk based demos
PIXMAN_CONF_OPTS = \
	-Dloongson-mmi=disabled \
	-Dvmx=disabled \
	-Dmips-dspr2=disabled \
	-Dopenmp=disabled \
	-Dgnuplot=false \
	-Dgtk=disabled \
	-Dlibpng=disabled \
	-Dtests=disabled

PIXMAN_IGNORE_CVES += CVE-2023-37769

ifeq ($(BR2_X86_CPU_HAS_MMX),y)
PIXMAN_CONF_OPTS += -Dmmx=enabled
else
PIXMAN_CONF_OPTS += -Dmmx=disabled
endif

ifeq ($(BR2_X86_CPU_HAS_SSE2),y)
PIXMAN_CONF_OPTS += -Dsse2=enabled
else
PIXMAN_CONF_OPTS += -Dsse2=disabled
endif

ifeq ($(BR2_X86_CPU_HAS_SSSE3),y)
PIXMAN_CONF_OPTS += -Dssse3=enabled
else
PIXMAN_CONF_OPTS += -Dssse3=disabled
endif

ifeq ($(BR2_ARM_CPU_HAS_ARM),y)
PIXMAN_CONF_OPTS += -Darm-simd=enabled
else
PIXMAN_CONF_OPTS += -Darm-simd=disabled
endif

ifeq ($(BR2_ARM_CPU_HAS_ARM)$(BR2_ARM_CPU_HAS_NEON),yy)
PIXMAN_CONF_OPTS += -Dneon=enabled
else
PIXMAN_CONF_OPTS += -Dneon=disabled
endif

ifeq ($(BR2_aarch64)$(BR2_ARM_CPU_HAS_NEON),yy)
PIXMAN_CONF_OPTS += -Da64-neon=enabled
else
PIXMAN_CONF_OPTS += -Da64-neon=disabled
endif

ifeq ($(BR2_RISCV_ISA_RVV),y)
PIXMAN_CONF_OPTS += -Drvv=enabled
else
PIXMAN_CONF_OPTS += -Drvv=disabled
endif

PIXMAN_CFLAGS = $(TARGET_CFLAGS)

ifeq ($(BR2_TOOLCHAIN_HAS_GCC_BUG_101737),y)
PIXMAN_CFLAGS += -O0
endif

$(eval $(meson-package))
$(eval $(host-meson-package))
