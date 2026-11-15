# 恢复指引（从这里继续）

> 最后更新：2026-11-01（V27：AI 远程提供商 / API 密钥 / 设置中心 AI 页）
>
> 冻结点：`shuios.img`（2026-11-01 12:13，1,905,795,072 字节，md5
> `c6d475565d0514988768106200d9791c`）已包含本页全部修复、浏览器、
> **PipeWire 音频（混音/音量/静音/重启保留）**、中文输入法、文件管理器、
> NetworkManager 网络管理、shui-settings 设置中心、**AI 远程提供商与 API
> 密钥（DeepSeek/通义千问/Moonshot/OpenAI/自定义）**、**layer-shell 任务栏/开始菜单**
> 与 **锁屏 / 空闲锁定 / 电源**；演示步骤见 `docs/08-演示清单.md`（58 项），
> 验证细节见 `docs/05-验证记录.md` V16–V27。
>
> 产品规划：`docs/09-产品规划与市场调研.md`（差距清单、四级验收、
> 竞品、TAM/SAM/SOM、90 天计划、待拍板事项）。

## 开发闭环（重要）

界面改动**不要**每轮重打镜像。用这两个脚本，一轮 **~10 秒**：

```bash
# GTK 应用（shui-panel / shui-store）
bash /mnt/d/shuios/tools/dev-deploy.sh shui-panel
# Rust 组件（shui-ctl / shuiosd / shui / shui-pkg …）
bash /mnt/d/shuios/tools/dev-deploy-rust.sh
```

浏览器是 C 程序，改 `br2-ext/package/shui-browser/src/shui-browser.c` 后：

```bash
# 约 20 秒：编 shui-browser，再推到 VM 的 /var/lib/shuios/dev/ 启动
# 第一个参数是 VM 的当前 IP（DHCP 可能变），第二个可选是启动 URL
bash /mnt/d/shuios/tools/dev-deploy-browser.sh 192.168.172.135
```

它们把二进制推进 VM 的 `/var/lib/shuios/dev/` 直接跑。
⚠️ 这些是**临时**的：要在正式镜像里生效，最后仍需重打镜像
（浏览器走 `shui-browser-rebuild`，其余见 `tools/wsl-rebuild-all.sh`）。

## 当前状态

