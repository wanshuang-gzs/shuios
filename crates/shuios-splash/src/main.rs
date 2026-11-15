//! # shuios-splash — 氵系统 的开机 / 关机动画
//!
//! 为什么自己写：Buildroot 2025.02 里**没有 plymouth 包**。与其移植，
//! 不如直接写一个"把画面画进帧缓冲"的小程序——这正好符合 shuios 的思路：
//! 少依赖、可控、可解释。
//!
//! 实现要点：
//! * 几何从 sysfs 读（`/sys/class/graphics/fb0/{virtual_size,stride,bits_per_pixel}`），
//!   **不做 ioctl 结构体对齐**，避免 32/64 位布局差异带来的坑；
//! * mmap `/dev/fb0` 后直接写像素，支持 32bpp（QEMU bochs / 常见 DRM 都是）；
//! * 自带 5x7 点阵字体（只覆盖大写与数字），以及手绘的「氵」字形；
//! * 时长到了、或收到 SIGTERM 就退出，退出前把屏幕清成桌面底色，避免闪白。

use std::fs::OpenOptions;
use std::io::Write;
use std::os::unix::io::AsRawFd;
use std::time::{Duration, Instant};

// ---------------------------------------------------------------------------
// 配色（与桌面主题一致）
// ---------------------------------------------------------------------------
const BG_TOP: (u8, u8, u8) = (0x11, 0x14, 0x1a);
const BG_BOTTOM: (u8, u8, u8) = (0x1b, 0x20, 0x28);
const ACCENT: (u8, u8, u8) = (0x2d, 0xae, 0xd9);
const ACCENT_DIM: (u8, u8, u8) = (0x2d, 0x6a, 0x8a);
const TEXT: (u8, u8, u8) = (0xd8, 0xdc, 0xe0);
const TEXT_DIM: (u8, u8, u8) = (0x7a, 0x84, 0x8a);

/// 帧缓冲封装：几何 + 映射内存。
struct Fb {
    mem: *mut u8,
    len: usize,
    width: usize,
    height: usize,
    stride: usize,
    bpp: usize,
    red_shift: u32,
    green_shift: u32,
    blue_shift: u32,
}

fn read_sysfs(path: &str) -> Result<String, String> {
    std::fs::read_to_string(path)
        .map(|s| s.trim().to_string())
        .map_err(|e| format!("读取 {path} 失败: {e}"))
}

