# shuios 界面改造方案：极简高对比 + 真图标

## Context（为什么做这个）

用户对当前桌面观感不满意（「UI 设计的好难看」），目标是把整体观感拉到接近 Windows/macOS 的水准，风格定为**极简高对比**。

调研后确认，"难看"不是审美问题，而是四个可修的工程缺口：

1. **没有图标主题**。`shuios_x86_64_defconfig` 里没有任何图标主题包，于是所有图标都是"包名首字母/首字符画个方块"（`终/浏/文/软`、`H/L`、`F`），这是最直观的廉价感来源。`shui-store.desktop` 已经写了 `Icon=system-software-install`，但没有主题能解析它。
2. **色源分散且互相冲突**。同一语义有 4 种白、3 种底色：

   * `waybar-style.css`：`#e6eaf0` / `#161a20`

   * `shui-panel.c`：`#d8e0e8` / `#14181e`

   * `shui-store.c`：`#e6eef4` / `#0e1620`

   * `foot.ini` / `sway-config` 又各写各的
     `docs/06` 自称"所有颜色只有一个来源"，但根本没落到代码。
3. **高饱和主色滥用 + 到处渐变**。`#2daed9` 同时是搜索框边框、安装按钮、图标底、任务栏高亮；开始按钮、tile、商店图标都用了渐变——没有层级，最扎眼的元素是「安装」按钮。
4. **文案是真 bug**。`load_apps()` 加了固定的「软件商店」，又扫到 `.desktop` 的 `Name=氵 软件商店`（名字不同→去重失效）→ 菜单里重复两项；`make_tile()` 的 `max_width_chars(8)` 把 `Foot Server` 截成 `Foot Se…`。

另外发现一处需在实现时先澄清的问题：**任务栏有两套实现并存**（`waybar`，以及保留 fallback 角色的 `shui-panel`），截图里看到的渲染更像 `shui-panel` 面板模式。必须确认实际在画任务栏的是谁，避免两个叠加。

预期结果：界面干净、一致、不刺眼，且颜色只有一个来源，后续换肤只改一处。

### 现实边界（先说明，避免期望错位）

在 Buildroot + TCG 软件渲染 + 无 GPU 的底座上，**做不到** Windows/macOS 的亚克力模糊、大阴影、60fps 动效。本方案的目标是「干净、一致、不碍眼」，且极简高对比恰好是软渲染下最稳的风格——这部分是能真正达到的。

***

## 设计令牌 v2（唯一色源）

用户已确认：**近中性单色，只在焦点/主操作处留一点青**。

| 角色   | token       | 值         | 用途                                |
| ---- | ----------- | --------- | --------------------------------- |
| 窗口底  | `BG_WINDOW` | `#0A0C0F` | 窗口/桌面/终端底                         |
| 面板底  | `BG_PANEL`  | `#12151A` | 任务栏、开始菜单、标题栏                      |
| 卡片底  | `BG_CARD`   | `#181C22` | 卡片、输入框、tile                       |
| 悬停底  | `BG_HOVER`  | `#21262D` | hover 态                           |
| 描边   | `LINE`      | `#292E36` | 所有 1px 边框/分隔线                     |
| 主文字  | `FG`        | `#EEF1F4` | 高对比正文/标题                          |
| 次文字  | `FG_DIM`    | `#9AA4AE` | 摘要、次要标签                           |
| 弱文字  | `FG_WEAK`   | `#6B747D` | 元信息、禁用                            |
| 强调   | `ACCENT`    | `#35A7CB` | **只用于** 焦点框 / 主按钮 / 运行指示线 / 当前任务项 |
| 强调悬停 | `ACCENT_HI` | `#4FBEDA` | 主按钮 hover（只亮一档）                   |
| 强调文字 | `ACCENT_ON` | `#08161C` | accent 实心底上的文字                    |
| 错误   | `DANGER`    | `#E0574F` | 仅错误状态                             |