| 项 | 状态 |
| --- | --- |
| Rust 组件（8 个 crate） | ✅ 类型检查通过，单元测试全绿（含 swayipc 4 个、htmltext 7 个；V27 新增 `shui-llm`） |
| Buildroot 全量构建 | ✅ 通（BR2_EXTERNAL，Buildroot 2025.02.9） |
| QEMU 启动到桌面 | ✅ 通（swayfx + 自研任务栏；默认 bochs VGA；V24 的 layer 任务栏在 VMware 验收） |
| VMware 启动到桌面 | ✅ 通（`mks.enable3d=TRUE`，GPU=vmwgfx 轻效档，不再回退 Weston） |
| 开机动画 / 关机动画 | ✅ 都已验证（`shuios-splash`，自写帧缓冲绘制） |
| 软件包管理器 `shui-pkg` | ✅ 通（安装/卸载/重启自动恢复；MCP 四个工具） |
| 软件商店 `shui-store` | ✅ 通（GTK3 + Cairo 自绘图标） |
| 任务栏 / 开始菜单 | ✅ `shui-panel` 已是 layer-shell（layer TOP、40px、exclusive_zone 40）：合并式窗口按钮、点击启动/聚焦/最小化、右键关闭、开始菜单 460×520 @410,232（含锁屏/注销/重启/关机）。无 waybar/顶栏/Dock（V24/V25） |
| 锁屏 / 空闲 / 电源 | ✅ `shui-lock`（layer OVERLAY 整屏 + 键盘独占 + `/etc/shadow` `crypt_r()` + 强制 GTK simple IM，防 fcitx 吃键）、`shui-idle`（evdev 计时，默认 600 s，异常退出看门狗恢复 mode）、`shui-key`（Wayland 虚拟键盘验收工具）；Win+L / 菜单 / 空闲三入口；开机/注销/重启/关机已实测，22:27 最终镜像复验空闲锁定/错密/解锁（V25）。无 PAM/登录管理器、无 DPMS/休眠 |
| 浏览器 | ✅ `shui-browser`（WebKitGTK 2.48）：起始页、多标签、下载气泡（Ctrl+J）、错误页；本地纯文本按 UTF-8 解码（V21）；VM 实测（V18）。`links` / `web.fetch` 仍可用 |
| 文件管理器 | ✅ `shui-files`（GTK3，V21）：浏览/导航、新建/重命名/删除、隐藏文件、路径栏、打开文件；Win+E / 任务栏 / 开始菜单三入口。搜索/复制/回收站/U 盘待补 |
| 音频 | ✅ PipeWire 1.2.8 + WirePlumber 0.5.5 + pipewire-pulse（V26）：真实 HDA sink、多程序混音、ALSA via asound.conf、pactl/GStreamer/WebKit；任务栏音量按钮 + 设置声音页；音量/静音写 `audio.conf` 并跨重启恢复。只做默认输出设备，设备切换/麦克风/单应用音量未做；宿主听感需人工 |
| 中文输入法 | ✅ fcitx5 5.1.23 + Rime：冷启动新窗口直接打中文（foot / GTK / 浏览器），`state=2 im=rime`（V20） |
| 网络管理 | ✅ NetworkManager 1.50.2 接管有线（DHCP + DNS stub）与 Wi-Fi（WPA2/WPA3）；networkd 关闭；连接配置持久化到 `/data`（V22）。真机无线待测 |
| 设置中心 | ✅ `shui-settings`（GTK3）：网络页（状态/扫描/Wi-Fi 开关/密码连接/断开，V23）+ 声音页（音量/静音/测试音，V26）+ AI 页（提供商/端点/模型/密钥/测试连接，V27）+ 关于页；Win+I、开始菜单入口。显示/电源/外观/键盘/语言页待补 |
| AI 密钥 / 远程提供商 | ✅ `shui-llm` + shuiosd `ai.*` + 设置 AI 页（V27）：本地 llama.cpp / DeepSeek / 通义千问 / Moonshot / OpenAI / 自定义；远程强制 HTTPS（curl + CA），密钥 0600 由守护进程保管、界面/日志/RPC 只回显末四位；`shui -c` 与 GUI 测试连接均走 daemon。真实服务商成功对话待用户密钥；本地 `.gguf` 未实测 |
| 界面视觉 | ✅ 壁纸 + 中文字体 + 品牌配色（规范见 docs/06-视觉规范.md） |
| 画面叠帧 | ✅ 已修（根因是**跑了两个合成器**，见 docs V14） |
| 分辨率 / 黑块 | ✅ QEMU 换 bochs VGA 后 8 帧采样 0 黑块；virtio-gpu 2D 才有（V16） |
| 帧率 / 空闲 CPU | ✅ wlroots 帧节流补丁：QEMU 250×250 客户端 67.8~72.4 fps @75Hz，空闲 sway 0%（V17） |
| 中文 locale | ✅ `BR2_GENERATE_LOCALE` + `/etc/locale.conf`；foot 可启动（V17） |
| 窗口拖动 | ✅ QEMU QMP 真输入拖动实测（中途帧无残影）；VMware 需人工鼠标（VNC 不收输入） |
| WHPX 硬件加速 | ✅ 可用（`-cpu Haswell,-vmx` 绕开 OVMF 的 MSR 0x3A `#GP`；`run-vm.ps1` 默认就是 whpx，`-Tcg` 才降级） |
| A/B 升级端到端 | ☐ 未验证 |
| VMware 硬件 GL 客户端 | ⚠️ vmwgfx dmabuf 导入失败；软件 GL / shm 客户端正常（V17） |

## 运行 / 演示（冻结镜像，零构建）

```powershell
# VMware（首选，3D 档；首次启动会把 raw 转成 vmdk，约 1 分钟）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\run-vmware.ps1

# QEMU（没装 VMware 时用；bochs VGA + WHPX，实测无黑块）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\run-vm.ps1

# 停机
powershell -NoProfile -ExecutionPolicy Bypass -File tools\run-vmware.ps1 -Stop
```

