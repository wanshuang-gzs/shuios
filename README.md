# 氵系统 · shuios

**一套为 AI 重新设计的桌面环境。**

> 系统是身体，AI 是大脑。身体留在这里，大脑在云上。

---

## 这是什么

shuios 不是一个跑在 GNOME/KDE 上的应用，**它本身就是桌面**——
基于 Qt Wayland Compositor 自建，显示服务器、窗口管理、AI 界面在同一个进程里。

它要解决一个普通 Linux 桌面没解决的问题：

> **AI 会犯错，也会幻觉。你不可能给它 root。**

所以 shuios 换了问法：不问「你是谁」，问「**你这次要做什么**」。

| | 传统 Linux | 氵系统 |
|---|---|---|
| 身份 | uid/gid，长期有效 | 无长期高权身份 |
| 授权 | setuid 一次，永久生效 | 每动作一枚凭据，120 秒过期 |
| 粒度 | 文件模式位 | 能力名 + 路径作用域 + 次数 |
| 危险操作 | 靠人记得小心 | DANGER 级强制停下等人 |
| 审计 | syslog，可关可改 | append-only 账本，立即 fsync |
| 用户接口 | 你得知道命令怎么拼 | 你说人话，系统给计划 |

---

## 三条铁律

**一、AI 永远不持有万能钥匙**

`kernel.modify`、`pay.transfer`、`cap.grant` 属于 ALWAYS 级，
**AI 在架构上签不出来**，必须人类显式批准。

**二、越权 = 动作不发生**

凭据带路径作用域，且做**边界安全**的前缀比较：

```
授权 /home/user/docs
  ├─ /home/user/docs/a.txt      → 放行
  ├─ /etc/passwd                → 拒绝
  └─ /home/user/docs_evil/x     → 拒绝  ← 不是简单 startswith！
```

第三行是最容易写错的地方。如果退化成 `startsWith()`，就是权限逃逸漏洞。

**三、看不懂就拒绝，不猜**

```
你：把服务器重启一下
氵：这条指令我无法确信理解 —— shuios 拒绝猜测执行。
```

AI 系统最危险的失败不是报错，是自信地做错事。

---

## 界面

黑白简约，中文优先，底部任务栏。

```
┌──────────────────────────────────────────────────┐
│  氵  shuios                        ● 大脑 DeepSeek │
├──────────────────────────────────────────────────┤
│                                                  │
│                        ┌──────────────────────┐  │
│                        │ 把下载文件夹整理一下  │  │
│                        └──────────────────────┘  │
│                                                  │
│  ┌────────────────────────────────────────┐      │
│  │ 我理解你想做这些：                      │      │
│  │  1. [只读] 扫描 ~/Downloads            │      │
│  │  2. [只读] 按类型分类                   │      │
│  │  3. [写入] 创建 sorted/ 子目录          │      │
│  │  4. [写入] 移动 47 个文件               │      │
│  │                                        │      │
│  │        [取消]         [执行]           │      │
│  └────────────────────────────────────────┘      │
│                                                  │
├──────────────────────────────────────────────────┤
│  氵  ❯                    账本  垃圾桶      14:32 │
└──────────────────────────────────────────────────┘
```

---

## 构建

### 依赖（Ubuntu 24.04）

```bash
sudo apt-get install -y \
  build-essential cmake ninja-build pkg-config \
  qt6-base-dev qt6-declarative-dev qt6-wayland-dev \
  qt6-wayland-private-dev qml6-module-qtwayland-compositor \
  libgl1-mesa-dev libwayland-dev libxkbcommon-dev
```

### 编译

```bash
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
```

### 测试

```bash
ctest --test-dir build --output-on-failure
```

### 打包

```bash
cd build && cpack -G DEB
sudo dpkg -i shuios-0.1.0-Linux.deb
```

### 配置大脑

**API Key 绝对不要写进代码。**

```bash
export SHUIOS_DEEPSEEK_KEY=sk-xxxxxxxx
shuios
```

或者写进 `~/.config/shuios/config.json`：

```json
{ "deepseek_api_key": "sk-xxxxxxxx" }
```

> 已登录桌面后，在登录管理器的会话列表里选「氵系统」即可进入 shuios 会话。

---

## 用 GitHub 编译（推荐）

不需要本地装 Qt，Actions 免费给你一台 x86_64 编译机。

```bash
git init
git add .
git commit -m "氵系统 v0.1"
git remote add origin https://github.com/<你的用户名>/shuios.git
git push -u origin main
```

push 之后，`Actions` 标签页会自动开始编译，几分钟后：
- 编译成功 → `Artifacts` 里下载 `shuios-deb`
- 编译失败 → 日志直接看，把错误贴回来即可

也可以手动触发：Actions → 构建 shuios → Run workflow。

**免费额度**：公开仓库无限；私有仓库 2000 分钟/月。

---

## 目录结构

```
shuios/
├── src/
│   ├── main.cpp              装配所有子系统
│   ├── compositor/           【身体】Wayland 合成器
│   ├── brain/                【大脑接口】唯一出网通路
│   ├── capability/           【权限内核】凭据 + 审计账本
│   ├── intent/               【意图层】人话 → 计划
│   └── actions/              【执行层】默认走垃圾桶
├── qml/
│   ├── main.qml              主界面
│   ├── ConversationView.qml  对话区
│   ├── PlanConfirmDialog.qml ⚠ 核心交互：计划确认
│   └── Taskbar.qml           底部任务栏
├── tests/                    边界安全与意图解析测试
└── .github/workflows/        GitHub Actions
```

---

## 许可证

**GPLv3**

原因：Qt Wayland Compositor 模块是 GPLv3 或商业授权的双许可，没有 LGPL 选项。
选择 GPLv3 意味着本项目及其衍生作品必须保持开源。

若将来需要闭源分发，两条路：
1. 购买 Qt 商业授权
2. 把合成器层改用 **wlroots**（MIT 许可）重写

---

## v0.1 范围

**目标：证明这个身体能活。**

- [x] 全屏、单窗口、黑白简约
- [x] 对话（DeepSeek 流式）
- [x] 权限内核：能识别删除意图 → 弹确认 → 人类点头才执行
- [x] 审计账本
- [x] 底部任务栏 + 垃圾桶 + 能力凭据查看

**不做**（留给后续）：多窗口管理、程序启动器、中文输入法、
本地模型、设置面板、主题切换。

---

## 已知边界（诚实说明）

- **v0.1 的合成器主体由 QML 承载**，C++ 侧只留钩子。
  窗口策略与出网管控最终会落到 C++（`WindowManager` / `ShimCompositor`）。
- **中文输入法未接入**。Compositor 里做输入法是硬骨头，
  v0.1 的输入框只保证 ASCII 可用。
- **本地无法验证编译结果**——本项目在移动端沙箱中编写，
  首次编译几乎必然有错，需要在 GitHub Actions 或你的机器上跑一遍。
  **这是预期内的，不是意外。** 把报错贴回来即可。
- **意图层是规则引擎，不是模型**。确定性、零依赖、启动即用，
  代价是覆盖面窄。下一版可在这一层挂端侧小模型做兜底，
  但产出仍必须是 plan，而不是直接动作。

---

*氵 —— 无形、渗透、承载。系统是容器，AI 是内容。*