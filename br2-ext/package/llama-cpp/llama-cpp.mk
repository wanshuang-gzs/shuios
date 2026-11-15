################################################################################
#
# llama.cpp — 本地推理引擎（shuios 的 AI 后端）
#
################################################################################

LLAMA_CPP_VERSION = v0.7.0
# 显式指定源码文件名：GitHub 的 archive URL 对 <ref> 后面的文件名不敏感，
# 但 Buildroot 的哈希校验必须与实际保存的文件名一致。
LLAMA_CPP_SOURCE = llama.cpp-$(LLAMA_CPP_VERSION).tar.gz
LLAMA_CPP_SITE = $(call github,ggml-org,llama.cpp,$(LLAMA_CPP_VERSION))
LLAMA_CPP_LICENSE = MIT
LLAMA_CPP_LICENSE_FILES = LICENSE
LLAMA_CPP_INSTALL_STAGING = YES
LLAMA_CPP_DEPENDENCIES = host-pkgconf

# 只构建运行期需要的东西：示例、测试、bench 之外的辅助工具一律关掉。
# GGML_NATIVE=OFF 让编译产物不绑定构建机的 CPU 指令集（镜像要能跑在别人的机器上）。
LLAMA_CPP_CONF_OPTS = \
	-DCMAKE_BUILD_TYPE=Release \
	-DLLAMA_BUILD_TESTS=OFF \
	-DLLAMA_BUILD_EXAMPLES=OFF \
	-DLLAMA_BUILD_TOOLS=ON \
	-DLLAMA_BUILD_SERVER=ON \
	-DLLAMA_CURL=OFF \
	-DGGML_NATIVE=OFF \
	-DGGML_OPENMP=OFF \
	-DGGML_CCACHE=OFF \
	-DGGML_LLAMAFILE=OFF \
	-DBUILD_SHARED_LIBS=ON

# llama.cpp 把可执行文件和共享库都输出到构建目录下的 bin/
define LLAMA_CPP_INSTALL_TARGET_CMDS
	for bin in llama-server llama-cli llama-bench; do \
		if [ -f "$(@D)/bin/$$bin" ]; then \
			$(INSTALL) -D -m 0755 "$(@D)/bin/$$bin" "$(TARGET_DIR)/usr/bin/$$bin"; \
		fi; \
	done
	for lib in $(@D)/bin/*.so $(@D)/bin/*.so.*; do \
		[ -e "$$lib" ] || continue; \
		cp -a "$$lib" "$(TARGET_DIR)/usr/lib/"; \
	done
endef

# 构建后校验：至少要产出 llama-server，否则说明上游改了构建布局。
define LLAMA_CPP_CHECK_BINARIES
	$(Q)if [ ! -f "$(@D)/bin/llama-server" ]; then \
		echo "*** llama.cpp 未产出 bin/llama-server，上游构建布局可能已改变"; \
		echo "*** 请检查 $(@D)/bin 的内容并更新 br2-ext/package/llama-cpp/llama-cpp.mk"; \
		exit 1; \
	fi
endef
LLAMA_CPP_POST_INSTALL_TARGET_HOOKS += LLAMA_CPP_CHECK_BINARIES

$(eval $(cmake-package))