验收步骤（58 项）与预期结果见 `docs/08-演示清单.md`。

## 构建 / 验证

```powershell
# 重建仓库 + 重打镜像（WSL 的 shui-build 里，约 4~8 分钟）
wsl -d shui-build -u root -- bash /mnt/d/shuios/tools/wsl-rebuild-all.sh
wsl -d shui-build -u root -- sh -c "cp -f /root/test.img /mnt/d/shuios/shuios.img && sync"

# QEMU 截图 + 像素统计（不依赖 GUI 截图）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\vm-shot.ps1 -Out D:\shuios\.cache\a.ppm
py -3 tools\ppm-inspect.py D:\shuios\.cache\a.ppm

# VMware 截图：Workstation 自带 VNC（本机调试时在 .vmx 里开过 5900，无密码，
# 只在可信网络用；run-vmware.ps1 不会自动开它）
node .cache\vnc-grab.mjs 127.0.0.1 5900 .cache\shot.png
```

## 下一步（按优先级）

0. **v0.3 P0 进度**（`docs/09` §6.2，方向已定）：fcitx5/中文输入 ✅（V20）、
   shui-files 文件管理器 ✅（V21）、NetworkManager/Wi-Fi ✅（V22）、
   shui-settings 设置中心 ✅（V23）、layer-shell 任务栏 ✅（V24）、
   锁屏/电源 ✅（V25）、PipeWire 音频 ✅（V26）、**AI 密钥/远程提供商 ✅（V27）**
   → 继续 **AI 运行时 v1 的其余部分**（授权 UI、审计、Landlock/seccomp、
   模型管理、RAG、多智能体）。真实远程对话需要用户提供服务商密钥：
   当前已验证到 HTTPS/TLS 与 HTTP 401，配置恢复后功能链路全部可复验。
   真机 Wi-Fi 验证按用户要求押后；下面的战术项可并行。
1. **VMware 人工鼠标/键盘验收（10 分钟）**：启动后拖窗口、点任务栏、开开始菜单、
   点关机；`Win+L` 后用真实键盘输入密码解锁。渲染与交互已由 VNC 截图 +
   合成输入验证，宿主真实输入链路只能人工过一遍。
2. **A/B 升级端到端验证**：`shuios-update apply` 写 B 槽 → 重启进 B →
   `boot-ok` 提交；再故意写坏 B 槽验证自动回滚。代码已就绪但没有真机验证过。
3. **远程软件仓库**：`shui-pkg` 支持 `repo = http://...`（自写 HTTP GET，
   只支持明文），但没有对真实 HTTP 服务跑过。宿主机架 `python -m http.server`
   即可验证。
4. **更多软件包**：`tools/make-pkgrepo.sh` 的 `PKGS` 加一项，
   再在 `sym_of()` / `deps_of()` 登记即可。GUI 应用要自己写
   （Buildroot 里的 pcmanfm/leafpad 都依赖 Xorg）。
5. **浏览器打磨（可选）**：下载历史 / 取消 / 另存为；网页视频逐站点验证；
   真机上走硬件 GL（现在虚拟 GPU 下是软件渲染）。
6. **音频打磨（可选）**：输出设备切换（HDMI/耳机）与麦克风选择；单应用音量；
   托盘音量弹层；蓝牙音频（BlueZ）；USB 声卡实测。混音与音量持久化已在 V26 交付。

## 已知小瑕疵

- foot 的 CSD 标题栏是 GTK 默认浅灰，和顶栏玻璃质感不完全一致（纯外观）
- sway 光标用内置默认主题，没有 `dnd-move` 抓取光标（拖动时指针不变形）
- xkb 缺 Compose 文件（死键不可用）
- fontconfig 警告 `44-wqy-zenhei.conf: multiple values in <test>`（无害）
- 全屏 1280×800 软件渲染客户端在 QEMU 下约 37 fps（llvmpipe 极限，不是合成器问题）
- vmwgfx 上硬件缓冲 EGL 客户端 dmabuf 导入失败（V17）；软件 GL / shm 客户端正常
- 镜像里的 `shuios-bootdiag.sh` 仍查旧 `weston` 单元；源码已改成查
  `shuios-desktop`，但 Buildroot 不会因文件内容变化自动重装该包，重打镜像时
  需先 `make shuios-runtime-reinstall` 才会生效
