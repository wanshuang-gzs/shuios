# shuios 顶层 Makefile —— 把「编译 Rust 组件」和「构建镜像」两条流水线串起来
#
# 常用：
#   make rust            编译 Rust 组件到 br2-ext/artifacts/
#   make build           构建完整镜像（需要先 make rust）
#   make run             QEMU 启动
#   make clean-build     清掉 Buildroot 输出（保留 Rust 产物）

SHELL := /bin/bash

ROOT := $(shell pwd)
BR2_EXT := $(ROOT)/br2-ext
BUILDROOT_VERSION ?= 2025.02.9
BUILDROOT_TARBALL := buildroot-$(BUILDROOT_VERSION).tar.xz
BUILDROOT_URL ?= https://buildroot.org/downloads/$(BUILDROOT_TARBALL)
BR_DIR := $(ROOT)/buildroot

JOBS := $(shell nproc 2>/dev/null || echo 4)

.PHONY: help rust build buildroot fetch run clean clean-build distclean deps check

help:
	@echo "shuios (氵系统) 构建入口"
	@echo ""
	@echo "  make deps         安装构建主机依赖（Debian/Ubuntu）"
	@echo "  make fetch        下载并解压 Buildroot $(BUILDROOT_VERSION)"
	@echo "  make rust         编译 Rust 组件（shuiosd / shui / shui-ctl）"
	@echo "  make build        完整构建镜像 -> output/images/shuios.img"
	@echo "  make run          QEMU 启动镜像"
	@echo "  make check        Rust 组件语法/编译检查"
	@echo "  make clean-build  删除 Buildroot 输出"
	@echo ""

deps:
	@echo ">>> 安装构建依赖（需要 sudo）"
	sudo apt-get update
	sudo apt-get install -y build-essential git wget cpio unzip rsync bc \
		libncurses-dev file python3 libssl-dev qemu-system-x86 ovmf \
		dosfstools mtools e2fsprogs rsync patch perl

fetch:
	@if [ ! -d "$(BR_DIR)" ]; then \
		echo ">>> 下载 Buildroot $(BUILDROOT_VERSION)"; \
		wget -q --show-progress -O "$(ROOT)/$(BUILDROOT_TARBALL)" "$(BUILDROOT_URL)"; \
		tar -xf "$(ROOT)/$(BUILDROOT_TARBALL)" -C "$(ROOT)"; \
		mv "$(ROOT)/buildroot-$(BUILDROOT_VERSION)" "$(BR_DIR)"; \
	else \
		echo ">>> Buildroot 已存在: $(BR_DIR)"; \
	fi

# 若存在本地源码镜像（tools/fetch-deps.sh 生成），自动用作主下载源
PRIMARY_SITE := $(shell test -f "$(ROOT)/.primary-site" && sed 's|^|file://|' "$(ROOT)/.primary-site" || true)
BR2_EXTRA := $(if $(PRIMARY_SITE),BR2_PRIMARY_SITE=$(PRIMARY_SITE),)

rust:
	./tools/build-rust.sh

check:
	cargo check --workspace --target x86_64-unknown-linux-gnu
	cargo clippy --workspace --target x86_64-unknown-linux-gnu --all-targets -- -D warnings

test:
	cargo test -p shuios-proto
	cargo test -p shui --lib

verify: check test
	@echo ">>> 本地静态验证通过（无需 Linux 环境）"

build: fetch rust
	@echo ">>> 构建 shuios 镜像（-j$(JOBS)）"
	$(MAKE) -C "$(BR_DIR)" BR2_EXTERNAL="$(BR2_EXT)" $(BR2_EXTRA) shuios_x86_64_defconfig
	$(MAKE) -C "$(BR_DIR)" BR2_EXTERNAL="$(BR2_EXT)" $(BR2_EXTRA) -j$(JOBS)

run:
	./tools/qemu-run.sh "output/images/shuios.img"

clean-build:
	@if [ -d "$(BR_DIR)" ]; then $(MAKE) -C "$(BR_DIR)" BR2_EXTERNAL="$(BR2_EXT)" clean; fi

clean: clean-build

distclean:
	@if [ -d "$(BR_DIR)" ]; then $(MAKE) -C "$(BR_DIR)" distclean; fi
	rm -rf output