impl Fb {
    /// 打开 `/dev/fb0`，从 sysfs 读几何并 mmap。
    fn open() -> Result<Fb, String> {
        let vsize = read_sysfs("/sys/class/graphics/fb0/virtual_size")?;
        let (w, h) = vsize
            .split_once(',')
            .ok_or_else(|| format!("virtual_size 格式异常: {vsize}"))?;
        let width: usize = w.trim().parse().map_err(|e| format!("宽度解析失败: {e}"))?;
        let height: usize = h.trim().parse().map_err(|e| format!("高度解析失败: {e}"))?;
        let bpp: usize = read_sysfs("/sys/class/graphics/fb0/bits_per_pixel")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(32);
        if bpp != 32 && bpp != 16 {
            return Err(format!("不支持的 bpp: {bpp}（只处理 16/32）"));
        }
        let stride: usize = read_sysfs("/sys/class/graphics/fb0/stride")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(width * (bpp / 8));

        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .open("/dev/fb0")
            .map_err(|e| format!("打开 /dev/fb0 失败: {e}"))?;
        let len = stride * height;
        let mem = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                len,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_SHARED,
                file.as_raw_fd(),
                0,
            )
        };
        if mem == libc::MAP_FAILED {
            return Err(format!("mmap 失败: {}", std::io::Error::last_os_error()));
        }

        // 常见的 32bpp 布局：XRGB8888 / ARGB8888，均为 r16 g8 b0
        Ok(Fb {
            mem: mem as *mut u8,
            len,
            width,
            height,
            stride,
            bpp,
            red_shift: 16,
            green_shift: 8,
            blue_shift: 0,
        })
    }

    #[inline]
    fn pixel(&self, r: u8, g: u8, b: u8) -> u32 {
        if self.bpp == 16 {
            let r5 = (r as u32 >> 3) & 0x1f;
            let g6 = (g as u32 >> 2) & 0x3f;
            let b5 = (b as u32 >> 3) & 0x1f;
            (r5 << 11) | (g6 << 5) | b5
        } else {
            ((r as u32) << self.red_shift)
                | ((g as u32) << self.green_shift)
                | ((b as u32) << self.blue_shift)
        }
    }

    #[inline]
    fn put(&mut self, x: i32, y: i32, color: u32) {
        if x < 0 || y < 0 || x >= self.width as i32 || y >= self.height as i32 {
            return;
        }
        let off = y as usize * self.stride + x as usize * (self.bpp / 8);
        if off + 4 <= self.len {
            unsafe {
                if self.bpp == 16 {
                    std::ptr::write_unaligned(self.mem.add(off) as *mut u16, color as u16);
                } else {
                    std::ptr::write_unaligned(self.mem.add(off) as *mut u32, color);
                }
            }
        }
    }

    fn fill_rect(&mut self, x: i32, y: i32, w: i32, h: i32, rgb: (u8, u8, u8)) {
        let c = self.pixel(rgb.0, rgb.1, rgb.2);
        for yy in y..y + h {
            for xx in x..x + w {
                self.put(xx, yy, c);
            }
        }
    }

    fn fill_circle(&mut self, cx: i32, cy: i32, radius: i32, rgb: (u8, u8, u8)) {
        let c = self.pixel(rgb.0, rgb.1, rgb.2);
        let r2 = radius * radius;
        for yy in -radius..=radius {
            for xx in -radius..=radius {
                if xx * xx + yy * yy <= r2 {
                    self.put(cx + xx, cy + yy, c);
                }
            }
        }
    }

    /// 抗锯齿不做了，画粗线足够。
    fn line(&mut self, x0: i32, y0: i32, x1: i32, y1: i32, width: i32, rgb: (u8, u8, u8)) {
        let c = self.pixel(rgb.0, rgb.1, rgb.2);
        let dx = (x1 - x0).abs();
        let dy = (y1 - y0).abs();
        let sx = if x0 < x1 { 1 } else { -1 };
        let sy = if y0 < y1 { 1 } else { -1 };
        let mut err = dx - dy;
        let (mut x, mut y) = (x0, y0);
        loop {
            for oy in -(width / 2)..=(width / 2) {
                for ox in -(width / 2)..=(width / 2) {
                    self.put(x + ox, y + oy, c);
                }
            }
            if x == x1 && y == y1 {
                break;
            }
            let e2 = 2 * err;
            if e2 > -dy {
                err -= dy;
                x += sx;
            }
            if e2 < dx {
                err += dx;
                y += sy;
            }
        }
    }

    /// 按行整块写竖直渐变：先把一行算好，再 memcpy 到每一行。
    fn paint_gradient(&mut self, top: (u8, u8, u8), bottom: (u8, u8, u8)) {
        let w = self.width;
        let h = self.height;
        let mut row: Vec<u32> = Vec::with_capacity(w);
        for y in 0..h {
            let k = y as f64 / h as f64;
            let r = (top.0 as f64 * (1.0 - k) + bottom.0 as f64 * k) as u8;
            let g = (top.1 as f64 * (1.0 - k) + bottom.1 as f64 * k) as u8;
            let b = (top.2 as f64 * (1.0 - k) + bottom.2 as f64 * k) as u8;
            let c = self.pixel(r, g, b);
            row.clear();
            row.resize(w, c);
            let off = y * self.stride;
            unsafe {
                if self.bpp == 16 {
                    std::ptr::copy_nonoverlapping(row.as_ptr() as *const u16, self.mem.add(off) as *mut u16, w);
                } else {
                    std::ptr::copy_nonoverlapping(row.as_ptr(), self.mem.add(off) as *mut u32, w);
                }
            }
        }
    }

    fn clear(&mut self, rgb: (u8, u8, u8)) {
        let w = self.width as i32;
        let h = self.height as i32;
        self.fill_rect(0, 0, w, h, rgb);
    }
}