- 浏览器：WebKit 沙箱不可用（镜像无 `bwrap`）；下载无历史/取消；虚拟 GPU 下
  是软件渲染（大页面滚动偏慢）
- 音频：只管理默认输出设备，没有设备切换/麦克风/单应用音量，也没有托盘
  音量弹层；音量持久化只覆盖 `shui-settings` / `shui-panel` 发起的修改
  （SSH 直接 `wpctl` 改的不写状态文件）；宿主扬声器听感未自动验证
  （guest 内 ALSA→PipeWire→sink / pactl / GStreamer / WebKit 已验证）
- AI：只完成密钥链路与远程提供商接入；没有真实服务商密钥的成功对话
  （已验证到 HTTPS/TLS 与 HTTP 401）；本地 `.gguf` 自动选型/启动未实测；
  只有一次性 chat，无流式/取消/多轮持久化；无远程模型列表，模型名手填；
  设置页不暴露 timeout/temperature；密钥是 0600 明文文件、无系统密钥环，
  `shuiosd` 以 root 运行
- 文件管理器：无搜索/复制/移动/回收站（Delete 直接删）/U 盘挂载 UI；
  打开文件只区分「可执行」与「交给浏览器」；开始菜单已开时再点开始按钮会
  先关后立刻重开（焦点丢失与 pgrep 竞态，不影响使用）
- 设置中心：有「网络 / 声音 / AI / 关于」四页（显示/电源/外观/键盘/语言待补）；
  不支持 802.1X/WEP；
  隐藏 SSID 不会自动连，需 `nmcli` 定向配置；未做单实例（重复 Win+I 会开多个
  窗口）；测试 AP 无 DHCP，新建配置的自动取址未验；真实无线网卡未实测
  （V22/V23 都用 mac80211_hwsim 虚拟无线电验证）
- 任务栏：没有窗口缩略图/多窗口分组（一个 app 一个按钮）；右键直接关窗、
  没有上下文菜单；裸 Win 键未绑定开始菜单（`Super+D`）；音量按钮已有（V26），
  托盘弹层未做；任务栏/开始菜单动作暂无 MCP 等价物（V24）
- 锁屏：swayfx 0.6 无 `ext-session-lock`，是 layer OVERLAY + 键盘独占 +
  binding mode 的组合，不是合成器级安全锁；无 PAM/独立登录会话，密码不限速；
  不关屏（无 DPMS）、不支持挂起/休眠/合盖；「注销」= 重启 sway 会话（V25）
- QEMU 的 `-Gl`（virtio-gpu-gl-pci）在本机会让 QEMU 崩在 NVIDIA 的 `nvoglv64.dll`
  （0xc0000005），所以默认不开；VMware 开 3D 后合成走宿主 GPU（sway 8%）

## 别踩的坑（血泪清单）

* `.ps1` 必须是**纯 ASCII**（PS 5.1 无 BOM 时按 ANSI 读，中文注释会让整个脚本解析失败）
* 不要在 PowerShell 内联串里写 `$?` `$()` `|` —— 用脚本文件
* 不要在 UTF-8 文件上做 `Get-Content -Raw | Set-Content` 往返（会毁掉编码）
* 改 defconfig 后必须重新 `<board>_defconfig`；改包配置后必须 `dirclean` 该包
* **`rsync br2-ext` 不要加 `--delete`**：`/root/shuios/br2-ext/artifacts/` 的
  预编译 Rust 二进制只存在于构建机（工作区没有），`--delete` 会删光，
  下一次构建卡在 `*** 缺少预编译二进制`。恢复：WSL 里
  `cd /root/shuios && ./tools/build-rust.sh`（记得 `export PATH=/root/.cargo/bin:$PATH`，
  非交互 shell 不读 .bashrc），再 `shuios-runtime-dirclean` 后重跑 make