圆角：`6`（小控件/胶囊）、`8`（按钮/输入框）、`12`（卡片/菜单）
字号：`11`（元信息）、`12`（次要/标签）、`13`（正文）、`15`（标题，仅此一处加粗）
间距：`4 / 8 / 12 / 16 / 24`

**硬规则**

1. **禁止渐变**——现在所有渐变（开始按钮、tile 底板、商店图标、「安装」按钮）全部移除，改纯色。
2. **accent 只出现在 4 个地方**（焦点框、主按钮、运行指示线、当前任务项底），其余一律中性灰。当前任务项底用低 alpha（≤12%）。
3. **描边永远 1px 中性**，只有焦点框可上 accent。
4. **同一语义只有一个色值**——消灭 4 种白。
5. **不用阴影**（软渲染下只会变脏）。

***

## 实施阶段

### P0 · 前置校验（在 WSL 里做，先跑结论）

* 确认 WSL 发行版 `shui-build` 可用、Buildroot 树在 `~/shuios/buildroot`（本机 D 盘无此树）。

* `grep -rni "hicolor\|adwaita" package/Config.in` 确认 Buildroot 2025.02.9 **是否存在** `BR2_PACKAGE_HICOLOR_ICON_THEME` 与 adwaita 图标主题符号。若不存在 → 退回 P2 的"中性扁平自制图标"路线，其余阶段不变。

* 确认实际在画任务栏的进程：`pgrep -a waybar; pgrep -a shui-panel`。据此决定 P4 是否停用其一。

### P1 · 建立唯一色源

* 新增 `br2-ext/board/shuios/common/ui/shuios-ui.h`：上表的 C 宏版本（颜色/圆角/字号/间距）。

* `br2-ext/package/shui-panel/shui-panel.mk` 与 `shui-store/shui-store.mk` 各加
  `CFLAGS += -I$(BR2_EXTERNAL_SHUIIOS_PATH)/board/shuios/common/ui`，让两个 C 应用共用同一头文件（现在它们各写各的）。

* 重写 `docs/06-视觉规范.md` 为「设计令牌 v2」，并**消解与** **`docs/07-界面规划.md`** **的冲突**：07 说任务栏底部 44px `#14181e`，06 还在写顶部 32px `#0d1620`——统一为本文档的底部 40px（对齐 `waybar-config` 的 `height: 40`）+ `BG_PANEL`。

### P2 · shui-panel（任务栏 / 开始菜单）

文件：`br2-ext/package/shui-panel/src/shui-panel.c`

* 删除 L26-36 的散落常量与 L810-837 CSS 块里的所有硬编码色，全改 token。

* 去渐变：`on_draw_start()`（L107-123）的线性渐变 → `ACCENT` 纯色；`on_draw_tile_icon()`（L533-555）的渐变 → `BG_CARD` 纯色 + `1px LINE` 描边。

* 图标：新增一个"优先取图标主题"的分支——能用 `gtk_image_new_from_icon_name()` 取到图标就显示真图标；取不到再退回「中性圆角块 + `FG` 首字符」。开始按钮保留品牌 ⊙，但 ⊙ 改为 `ACCENT_ON`（现在是大片白 ⊙，过亮）。

* 修文案 bug：

  * `load_apps()`（L518-530）：去重改为按**规范化名字**（剥掉 `氵 `  前缀与空格）比较，解决「软件商店」重复。

  * `make_tile()`（L565-589）：`max_width_chars(8)` → 12，标签允许两行，长名保留 tooltip。

  * `APPS[]`（L45-49）里第一项 label 是 `术`（与「终端」不一致，疑似笔误）→ 改为一致。

  * `first_glyph()`（L430-441）：跳过品牌前缀/空白后再取首字符（现在 `Foot Server`→`F` 这种可以接受，但 `氵 软件商店`→`氵` 会脏）。

### P3 · shui-store（软件商店）

文件：`br2-ext/package/shui-store/src/shui-store.c`