impl Drop for Fb {
    fn drop(&mut self) {
        unsafe {
            libc::munmap(self.mem as *mut libc::c_void, self.len);
        }
    }
}

// ---------------------------------------------------------------------------
// 5x7 点阵字体（只需大写、数字与少量符号）
// ---------------------------------------------------------------------------
fn glyph(ch: char) -> Option<[u8; 7]> {
    let g = match ch.to_ascii_uppercase() {
        'A' => [0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001],
        'B' => [0b11110, 0b10001, 0b11110, 0b10001, 0b10001, 0b10001, 0b11110],
        'C' => [0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110],
        'D' => [0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110],
        'E' => [0b11111, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000, 0b11111],
        'F' => [0b11111, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000, 0b10000],
        'G' => [0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01111],
        'H' => [0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001],
        'I' => [0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110],
        'J' => [0b00111, 0b00010, 0b00010, 0b00010, 0b10010, 0b10010, 0b01100],
        'K' => [0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001],
        'L' => [0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111],
        'M' => [0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001],
        'N' => [0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001],
        'O' => [0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110],
        'P' => [0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000],
        'Q' => [0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101],
        'R' => [0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001],
        'S' => [0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110],
        'T' => [0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100],
        'U' => [0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110],
        'V' => [0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100],
        'W' => [0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b10101, 0b01010],
        'X' => [0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001],
        'Y' => [0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100],
        'Z' => [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111],
        '0' => [0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110],
        '1' => [0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110],
        '2' => [0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111],
        '3' => [0b11111, 0b00010, 0b00100, 0b00010, 0b00001, 0b10001, 0b01110],
        '4' => [0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010],
        '5' => [0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110],
        '6' => [0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110],
        '7' => [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000],
        '8' => [0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110],
        '9' => [0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100],
        '.' => [0, 0, 0, 0, 0, 0b01100, 0b01100],
        '-' => [0, 0, 0, 0b11111, 0, 0, 0],
        ':' => [0, 0b01100, 0b01100, 0, 0b01100, 0b01100, 0],
        '/' => [0b00001, 0b00010, 0b00010, 0b00100, 0b01000, 0b01000, 0b10000],
        ' ' => [0; 7],
        _ => return None,
    };
    Some(g)
}

fn draw_text(fb: &mut Fb, x: i32, y: i32, text: &str, scale: i32, rgb: (u8, u8, u8)) {
    let c = fb.pixel(rgb.0, rgb.1, rgb.2);
    let mut cx = x;
    for ch in text.chars() {
        if let Some(g) = glyph(ch) {
            for (row, bits) in g.iter().enumerate() {
                for col in 0..5 {
                    if (bits >> (4 - col)) & 1 == 1 {
                        for sy in 0..scale {
                            for sx in 0..scale {
                                fb.put(cx + col * scale + sx, y + row as i32 * scale + sy, c);
                            }
                        }
                    }
                }
            }
        }
        cx += 6 * scale;
    }
}

fn text_width(text: &str, scale: i32) -> i32 {
    text.chars().count() as i32 * 6 * scale
}

// ---------------------------------------------------------------------------
// 「氵」字形：两点一提，用基本图元手绘
// ---------------------------------------------------------------------------
fn draw_water_radical(fb: &mut Fb, cx: i32, cy: i32, size: i32, phase: f64) {
    // 整体轻微上下浮动，像水波
    let bob = (phase * 1.6).sin() * (size as f64 * 0.03);
    let y0 = cy + bob as i32;
    let r = (size as f64 * 0.10) as i32;

    // 上面一点
    fb.fill_circle(cx - size / 5, y0 - size / 3, r, ACCENT);
    // 中间一点（略小）
    fb.fill_circle(cx - size / 6, y0, (r as f64 * 0.85) as i32, ACCENT);
    // 下面一提：从右下往左上的粗笔画
    fb.line(
        cx + size / 5,
        y0 + size / 3 + r,
        cx - size / 5,
        y0 + size / 6,
        (r as f64 * 1.15) as i32,
        ACCENT,
    );
}