* 改**本地包源码**（shui-panel / shui-browser / shui-files …）也一样：
  `<pkg>-rebuild` 不会重新 rsync 源码，必须先把包目录 rsync 到
  `/root/shuios/br2-ext/...`，再 `<pkg>-dirclean && <pkg>-rebuild`
* `make <pkg>` 不会重装文件（install stamp 还在），要 `<pkg>-reinstall`
* 帧缓冲绘制必须按行批量写（逐像素在 TCG 下慢到看不见）
* 写 `/dev/fb0` 在合成器持有 DRM master 时**不会显示**（fbcon 被隐藏）
* **UEFI 变量文件坏了会假死**：现象是串口停在 `Booting ...`、SSH 连不上、`/Image`
  明明在。删掉 `D:\shuios\.cache\ovmf\OVMF_VARS_run.fd` 从 `OVMF_VARS_4M.fd` 重建即可。
  （起因：同时跑两个 QEMU 实例碰同一个镜像/变量文件）
* **别同时跑两个 QEMU**（同一个 img 或 OVMF_VARS）——会写坏镜像或 NVRAM
* waybar 需要 session D-Bus（否则 `Cannot autolaunch D-Bus without X11 $DISPLAY` 直接退出）
* locale 数据不是"重编 glibc"：Buildroot 要设 `BR2_GENERATE_LOCALE="zh_CN.UTF-8 ..."`
  才会生成 `/usr/lib/locale/locale-archive`；不生成时连 `C.UTF-8` 都没有，
  foot 直接拒绝启动、GTK 报 `Locale not supported`（V17 已修）
* **bochs 显卡不按 vblank 节流**：wlroots 会给客户端无限发 frame 事件
  （实测 176→334 fps、sway ~300% CPU）。靠 `patches/wlroots/*/0001-drm-pace-frame-events.patch`
  夹到刷新率；不要靠"换 virtio-gpu"解决——那是黑块；`-Gl` 会崩宿主 NVIDIA 驱动
* **Workstation 自带 VNC 只出画面、不收输入**：实测 RFB PointerEvent 发到
  (800,400) 后光标不动。别拿它做点击/拖动自动化；VMware 输入只能人工验证
* **任务栏是 layer-shell，不在窗口树里**：`shui-ctl windows` / `get_tree` 找不到它，
  验证要找 `"namespace": "shui-panel"` 的 layer 条目；旧的浮动 Dock 规则已删，
  不要再对 `[app_id="shui-panel"]` 做 `resize set / move position`
* **layer surface 不能弹 xdg_popup**：GtkMenu 在任务栏上弹不出来；开始菜单必须是
  独立 toplevel（`shui-panel --menu`，app_id `shui-panel-menu`）；右键也没有
  上下文菜单，只能直接关窗
* **`move position` 相对工作区原点**：outer gaps 让原点变成 (16,16)，同一
  条 `for_window` 规则在冷启动与用过窗口后差 16px；需要精确落位的窗体
  （开始菜单）用 `move absolute position`（V24）
* **合成指针 `cursor set` 是异步的**：设完坐标立刻 press 会按在旧位置；
  脚本必须 set → 等 250ms → press（V24 踩过：菜单没关、还误点了浏览器）
* **没有 open-vm-tools 时 `vmrun stop soft` 会一直阻塞**（不是等 60s 超时，
  是 vmrun 本身不返回）：先 SSH `systemctl poweroff`，等机器下线再跑重启脚本
* waybar 硬依赖 `xkbregistry`，而 Buildroot 的 libxkbcommon 默认 `-Denable-xkbregistry=false`；
  用 `tools/wsl-enable-xkbregistry.sh` 打开（幂等）
