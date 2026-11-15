//! 极简 HTML → 纯文本。
//!
//! 目的不是做「正确的 HTML 解析」，而是把抓到的网页变成**模型能读的一段文字**：
//! 去掉 script/style、把块级标签变成换行、解码常见实体、压缩空白。
//!
//! 不引 HTML 解析库的理由和项目其它地方一致：镜像要小，而且这里的需求
//! 只是"把正文捞出来"，正则/状态机够用。

/// 块级标签：遇到它们就换行，避免整页挤成一行。
const BLOCK_TAGS: [&str; 22] = [
    "p", "br", "div", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "table",
    "section", "article", "header", "footer", "nav", "pre", "blockquote", "hr",
];

/// 抓取结果的最大正文长度（字符数）。模型上下文有限，别把整页都塞进去。
pub const MAX_CHARS: usize = 20_000;

pub fn html_to_text(html: &str) -> String {
    let bytes = html.as_bytes();
    let mut out = String::with_capacity(html.len() / 2);
    let mut i = 0usize;
    let mut pending_space = false;

    while i < bytes.len() {
        let b = bytes[i];

        // 注释
        if b == b'<' && html[i..].starts_with("<!--") {
            match html[i..].find("-->") {
                Some(off) => {
                    i += off + 3;
                    continue;
                }
                None => break,
            }
        }

        // script / style：整段丢弃
        if b == b'<' {
            let rest = &html[i..];
            let lower = rest.to_ascii_lowercase();
            if lower.starts_with("<script") || lower.starts_with("<style") {
                let close = if lower.starts_with("<script") {
                    "</script>"
                } else {
                    "</style>"
                };
                match lower.find(close) {
                    Some(off) => {
                        i += off + close.len();
                        continue;
                    }
                    None => break,
                }
            }

            // 普通标签：找到 '>'，判断是不是块级
            if let Some(end) = rest.find('>') {
                let tag = rest[1..end].trim_start_matches('/').trim();
                let name: String = tag
                    .chars()
                    .take_while(|c| c.is_ascii_alphanumeric())
                    .collect::<String>()
                    .to_ascii_lowercase();
                if BLOCK_TAGS.contains(&name.as_str()) {
                    push_break(&mut out);
                } else {
                    pending_space = true;
                }
                i += end + 1;
                continue;
            }
            // 没有 '>' 的孤立 '<'：当成普通字符
        }

        // 实体
        if b == b'&' {
            if let Some(semi) = html[i..].find(';') {
                if semi <= 10 {
                    let ent = &html[i + 1..i + semi];
                    if let Some(ch) = decode_entity(ent) {
                        push_char(&mut out, ch, &mut pending_space);
                        i += semi + 1;
                        continue;
                    }
                }
            }
        }

        // 正文（按 UTF-8 字符推进）
        let ch = match html[i..].chars().next() {
            Some(c) => c,
            None => break,
        };
        push_char(&mut out, ch, &mut pending_space);
        i += ch.len_utf8();
    }

    // 收尾：压缩连续空行
    let mut text = String::with_capacity(out.len());
    let mut blank = 0;
    for line in out.lines() {
        let t = line.trim_end();
        if t.trim().is_empty() {
            blank += 1;
            if blank > 1 {
                continue;
            }
            text.push('\n');
        } else {
            blank = 0;
            text.push_str(t);
            text.push('\n');
        }
    }
    let text = text.trim().to_string();

    if text.chars().count() > MAX_CHARS {
        let truncated: String = text.chars().take(MAX_CHARS).collect();
        format!("{truncated}\n\n…（正文超过 {MAX_CHARS} 字符，已截断）")
    } else {
        text
    }
}

fn push_break(out: &mut String) {
    while out.ends_with(' ') {
        out.pop();
    }
    if !out.ends_with('\n') {
        out.push('\n');
    }
}

fn push_char(out: &mut String, ch: char, pending_space: &mut bool) {
    if ch.is_whitespace() {
        *pending_space = true;
        return;
    }
    if *pending_space {
        if !out.is_empty() && !out.ends_with('\n') && !out.ends_with(' ') {
            out.push(' ');
        }
        *pending_space = false;
    }
    out.push(ch);
}

fn decode_entity(ent: &str) -> Option<char> {
    let lower = ent.to_ascii_lowercase();
    let ch = match lower.as_str() {
        "amp" => '&',
        "lt" => '<',
        "gt" => '>',
        "quot" => '"',
        "apos" => '\'',
        "nbsp" => ' ',
        "mdash" => '—',
        "ndash" => '–',
        "hellip" => '…',
        "middot" => '·',
        "copy" => '©',
        "reg" => '®',
        "trade" => '™',
        _ => {
            // 数字实体：&#64; / &#x40;
            if let Some(num) = lower.strip_prefix('#') {
                let code = if let Some(hex) = num.strip_prefix('x') {
                    u32::from_str_radix(hex, 16).ok()
                } else {
                    num.parse::<u32>().ok()
                };
                return code.and_then(char::from_u32);
            }
            return None;
        }
    };
    Some(ch)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn 去掉标签只留正文() {
        let t = html_to_text("<html><body><h1>标题</h1><p>第一段</p><p>第二段</p></body></html>");
        assert!(t.contains("标题"));
        assert!(t.contains("第一段"));
        assert!(t.contains("第二段"));
        assert!(!t.contains('<'));
        // 块级标签之间要有换行
        assert!(t.lines().count() >= 3);
    }

    #[test]
    fn 丢掉脚本与样式() {
        let t = html_to_text(
            "<div>保留</div><script>var x = '<p>不该出现</p>';</script><style>.a{color:red}</style><span>也保留</span>",
        );
        assert!(t.contains("保留"));
        assert!(t.contains("也保留"));
        assert!(!t.contains("不该出现"));
        assert!(!t.contains("color"));
    }

    #[test]
    fn 解码实体() {
        let t = html_to_text("<p>a &amp; b &lt;c&gt; &quot;d&quot; &#65;</p>");
        assert!(t.contains("a & b <c> \"d\" A"), "实际：{t}");
    }

    #[test]
    fn 压缩空白与空行() {
        // 空段落（<p></p>）不产生额外空行：块级分隔最多收敛成一个换行
        let t = html_to_text("<p>a</p>\n\n\n<p></p><p></p><p>b</p>");
        assert_eq!(t, "a\nb");
        // 正常的两段之间只有一个换行——交给渲染端按需显示空行
        let t2 = html_to_text("<p>one</p><p>two</p>");
        assert_eq!(t2, "one\ntwo");
    }

    #[test]
    fn 去掉注释() {
        let t = html_to_text("<p>可见</p><!-- 隐藏 --><p>也可</p>");
        assert!(t.contains("可见"));
        assert!(!t.contains("隐藏"));
    }

    #[test]
    fn 超长截断() {
        let big = format!("<p>{}</p>", "字".repeat(MAX_CHARS + 500));
        let t = html_to_text(&big);
        assert!(t.contains("已截断"));
        assert!(t.chars().count() <= MAX_CHARS + 40);
    }

    #[test]
    fn 纯文本原样返回() {
        let t = html_to_text("just plain text");
        assert_eq!(t, "just plain text");
    }
}