// ---------------------------------------------------------------------------
// 动画
// ---------------------------------------------------------------------------
struct Args {
    mode: String,
    duration: f64,
    log: bool,
}

fn parse_args() -> Args {
    let mut a = Args { mode: "boot".to_string(), duration: 8.0, log: true };
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--mode" | "-m" => {
                i += 1;
                if let Some(v) = args.get(i) {
                    a.mode = v.clone();
                }
            }
            "--duration" | "-t" => {
                i += 1;
                if let Some(v) = args.get(i) {
                    a.duration = v.parse().unwrap_or(8.0);
                }
            }
            "--quiet" => a.log = false,
            "--help" | "-h" => {
                println!("shuios-splash [--mode boot|shutdown] [--duration 秒] [--quiet]");
                std::process::exit(0);
            }
            other => {
                eprintln!("shuios-splash: 未知参数 {other}");
                std::process::exit(2);
            }
        }
        i += 1;
    }
    a
}

/// 让 fbcon（DRM 的 fbdev 兼容层）重新绑定到这个帧缓冲。
///
/// 写 `/dev/fb0` 能不能出现在屏幕上，取决于内核里的 fbcon 是否"可见"：
/// * 合成器（weston/sway）持有 DRM master 时，内核把 fbcon 标记为隐藏，
///   deferred IO 不再把影子缓冲刷到扫描输出——此时写 fb0 完全没有效果；
/// * sway 模式下 `shuios-session.sh` 还会显式解绑 vtcon（`bind=0`），
///   那种情况连刷新通道都没有，必须自己绑回来。
///
/// 所以这个函数是"sway 兜底"，而真正保证关机动画能看见的是
/// `shuios-desktop.service` 的 `ExecStopPost=`：等合成器退出、master 释放之后再画。
fn bind_fbcon(log: bool) {
    let Ok(entries) = std::fs::read_dir("/sys/class/vtconsole") else {
        return;
    };
    for e in entries.flatten() {
        let dir = e.path();
        let name = std::fs::read_to_string(dir.join("name")).unwrap_or_default();
        if !name.contains("drm") && !name.contains("fb") {
            continue;
        }
        let bind = dir.join("bind");
        let cur = std::fs::read_to_string(&bind).unwrap_or_default();
        if cur.trim() == "0" {
            match std::fs::write(&bind, "1") {
                Ok(()) => {
                    if log {
                        eprintln!("shuios-splash: 已重新绑定 {}（{}）", bind.display(), name.trim());
                    }
                    // 给内核一点时间把 fbcon 挂回扫描输出
                    std::thread::sleep(Duration::from_millis(150));
                }
                Err(err) => eprintln!("shuios-splash: 绑定 {} 失败：{err}", bind.display()),
            }
        }
    }
}