* **VMware 里必须开 3D**：`mks.enable3d = "FALSE"` 时 guest 的 vmwgfx 建不出 EGL screen
  （串口 `VMware: No 3D enabled` → `failed to create dri2 screen`）→ swayfx 退出 →
  静默回退 Weston（没有 layer-shell，waybar/Dock 全灭，还有鼠标黑块）。
  vmwgfx 又不实现 dumb buffer，所以 `kms_swrast` 兜底在它身上不成立——只能开 3D。
  `tools/run-vmware.ps1` 现在每次启动前自动校正这几个键
* **软件渲染档不要开 blur**：swayfx 的 blur 背景纹理在 llvmpipe 下逐帧不稳定，
  半透明面板每次重绘都采到不同底色 = 整条菜单栏颜色跳（用户看到的"虚闪"），
  而且每跳一次就是整条脏区，合成器永远闲不下来。实测见 docs/05 V16
* **QEMU 别用 virtio-gpu 2D**：宿主机侧 surface 只收到脏矩形的局部传输，新资源
  没传到的区域是黑的 —— 屏幕上是 64 像素对齐的黑块，冷启动后能持续几分钟。
  `run-vm.ps1` 默认已改成 bochs VGA（同一镜像实测 0 黑块、指针移出移回后桌面
  变化 0 像素）；`-Virtio` 只用来复现这个问题。
* `.ps1` 被 `Get-Content -Raw | Set-Content` 往返过多次后会**堆 BOM**
  （`run-vm.ps1` 一度有 12 个），PS 只认第一个，剩下的会把 `param()` 块打成
  语法错误。用 `[IO.File]::WriteAllLines` + `UTF8Encoding($false)` 而不是 Set-Content
* **fcitx5 在 system 服务里必须有 HOME**：`src/server/main.cpp` 见 HOME 为空
  直接 `Please set HOME.` 退出；`shuios-session` 已 export 到
  `/var/lib/shuios/home`。另外 `ActiveByDefault` 默认是 false，出厂 `config`
  必须写 `True`，否则每个新窗口都从英文开始（V20）
* **合成键盘验收要等焦点就绪**：`zwp_virtual_keyboard_v1` 没有真实指针点击，
  WebKit 窗口映射后约 40 s 输入法过滤器才就绪；注入太早按键会直落拉丁字母。
  半遮挡的 WebKit 窗口在 resize 前不重绘，验收时用单窗口（V20）
* **`systemctl preset-all` 在 post-build 之后跑**（Buildroot ROOTFS_PRE_CMD）：
  在 post-build 里 `systemctl disable` 没用，会被默认 preset 重新 enable。
  想关某单元要写 `/etc/systemd/system-preset/00-shuios.preset`（编号小于
  Buildroot 的 90-default.preset）。V22 的 networkd / network.service 就靠它
* **`ln -sfn` 盖在真实目录上会生成目录内自指链接**，不是替换。要
  `rm -rf` 目标目录再建链接；症状是 NM 写连接配置报 Read-only file system（V22）
* **`mac80211_hwsim` 两端同机，ping 通是假证据**：AP 和客户端在同一个内核里，
  `10.10.10.x` 互 ping 走本机回环。无线是否真的关联看 `nmcli` state 100、
  `iw link Connected`、hostapd station dump（V22）
* **镜像没有 `getent`**：DNS 验收用 `ping example.com` 或 `resolvectl query`；
  别再拿 `getent hosts` 判 DNS 失败
* **nmtui 编不进来**：newt 0.52.23 源码包在 pagure.io 归档后 404、Debian
  orig 包哈希不符；用 `nmcli`，图形界面由 `shui-settings` 提供
* **GTK 窗口关闭 ≠ 进程退出**：`gtk_main()` 只认 `gtk_main_quit()`，销毁窗口
  不会结束主循环。V23 的 `shui-settings` 点 × 后进程残留，补
  `destroy → gtk_main_quit` 才正常；新 GTK 应用照 `shui-files` 的写法连一次
* **根分区只读（squashfs）**：开发期 `scp` 覆盖 `/etc/shuios/sway-config` 或往
  `/usr/share/applications` 加 `.desktop` 会报 Failure。临时验证用 bind mount
  （单文件）或 tmpfs 叠加（目录）；正式文件必须随包构建安装（V23）