* CSS（L410-439）token 化；删掉 `headerbar` 的 `inset 0 -2px 0 0 #1d5a7a` 主色下划线，改 1px `LINE` 分隔线。

* 卡片重排 `make_tile()`（L293-354）：**`summary`** **去掉** **`vexpand=TRUE`**（L335 是中间大空白的根因），卡片高度收紧；层级改为 图标 → 名称 → 摘要（≤2 行）→ `meta` → 按钮，间距用 `8/12`。

* 图标：有图标主题则用真图标；否则中性 `BG_CARD` 块 + `FG_DIM` 字符。**删掉** **`pkg_color()`** **的 6 色彩虹**（L58-72）与竖渐变（L94-99）——这是极简路线下最大的"花"来源。

* 按钮：`button.install` → `ACCENT` 实心 + `ACCENT_ON` 文字，hover 只到 `ACCENT_HI`；`button.remove` 由灰底改为 1px 描边中性按钮（降低视觉重量）。

* 窗口：`gtk_window_set_default_size` 900×620（L455），并同步 `sway-config` 的 `for_window [app_id="shui-store"]` 尺寸，避免窄窗只排 2 列、右侧大片空。

* headerbar 副标题「装的是 app，不是系统」（L462）→ 中性文案（如「本地软件包」）。

### P4 · 面：waybar / foot / sway / 壁纸

* `files/waybar-style.css`：全 token 化；`#custom-start` 的 `linear-gradient(160deg …)`（L25）→ `ACCENT` 纯色、字号 16→14；`#taskbar button.active` 底 alpha `.18`→`.12`。补 `wlr/taskbar` 的图标间距。

* `files/foot.ini`：`[colors] background=0A0C0F / foreground=EEF1F4`；`[csd] border-color=292E36`、`button-color=9AA4AE`（L22-24）；光标色与 selection 用 accent。

* `files/sway-config`：`client.focused/focused_inactive/unfocused/urgent`（L29-33）token 化；`gaps inner 8 / outer 10` 统一为 `8 / 8`；`default_border pixel 2 / floating 3` 统一（1px 或 2px）；`font`（L22）字号 10→11。

* `tools/make-wallpaper.py`：改为近黑底 + 极淡单色水波，降低与界面的竞争。

### P5 · 验证

* 快环（\~20 秒/轮）：`bash /mnt/d/shuios/tools/dev-deploy.sh shui-panel`、`… shui-store`；配置类改动用 `tools/vm-restart-desktop.sh`。

* 截图 + 量化：`powershell -File tools\vm-shot.ps1 -Out D:\shuios\.cache\a.ppm`，再 `py -3 tools\ppm-inspect.py …` 出颜色直方图与 ASCII 预览。

* 正式验证：`wsl -d shui-build -u root -- bash /mnt/d/shuios/tools/wsl-rebuild-all.sh` 重打镜像后再截一次。

**量化验收**

* 底部任务栏区域：`BG_PANEL` 像素占比 > 85%，`ACCENT` 像素 < 5%。

* 开始菜单：tile 数 = 固定 4 项 + 去重后已装项（无重复「软件商店」），无被截断标签（或全部有 tooltip）。

* 商店卡片：卡片内空白（无内容像素）比例 < 25%。

* 全屏唯一色数（`ppm-inspect` 直方图）较改造前明显下降。

* 各 surface 同一语义色一致（`docs/06` 的白名单里无游离色值）。

### P6 · 可选守卫（防色源漂移）

* `tools/check-theme-tokens.sh`：grep 各 surface（两个 C 文件 + 3 个配置文件），出现不在 token 白名单里的 hex 就报错。把"唯一色源"从口号变成可校验的约束。

***

## 关键决策点（实现时第一步就要定）

1. **任务栏到底是谁**：waybar 还是 shui-panel（或两者叠加）。澄清后**只保留一个**，避免继续维护两套样式。
2. **图标主题是否在 Buildroot 里可用**。不可用则 P2/P3 退回"中性扁平自制图标"，其余不变。