fn main() {
    let args = parse_args();
    bind_fbcon(args.log);

    let mut fb = match Fb::open() {
        Ok(fb) => {
            if args.log {
                eprintln!(
                    "shuios-splash: {}x{} @{}bpp，模式={} 时长={:.1}s",
                    fb.width, fb.height, fb.bpp, args.mode, args.duration
                );
                let _ = std::io::stdout().flush();
            }
            fb
        }
        Err(e) => {
            eprintln!("shuios-splash: 无法使用帧缓冲（{e}），跳过动画");
            std::process::exit(1);
        }
    };

    let start = Instant::now();
    let total = Duration::from_secs_f64(args.duration.max(0.5));
    let frame = Duration::from_millis(40); // ~25fps
    let shutdown = args.mode == "shutdown";

    let w = fb.width as i32;
    let h = fb.height as i32;

    // 竖屏也好、超宽屏也好，都按短边缩放
    let base = h.min(w);

    loop {
        let elapsed = start.elapsed();
        let t = elapsed.as_secs_f64();
        let progress = (t / total.as_secs_f64()).clamp(0.0, 1.0);

        // 1) 渐变背景
        //    注意：必须按行整块写。逐像素 put() 在 TCG 模拟下慢到一帧几秒，
        //    表现就是"只画出渐变、Logo 和文字永远看不到"。
        fb.paint_gradient(BG_TOP, BG_BOTTOM);

        // 2) 底部水波（两条正弦线，相位相反）
        let wave_base = h - base / 6;
        for x in 0..w {
            let k = x as f64 / w as f64 * std::f64::consts::TAU;
            let a = (k * 2.0 + t * 1.8).sin() * (base as f64 * 0.018);
            let b = (k * 3.0 - t * 1.2).sin() * (base as f64 * 0.012);
            let c1 = fb.pixel(ACCENT_DIM.0, ACCENT_DIM.1, ACCENT_DIM.2);
            fb.put(x, wave_base + a as i32, c1);
            let dim = (BG_BOTTOM.0 / 2, BG_BOTTOM.1 / 2, BG_BOTTOM.2 / 2 + 20);
            let c2 = fb.pixel(dim.0, dim.1, dim.2);
            fb.put(x, wave_base + 4 + b as i32, c2);
        }

        // 3) 中央「氵」+ 文字
        let logo_size = (base as f64 * 0.22) as i32;
        let cx = w / 2;
        let cy = h / 2 - logo_size / 3;
        draw_water_radical(&mut fb, cx, cy, logo_size, t);

        let title = "SHUIOS";
        let ts = (base as f64 * 0.010).max(2.0) as i32;
        draw_text(
            &mut fb,
            cx - text_width(title, ts) / 2,
            cy + logo_size / 2 + base / 20,
            title,
            ts,
            TEXT,
        );

        let sub = if shutdown { "SHUTTING DOWN" } else { "BOOTING" };
        let ss = (ts * 2 / 3).max(1);
        draw_text(
            &mut fb,
            cx - text_width(sub, ss) / 2,
            cy + logo_size / 2 + base / 20 + ts * 9,
            sub,
            ss,
            TEXT_DIM,
        );

        // 4) 进度条
        let bar_w = (w as f64 * 0.36) as i32;
        let bar_h = (base as f64 * 0.008).max(3.0) as i32;
        let bar_x = cx - bar_w / 2;
        let bar_y = cy + logo_size / 2 + base / 20 + ts * 18;
        fb.fill_rect(bar_x, bar_y, bar_w, bar_h, (0x24, 0x2a, 0x31));
        let filled = (bar_w as f64 * progress) as i32;
        fb.fill_rect(bar_x, bar_y, filled, bar_h, ACCENT);

        // 5) 呼吸点（提示系统还在动）
        let dots = ((t * 3.0) as usize) % 4;
        for i in 0..3 {
            let on = i < dots;
            let rgb = if on { ACCENT } else { (0x33, 0x3a, 0x42) };
            fb.fill_circle(
                bar_x + bar_w / 2 - base / 20 + i as i32 * (base / 14),
                bar_y + bar_h + base / 24,
                (base as f64 * 0.006).max(2.0) as i32,
                rgb,
            );
        }

        if elapsed >= total {
            break;
        }
        std::thread::sleep(frame);
    }

    // 开机模式在桌面起来后会被整屏覆盖，清掉这最后一帧更干净；
    // 关机模式则要留着这帧——关机过程中没有人再重绘，清屏等于黑屏一闪。
    if !shutdown {
        fb.clear(BG_BOTTOM);
    }
    if args.log {
        eprintln!("shuios-splash: 动画结束");
    }
}