* **hwsim 测试 AP 没有 DHCP**：GUI 新建配置是 `ipv4.method auto`，在这种 AP 上
  会卡在获取地址。验收密码/连接链路时预置 manual 配置；别把它当成 GUI 的 bug
  （V23）
* **layer-shell 的 `exclusive_zone=-1` 才是整块输出**：写 0 会进入非独占排列，
  被任务栏的 `exclusive_zone=40` 裁成 1280×760，锁屏底部露出任务栏（V25）
* **wlroots 虚拟键盘不会自己推导修饰键**：`zwp_virtual_keyboard_v1.key` 带
  `update_state=false`，每发一键都要再发 `modifiers`，否则 `Win+L` 只有 `l`
  生效（V25 踩过）
* **GTK 输入框的错误提示要注意信号顺序**：先清空 entry 会触发 `changed`
  → `hide_error`，把刚显示的错误提示立刻藏掉；必须先清空再显示（V25）
* **锁屏要强制 GTK simple IM**：会话 `GTK_IM_MODULE=fcitx`，fcitx 在中文态会
  把密码键吃进 preedit、把 Enter 当候选提交。锁屏在 `gtk_init` 后设
  `gtk-im-module=gtk-im-context-simple`；合成虚拟键盘不经 fcitx，自动化
  验收测不出这一类问题（V25）
* **Buildroot 的 PipeWire 系统单元会抢走声卡**：`pipewire.service` /
  `pipewire.socket` / `pipewire-manager.socket` / `wireplumber.service` /
  `wireplumber@.service` 以 `pipewire` 用户、`/run/pipewire` 运行，先占 HDA；
  会话再起实例只能拿 Dummy Output。post-build 必须 `ln -sf /dev/null` 全部
  mask（V26 踩过）
* **GStreamer 1.24 的 Pulse 插件叫 `libgstpulseaudio.so`**，不是
  `libgstpulse.so`；改了 `BR2_PACKAGE_GST1_PLUGINS_GOOD_PLUGIN_PULSE` 后
  `gst1-plugins-good` 可能因旧 stamp 不再重编，要 `dirclean` 再编（V26）
* **WirePlumber 不持久化默认 sink 音量**：冷启动回 40%。要自己写
  `/var/lib/shuios/state/audio.conf`；恢复不能在 `start_audio()` 里立刻写，
  要等 `@DEFAULT_AUDIO_SINK@` 出现后再等 1 s（WP 建卡后会补默认音量），
  否则恢复值被覆盖（V26）
* **`speaker-test -l 1` 在 PipeWire 下播完不退出**：进程卡在 poll、
  sink-input 残留。界面用 9 s 看门狗 kill；命令行验收也要自己收尾
  （镜像没有 `timeout`）（V26）
* **gtk_stack 的 CROSSFADE 不能 show_all 前切页**：`gtk_widget_show_all()`
  之前 `gtk_stack_set_visible_child_name()` 不生效（导航选中、内容仍旧页）。
  初始页在 show_all 后切；导航用 `row-activated`（V26 一度用 `row-selected`，
  V27 发现 Tab 经过导航行会切页、焦点被锁在侧栏后改回）
* **VMware HDA 的 ALSA xrun / `Broken pipe` 警告是噪音**：长时间/高负载
  播放时 `audio.log` 会刷 `snd_pcm_avail after recover`，不影响实际播放；
  别拿它判音频坏了（V26）
* **`BR2_PACKAGE_LIBCURL_CURL` 是 `BR2_PACKAGE_LIBCURL` 的子选项**：只写前者
  会被 Kconfig 静默丢弃，镜像里没有 curl；远程 HTTPS 还要
  `BR2_PACKAGE_LIBCURL_OPENSSL` + `BR2_PACKAGE_CA_CERTIFICATES`。改完
  `make libcurl-dirclean` 再编，否则旧 stamp 会复用无 TLS 的二进制（V27）
* **GTK 工作线程结束后要 `g_idle_add`**：AI 测试线程只 return 不调度主循环，
  按钮会永远停在「正在连接推理服务…」；结果必须回到主线程更新控件（V27）
