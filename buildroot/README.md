# 构建氵系统镜像

这一层把 shuios 从"装在别人系统上的应用"变成**一套能开机的系统**。

---

## 产出什么

| 文件 | 用途 |
|---|---|
| `shuios-YYYYMMDD-x86_64.iso` | 混合镜像：可刻盘，也可 `dd` 到 U 盘直接引导 |
| `使用说明.txt` | 随镜像一起交付 |

**开机流程：**

```
BIOS/UEFI → 内核 → init → shuios（eglfs 直接画在屏幕上）
```

没有登录管理器、没有桌面环境、没有 shell 提示符。

---

## 为什么用 eglfs，不用 cage

前一轮实测发现：**Buildroot 2024.02 的 Qt6 没有 qt6declarative（QML）模块**，
shuios 是 QML 应用，根本编译不了。

改用 **Buildroot 2025.02 LTS** 后确认具备：

| 符号 | 作用 |
|---|---|
| `BR2_PACKAGE_QT6DECLARATIVE` + `_QUICK` | QML / Quick |
| `BR2_PACKAGE_QT6WAYLAND` + `_COMPOSITOR` | Wayland 合成器（实验性） |
| `BR2_PACKAGE_QT6BASE_EGLFS` | **直接 DRM/KMS 渲染** |

`eglfs` 是关键：Qt 直接向内核的 DRM/KMS 提交画面，
**不需要任何合成器或桌面环境**。屏幕上的第一个画面就是 shuios。

```
BIOS → 内核 → init → shuios (eglfs) → 屏幕
                        ↑
              shuios 自己就是"身体"
```

比 cage 方案更贴近设计目标：cage 还隔着一层，eglfs 没有。

## 本地构建

```bash
# 依赖（Debian/Ubuntu）
sudo apt install build-essential bison flex rsync bc cpio unzip file \
                 libncurses-dev libssl-dev libelf-dev python3

# 取 Buildroot
git clone --depth 1 --branch 2024.02.x \
    https://github.com/buildroot/buildroot.git buildroot-src

# 配置
cd buildroot-src
make O=$PWD/../output BR2_EXTERNAL=$PWD/../buildroot shuios_x86_64_defconfig

# 编译（4 核约 2–4 小时）
make O=$PWD/../output BR2_EXTERNAL=$PWD/../buildroot -j$(nproc)

# 产物
ls ../output/images/
```

---

## 在 GitHub Actions 上构建

`.github/workflows/build-iso.yml` 干两件事：

1. **配置校验**（2 分钟）—— 只跑 `defconfig`，确认符号没写错
2. **全量构建**（最长 350 分钟）—— 出 ISO

**为什么先校验**：全量编译动辄数小时，如果配置写错了，
不值得浪费时间。先花两分钟确认。

**缓存**：`output/dl` 目录（源码包）会被缓存，
第二次构建省掉所有下载时间。

---

## 装到 U 盘

**Linux / macOS**
```bash
sudo dd if=shuios-*.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

**Windows** — 用 Rufus 或 balenaEtcher

> ⚠️ `/dev/sdX` 必须换成你 U 盘的设备名。写错会毁掉你的硬盘。

---

## 配置 AI 大脑

镜像里**不含任何 API Key**。三种方式写入：

**1. 开机前写进 U 盘**（推荐）
```bash
mount /dev/sdX1 /mnt
echo "sk-your-key" > /mnt/etc/shuios/key
umount /mnt
```

**2. 开机后进终端**
按 `Ctrl+Alt+F2`，登录后：
```sh
echo "sk-your-key" > /etc/shuios/key
reboot
```

**3. 构建时注入**（仅限私有构建）
在仓库 Secrets 里设 `SHUIOS_DEEPSEEK_KEY`，
post-build 脚本会写进镜像。

---

## 目录结构

```
buildroot/
├── external.desc                    外部树标识
├── external.mk
├── Config.in
├── configs/
│   └── shuios_x86_64_defconfig      ★ 主配置（要改什么就改这里）
├── board/shuios/
│   ├── linux.fragment               内核配置（i915 / 网络 / 文件系统）
│   ├── post-build.sh                rootfs 后处理
│   ├── post-image.sh                镜像改名 + 使用说明
│   └── rootfs-overlay/
│       ├── etc/inittab              ★ 开机直接进 shuios
│       ├── etc/init.d/S40network    DHCP
│       ├── etc/hostname
│       └── usr/bin/shuios-session   ★ 会话启动脚本
└── package/
    ├── shuios/                      shuios 的 Buildroot 包
    └── qt6waylandcompositor/        自研合成器（预留，默认不启用）
```

---

## 已知风险（诚实说明）

| 风险 | 说明 |
|---|---|
| **首次构建可能失败** | 配置符号、依赖关系都未经真机验证，第一轮大概率报错 |
| **中文字体** | `BR2_PACKAGE_WQY_ZENHEI` 已确认存在，中文可正常显示 |
| **Mesa 驱动名** | `iris` 驱动符号可能因 Buildroot 版本而异 |
| **构建时长** | 全量编译接近 Actions 6 小时上限，可能超时 |
| **真机未验证** | 镜像能否在 N100 上引导，只有你实测才知道 |

**这一层的现实**：Buildroot 的配置正确性高度依赖实测。
第一轮跑完，我会根据日志逐个修符号名和依赖 —— 和之前修 CMake
是同一个过程，只是每轮更慢。
