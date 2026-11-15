################################################################################
#
# shuios-runtime — 氵系统 的用户态核心
#
################################################################################

SHUIOS_RUNTIME_VERSION = 0.1.0
SHUIOS_RUNTIME_SITE = $(BR2_EXTERNAL_SHUIOS_PATH)/artifacts
SHUIOS_RUNTIME_SITE_METHOD = local
SHUIOS_RUNTIME_LICENSE = Apache-2.0
SHUIOS_RUNTIME_INSTALL_STAGING = NO

SHUIOS_RUNTIME_BINARIES = shuiosd shui shui-ctl shuios-update shuios-splash shui-pkg
SHUIOS_RUNTIME_UNITS = shuiosd.service shuios-storage.service shuios-firstboot.service shuios-bootok.service shuios-llama.service shuios-desktop.service shuios-bootdiag.service shuios-splash.service shuios-splash-shutdown.service shuios-pkg.service

define SHUIOS_RUNTIME_CHECK_BINARIES
	$(Q)missing=0; \
	for b in $(SHUIOS_RUNTIME_BINARIES); do \
		if [ ! -f "$(@D)/$$b" ]; then \
			echo "*** 缺少预编译二进制: $(@D)/$$b"; \
			missing=1; \
		fi; \
	done; \
	if [ $$missing -ne 0 ]; then \
		echo "*** 请先在构建主机上执行: ./tools/build-rust.sh"; \
		exit 1; \
	fi
endef
SHUIOS_RUNTIME_PRE_INSTALL_TARGET_HOOKS += SHUIOS_RUNTIME_CHECK_BINARIES

define SHUIOS_RUNTIME_INSTALL_TARGET_CMDS
	for b in $(SHUIOS_RUNTIME_BINARIES); do \
		$(INSTALL) -D -m 0755 "$(@D)/$$b" "$(TARGET_DIR)/usr/bin/$$b"; \
	done
	for u in $(SHUIOS_RUNTIME_UNITS); do \
		$(INSTALL) -D -m 0644 "$(SHUIOS_RUNTIME_PKGDIR)/files/$$u" \
			"$(TARGET_DIR)/usr/lib/systemd/system/$$u"; \
	done
	$(INSTALL) -D -m 0644 "$(SHUIOS_RUNTIME_PKGDIR)/files/shuios.json" \
		"$(TARGET_DIR)/etc/shuios/shuios.json"
	$(INSTALL) -D -m 0755 "$(SHUIOS_RUNTIME_PKGDIR)/files/shuios-firstboot.sh" \
		"$(TARGET_DIR)/usr/libexec/shuios/shuios-firstboot"
	$(INSTALL) -D -m 0755 "$(SHUIOS_RUNTIME_PKGDIR)/files/shuios-storage.sh" \
		"$(TARGET_DIR)/usr/libexec/shuios/shuios-storage"
	$(INSTALL) -D -m 0755 "$(SHUIOS_RUNTIME_PKGDIR)/files/shuios-llama.sh" \
		"$(TARGET_DIR)/usr/libexec/shuios/shuios-llama"
	$(INSTALL) -D -m 0755 "$(SHUIOS_RUNTIME_PKGDIR)/files/shuios-session.sh" \
		"$(TARGET_DIR)/usr/libexec/shuios/shuios-session"
	$(INSTALL) -D -m 0755 "$(SHUIOS_RUNTIME_PKGDIR)/files/shuios-desktop.sh" \
		"$(TARGET_DIR)/usr/libexec/shuios/shuios-desktop"
	$(INSTALL) -D -m 0755 "$(SHUIOS_RUNTIME_PKGDIR)/files/shuios-bootdiag.sh" \
		"$(TARGET_DIR)/usr/libexec/shuios/shuios-bootdiag"
	$(INSTALL) -D -m 0644 "$(SHUIOS_RUNTIME_PKGDIR)/files/weston.ini" \
		"$(TARGET_DIR)/etc/xdg/weston/weston.ini"
	$(INSTALL) -D -m 0644 "$(SHUIOS_RUNTIME_PKGDIR)/files/sway-config" \
		"$(TARGET_DIR)/etc/shuios/sway-config"
	$(INSTALL) -D -m 0644 "$(SHUIOS_RUNTIME_PKGDIR)/files/foot.ini" \
		"$(TARGET_DIR)/etc/xdg/foot/foot.ini"
	# ALSA 默认 PCM 走 PipeWire，避免传统程序绕过声音服务器独占硬件
	$(INSTALL) -D -m 0644 "$(SHUIOS_RUNTIME_PKGDIR)/files/asound.conf" \
		"$(TARGET_DIR)/etc/asound.conf"
	# waybar（现成任务栏）：配置 + CSS 主题
	$(INSTALL) -D -m 0644 "$(SHUIOS_RUNTIME_PKGDIR)/files/waybar-config" \
		"$(TARGET_DIR)/etc/xdg/waybar/config"
	$(INSTALL) -D -m 0644 "$(SHUIOS_RUNTIME_PKGDIR)/files/waybar-style.css" \
		"$(TARGET_DIR)/etc/xdg/waybar/style.css"
	$(INSTALL) -D -m 0755 "$(SHUIOS_RUNTIME_PKGDIR)/files/shuios-launch.sh" \
		"$(TARGET_DIR)/usr/libexec/shuios/shuios-launch"
	$(INSTALL) -D -m 0644 "$(SHUIOS_RUNTIME_PKGDIR)/files/10-shuios.conf" \
		"$(TARGET_DIR)/usr/lib/systemd/system.conf.d/10-shuios.conf"
	$(INSTALL) -D -m 0644 "$(SHUIOS_RUNTIME_PKGDIR)/files/90-shuios.conf" \
		"$(TARGET_DIR)/etc/sysctl.d/90-shuios.conf"
	$(INSTALL) -D -m 0644 "$(SHUIOS_RUNTIME_PKGDIR)/files/shuios.tmpfiles.conf" \
		"$(TARGET_DIR)/usr/lib/tmpfiles.d/shuios.conf"
	$(INSTALL) -D -m 0644 "$(SHUIOS_RUNTIME_PKGDIR)/files/pkgrepo.conf" \
		"$(TARGET_DIR)/etc/shuios/pkgrepo.conf"
	# NetworkManager：状态文件走数据分区；连接配置目录也指向持久化路径
	$(INSTALL) -D -m 0644 "$(SHUIOS_RUNTIME_PKGDIR)/files/NetworkManager-10-shuios.conf" \
		"$(TARGET_DIR)/etc/NetworkManager/conf.d/10-shuios.conf"
	# NetworkManager 的连接配置目录指向数据分区。NM 包会先建一个真实
	# 目录，必须先删掉，否则 `ln -sfn` 会在目录里再建一层自指向链接，
	# 连接配置写不出去（表现为 Read-only file system）。
	rm -rf "$(TARGET_DIR)/etc/NetworkManager/system-connections"
	ln -sfn /var/lib/shuios/NetworkManager/system-connections \
		"$(TARGET_DIR)/etc/NetworkManager/system-connections"
	# 内置软件仓库（由 tools/make-pkgrepo.sh 生成；没生成过就跳过，不阻断构建）
	if [ -d "$(BR2_EXTERNAL_SHUIOS_PATH)/pkgrepo" ]; then \
		mkdir -p "$(TARGET_DIR)/usr/share/shuios/pkgrepo"; \
		cp -a "$(BR2_EXTERNAL_SHUIOS_PATH)/pkgrepo/." \
			"$(TARGET_DIR)/usr/share/shuios/pkgrepo/"; \
	else \
		echo "*** 提示：$(BR2_EXTERNAL_SHUIOS_PATH)/pkgrepo 不存在，镜像将不带内置软件仓库"; \
	fi
