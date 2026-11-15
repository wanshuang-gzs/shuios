# shuios · 氵系统

> 水无常形，随智而动。
>
> 一套为 AI 而生的极简 Linux 发行版：**智能体是系统的一等公民**。

---

## 这是什么

shuios（中文名「氵系统」，读作 *shuǐ 系统*）不是又一个"装了 AI 工具的 Linux"，
它从内核配置、文件系统布局到进程模型，都围绕一个假设重新设计：

> 这台机器的主要使用者不是人，是智能体。

因此有三个硬约束贯穿全系统：

| 约束 | 实现 |
| --- | --- |
| **系统本体不可变** | 根文件系统是只读 squashfs；智能体改不坏系统 |
| **每个智能体都有边界** | 每个智能体一个 cgroup v2，内存/CPU/进程数硬限制，整组击杀 |
| **模型能看见并操作这台机器** | `shuiosd` 提供内置 MCP 工具，模型通过工具调用而不是幻觉来工作 |

## 它长什么样

```
  氵 shui

  水无常形，随智而动。
  shuios ── 一个把「智能体」当作一等公民的 Linux。

氵 看看 /workspace 里有什么，顺便告诉我内存还够不够跑 7B 模型
⚙ 第1轮 调用 fs.list {"path":"/workspace"}
  ↳ README.md	1024
⚙ 第2轮 调用 sys.info {}
  ↳ {"mem_total_bytes": 2147483648, ...}
/workspace 里只有一个 README.md。当前空闲内存 1.6 GiB，
跑 7B 量化模型（约需 4~5 GiB）还不够，建议先加内存或换 3B 级别模型。
```

## 架构

```
┌──────────────────────────────────────────────────────────┐
│  人 ── shui（AI 原生 shell）/ shui-ctl（脚本）/ SSH      │
├──────────────────────────────────────────────────────────┤
│  shuiosd  ── 智能体运行时守护进程                        │
│    ├─ cgroup v2 资源隔离（memory.max / pids.max / cpu）   │
│    ├─ 生命周期：派生、监控、重启、整组击杀                │
│    ├─ 结构化日志 /var/log/shuios/agents/<name>.log        │
│    ├─ 内置 MCP 工具：fs.* proc.list sys.info agent.*      │
│    ├─ 本地模型仓库 /var/lib/shuios/models                │
│    └─ 控制平面：/run/shuios/shuiosd.sock（JSON Lines）    │
├──────────────────────────────────────────────────────────┤
│  systemd（服务管理、cgroup 树、sandbox 原语）             │
├──────────────────────────────────────────────────────────┤
│  只读 squashfs 根  │  ext4 数据分区 /data                │
│                     └→ /workspace（唯一持久用户目录）     │
│                        /var/lib/shuios（模型、状态）      │
├──────────────────────────────────────────────────────────┤
│  Linux 内核（io_uring / cgroup v2 / landlock / BPF / zram）│
│  UEFI + GRUB2                                             │
└──────────────────────────────────────────────────────────┘
```

## 目录结构

```
shuios/
├── crates/                 自研 Rust 组件
│   ├── shuios-proto/       协议与客户端库（唯一权威的 IPC 契约）
│   ├── shuiosd/            智能体运行时守护进程
│   ├── shui/               AI 原生 shell
│   ├── shui-ctl/           控制 CLI
│   ├── shui-llm/           OpenAI 兼容客户端（本地/远程，V27）
│   └── …                   更新/包管理/动画等其余组件
├── br2-ext/                Buildroot BR2_EXTERNAL 树
│   ├── configs/            板级 defconfig
│   ├── package/            shuios 自有包（预编译二进制安装）
│   └── board/shuios/       rootfs overlay、genimage、GRUB、内核 fragment
├── docs/                   设计与构建文档
├── tools/                 构建脚本、QEMU 启动器、WSL 引导脚本
└── Makefile                一条命令出镜像
```

## 快速开始

前置：一台 Linux（或 Windows + WSL2），装好 `make gcc git wget`.

