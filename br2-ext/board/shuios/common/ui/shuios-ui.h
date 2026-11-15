/*
 * shuios 设计令牌 v4 —— 自研界面的唯一色源。
 *
 * 规范与取值表见 docs/06-视觉规范.md 与 docs/07-界面规划.md
 * （Windows 形态：深色底 + 底部任务栏）。规则：
 *   1. 深色底 + 扁平色块，不做玻璃/半透明；任务栏和菜单用 BG_PANEL。
 *   2. ACCENT 克制使用：焦点框 / 主按钮 / 品牌「氵」/ 运行指示短线。
 *   3. 同一语义只有一个色值——不要在各处再写一遍 hex / rgba。
 *
 * shui-panel、shui-settings、shui-files、shui-store 都通过 -I 指向本目录
 * （见各自 .mk），这样"改一处，所有界面一起变"。foot/sway 是外部程序
 * 读静态配置，无法 include，只能照这份表抄——改动时以本文档为准。
 */

#ifndef SHUIOS_UI_H
#define SHUIOS_UI_H

/* ---------------------------------------------------------------- 颜色
 * 两个形态：UI_RGB_* 给 cairo（0..1 分量），UI_HEX_* 给拼 GTK CSS 字符串。
 * 分量 = hex/255，保留四位小数。
 */

/* 窗口 / 桌面 / 终端底 #0A0C0F */
#define UI_RGB_BG_WINDOW 0.0392, 0.0471, 0.0588
#define UI_HEX_BG_WINDOW "#0A0C0F"

/* 面板底：任务栏、开始菜单、标题栏 #12151A */
#define UI_RGB_BG_PANEL 0.0706, 0.0824, 0.1020
#define UI_HEX_BG_PANEL "#12151A"

/* 卡片底：卡片、输入框、图标底板 #181C22 */
#define UI_RGB_BG_CARD 0.0941, 0.1098, 0.1333
#define UI_HEX_BG_CARD "#181C22"

/* 悬停底 #21262D */
#define UI_RGB_BG_HOVER 0.1294, 0.1490, 0.1765
#define UI_HEX_BG_HOVER "#21262D"

/* 描边：所有 1px 边框 / 分隔线 #292E36 */
#define UI_RGB_LINE 0.1608, 0.1804, 0.2118
#define UI_HEX_LINE "#292E36"

/* 主文字 #EEF1F4（高对比） */
#define UI_RGB_FG 0.9333, 0.9451, 0.9569
#define UI_HEX_FG "#EEF1F4"

/* 次文字：摘要、次要标签 #9AA4AE */
#define UI_RGB_FG_DIM 0.6039, 0.6431, 0.6824
#define UI_HEX_FG_DIM "#9AA4AE"

/* 弱文字：元信息、禁用 #6B747D */
#define UI_RGB_FG_WEAK 0.4196, 0.4549, 0.4902
#define UI_HEX_FG_WEAK "#6B747D"

/* 强调：唯一主色，仅用于焦点/主操作/运行指示/当前任务项 #35A7CB */
#define UI_RGB_ACCENT 0.2078, 0.6549, 0.7961
#define UI_HEX_ACCENT "#35A7CB"

/* 强调悬停：只亮一档 #4FBEDA */
#define UI_RGB_ACCENT_HI 0.3098, 0.7451, 0.8549
#define UI_HEX_ACCENT_HI "#4FBEDA"

/* 强调底上的文字 #08161C */
#define UI_RGB_ACCENT_ON 0.0314, 0.0863, 0.1098
#define UI_HEX_ACCENT_ON "#08161C"

/* 错误：仅错误状态 #E0574F */
#define UI_RGB_DANGER 0.8784, 0.3412, 0.3098
#define UI_HEX_DANGER "#E0574F"

/* ---------------------------------------------------------------- 圆角 */
#define UI_RADIUS_SM 6   /* 小控件 / 胶囊 */
#define UI_RADIUS 8      /* 按钮 / 输入框 */
#define UI_RADIUS_CARD 12 /* 卡片 / 菜单 */

/* ---------------------------------------------------------------- 字号 */
#define UI_FS_META 11  /* 元信息 */
#define UI_FS_LABEL 12 /* 次要 / 标签 */
#define UI_FS_BODY 13  /* 正文 */
#define UI_FS_TITLE 15 /* 标题（仅此一处加粗） */

/* ---------------------------------------------------------------- 间距 */
#define UI_SP_1 4
#define UI_SP_2 8
#define UI_SP_3 12
#define UI_SP_4 16
#define UI_SP_6 24

/* ------------------------------------------------------- 数值 → 字符串
 * 拼 GTK CSS 字符串时用：UI_STR(UI_FS_BODY) 展开成 "13"。
 * 这样字号/圆角也只有一处来源，不必在 CSS 里再写一遍数字。
 */
#define UI_STRINGIFY_(x) #x
#define UI_STR(x) UI_STRINGIFY_(x)

#endif /* SHUIOS_UI_H */