endef

define SHUIOS_RUNTIME_ENABLE_SERVICES
	mkdir -p $(TARGET_DIR)/etc/systemd/system/multi-user.target.wants
	rm -f $(TARGET_DIR)/etc/systemd/system/multi-user.target.wants/weston.service
	ln -sf ../../../../usr/lib/systemd/system/shuiosd.service \
		$(TARGET_DIR)/etc/systemd/system/multi-user.target.wants/shuiosd.service
	ln -sf ../../../../usr/lib/systemd/system/shuios-storage.service \
		$(TARGET_DIR)/etc/systemd/system/multi-user.target.wants/shuios-storage.service
	ln -sf ../../../../usr/lib/systemd/system/shuios-firstboot.service \
		$(TARGET_DIR)/etc/systemd/system/multi-user.target.wants/shuios-firstboot.service
	ln -sf ../../../../usr/lib/systemd/system/shuios-bootok.service \
		$(TARGET_DIR)/etc/systemd/system/multi-user.target.wants/shuios-bootok.service
	ln -sf ../../../../usr/lib/systemd/system/shuios-llama.service \
		$(TARGET_DIR)/etc/systemd/system/multi-user.target.wants/shuios-llama.service
	ln -sf ../../../../usr/lib/systemd/system/shuios-desktop.service \
		$(TARGET_DIR)/etc/systemd/system/multi-user.target.wants/shuios-desktop.service
	# seatd 的 unit 由 seatd 包安装，这里只负责让它开机自启。
	# 符号链接不要求目标已存在，seatd 没启用时最多是一条悬空链接。
	ln -sf ../../../../usr/lib/systemd/system/seatd.service \
		$(TARGET_DIR)/etc/systemd/system/multi-user.target.wants/seatd.service
	ln -sf ../../../../usr/lib/systemd/system/shuios-bootdiag.service \
		$(TARGET_DIR)/etc/systemd/system/multi-user.target.wants/shuios-bootdiag.service
	# 软件包恢复：开机按清单重新挂载已装软件（没有清单时单元自会跳过）
	ln -sf ../../../../usr/lib/systemd/system/shuios-pkg.service \
		$(TARGET_DIR)/etc/systemd/system/multi-user.target.wants/shuios-pkg.service
	# 网络：NetworkManager 统一管理有线/无线（storage 单元先挂好数据分区）
	ln -sf ../../../../usr/lib/systemd/system/NetworkManager.service \
		$(TARGET_DIR)/etc/systemd/system/multi-user.target.wants/NetworkManager.service
	# 开机动画挂在 sysinit.target（比桌面更早）
	mkdir -p $(TARGET_DIR)/etc/systemd/system/sysinit.target.wants
	ln -sf ../../../../usr/lib/systemd/system/shuios-splash.service \
		$(TARGET_DIR)/etc/systemd/system/sysinit.target.wants/shuios-splash.service
	# 关机动画挂在 shutdown.target
	mkdir -p $(TARGET_DIR)/etc/systemd/system/shutdown.target.wants
	ln -sf ../../../../usr/lib/systemd/system/shuios-splash-shutdown.service \
		$(TARGET_DIR)/etc/systemd/system/shutdown.target.wants/shuios-splash-shutdown.service
endef
SHUIOS_RUNTIME_POST_INSTALL_TARGET_HOOKS += SHUIOS_RUNTIME_ENABLE_SERVICES

$(eval $(generic-package))