```bash
make deps                       # Debian/Ubuntu 依赖 + QEMU
make fetch                      # 拉取 Buildroot
make rust                       # 编译 Rust 组件
make build                      # 出镜像 output/images/shuios.img
make run                        # QEMU 里启动它
```

镜像也可以直接写到 U 盘（**认准设备名，写错会毁数据**）：

```bash
sudo dd if=output/images/shuios.img of=/dev/sdX bs=4M status=progress oflag=sync
```

开机后的样子（当前镜像为 **swayfx 桌面**）：

| 位置 | 内容 |
| --- | --- |
| **tty1（图形）** | swayfx 桌面：底部 40px 任务栏（`shui-panel`）+ 开始菜单；点任务栏「终端」打开 `shui` |
| **tty2 / SSH（文本）** | 自动登录 root，直接进 `shui`（AI 原生 shell，`氵 ` 提示符） |

默认 root 密码：`shui`（**请立刻改**）。没有显示设备时（无 DRM 的虚拟机/容器），
桌面会自动回退到 Weston 的 headless 后端而不是死循环重启。

浏览器：预装图形浏览器 `shui-browser`（WebKitGTK 2.48 引擎 + 自研 GTK3 外壳）：
多标签、地址栏搜索、前进/后退/刷新、Ctrl+J 下载气泡、文件保存到 `/workspace/下载`、
中文错误页与起始页。`links` 与 `web.fetch` 仍保留作纯文本后备。

音频：VMware 虚拟 HDA（`tools/run-vmware.ps1` 自动挂 `sound.*` 键）+ 内核内置
codec + **PipeWire 1.2.8 + WirePlumber 0.5.5**（会话内启动，`pipewire-pulse`
提供 PulseAudio 兼容）。任务栏右侧音量按钮（左键静音、滚轮调节、右键设置）
或设置中心「声音」页调音量；音量/静音写在数据分区，重启保留。`aplay` /
`speaker-test` 经 `/etc/asound.conf` 进 PipeWire，多程序自动混音；WebKit 的
视频/音频走 GStreamer `pulsesink`。

AI：设置中心「AI」页或 `shui-ctl ai` 选择提供商——本地 llama.cpp
（`http://127.0.0.1:8080`，无需密钥）或远程 OpenAI 兼容服务（DeepSeek /
通义千问 / Moonshot / OpenAI / 自定义，强制 HTTPS）。密钥只保存在
`/var/lib/shuios/state/ai.json`（0600），由 `shuiosd` 代发请求，不会出现在
命令行、日志或界面回读中；填好后可点「测试连接」验证。

演示步骤与验收数据见 [`docs/08-演示清单.md`](docs/08-演示清单.md)；
冻结镜像与启动脚本：`shuios.img` + `tools/run-vmware.ps1`（3D）/
`tools/run-vm.ps1`（QEMU）。

## 组件速览

| 组件 | 作用 | 关键设计 |
| --- | --- | --- |
| `shuiosd` | 智能体运行时 | 只用 std + serde + libc；线程模型；cgroup v2 直写 |
| `shui` | AI 原生 shell | `/命令` 内置、`!命令` 直通 sh、其余交给推理服务（本地/远程，经 `shuiosd`） |
| `shui-ctl` | 控制 CLI | 面向脚本，输出稳定，无交互 |
| `shuios-update` | A/B 原子升级 | GRUB 环境块状态机；新槽启动失败自动回滚 |
| `shuios-splash` | 开机/关机动画 | 直接写 `/dev/fb0`（Buildroot 没有 plymouth）；自绘 5x7 字体与「氵」 |
| `shui-pkg` | 软件包管理 | 每包一个自带依赖闭包的 squashfs，挂到可写数据分区；自写 SHA-256 与 HTTP GET |
| `shui-store` | 图形软件商店 | GTK3 + Cairo 自绘图标；读 `shui-pkg list --tsv`，点按钮即装/卸 |
| `shui-browser` | 图形浏览器 | WebKitGTK 4.1 + GTK3 外壳（约 1000 行 C）；多标签、下载气泡、错误页；虚拟 GPU 下自动软件渲染 |
| PipeWire 音频 | 系统声音 | PipeWire 1.2.8 + WirePlumber 0.5.5 + `pipewire-pulse`；ALSA 经 `asound.conf` 接入；任务栏/设置音量、静音、重启保留；WebKit 走 GStreamer `pulsesink` |
| AI 推理 | 本地/远程模型 | `shui-llm` OpenAI 兼容客户端（远程 HTTPS 走 curl + 系统 CA）；密钥 0600 由 `shuiosd` 保管并代发；设置中心 AI 页 / `shui-ctl ai`（V27） |
| `shuios-proto` | 协议库 | JSON Lines over Unix socket + MCP 总线类型，全组件共用 |

## 设计取舍（重要）

* **不引入 async 运行时**：单机智能体是几十个量级，一线程一连接更可预测，
  也让镜像里的二进制小得多。
* **不做 Python 预装**：v0.1 的核心是"运行时"而不是"框架"。需要 Python 时
  按需加包，而不是让它成为默认负担。
* **不用容器运行时管理智能体**：直接 cgroup v2 + 进程组，比拉 containerd
  轻得多，也足够表达"隔离"。
* **配置用 JSON 不用 TOML**：只为少一个依赖。这是可替代的细节。

## 现状与路线

当前是 **V27 镜像**：v0.1「泉」、v0.2「溪」已完成；v0.3「河」已交付
中文输入法、文件管理器、Wi-Fi、设置中心、layer-shell 任务栏、锁屏/电源、
PipeWire 音频与 AI 远程提供商/API 密钥；A/B 升级待真机验证，
Landlock/seccomp 沙箱与 AI 审计/RAG 未做。

* **v0.1「泉」**：能启动、能跑 `shuiosd`/`shui`/`shui-ctl`、
  只读根 + 数据分区、UEFI 启动、cgroup 限额、内置 MCP 工具。
* **v0.2「溪」**：swayfx 桌面 + 任务栏/开始菜单、`shui-browser`（WebKitGTK）、
  VMware HDA/ALSA 音频、`shui-pkg`/`shui-store`、A/B 升级代码、MCP 总线。
* **v0.3「河」**（进行中）：技术用户可日用——fcitx5 中文输入 ✅、
  `shui-files` ✅、NetworkManager/Wi-Fi ✅、`shui-settings` ✅、
  layer-shell 任务栏 ✅、锁屏/电源 ✅、PipeWire ✅、AI 密钥/远程提供商 ✅（V27）；
  余下：显示/电源设置、托盘/通知、AI 运行时 v1（权限/审计/模型管理/RAG）、
  VA-API、备份恢复。
* **v0.4「江」/ v1.0「海」**：安装器、多用户、Secure Boot、Fleet 管理、
  OEM/教育/信创合作模块、多架构与规模化。

技术路线见 [`docs/04-路线图.md`](docs/04-路线图.md)；
产品优先级、市场判断与 90 天计划见
[`docs/09-产品规划与市场调研.md`](docs/09-产品规划与市场调研.md)。

## 文档

| 文档 | 内容 |
| --- | --- |
| [01-架构总览](docs/01-架构总览.md) | 分层、进程模型、不可变根的实现 |
| [02-构建指南](docs/02-构建指南.md) | 从零到镜像，含 WSL2 与常见坑（附实测踩坑表） |
| [03-组件与协议](docs/03-组件与协议.md) | RPC 方法表、数据结构、配置项 |
| [04-路线图](docs/04-路线图.md) | 版本计划与未决问题 |
| [05-验证记录](docs/05-验证记录.md) | 实际跑过的验证与证据（含待验证清单） |
| [06-视觉规范](docs/06-视觉规范.md) | 配色、字体、圆角与特效档位 |
| [07-界面规划](docs/07-界面规划.md) | 桌面布局与交互规划 |
| [08-演示清单](docs/08-演示清单.md) | 10 项验收步骤、实测数据与截图证据 |
| [09-产品规划与市场调研](docs/09-产品规划与市场调研.md) | 完整 OS 差距、四级验收、竞品、TAM/SAM/SOM、90 天计划 |

## 许可

Apache-2.0。

---

*「上善若水。水善利万物而不争。」*
