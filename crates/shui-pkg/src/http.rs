//! 极简 HTTP/1.1 客户端（只支持 `GET`，明文 `http://`）。
//!
//! shuios 不在镜像里塞 TLS 库，所以**只支持 http://**；需要时由用户在前面
//! 架一层反向代理/内网镜像。实现得很小：写请求、读响应用于、拆头、按
//! `Content-Length` 或 `Transfer-Encoding: chunked` 取正文。
//!
//! 包体积不大（几百 KB 到几十 MB），因此整块读进内存再落盘，代码简单、
//! 出错路径清楚；真需要 TB 级分发时再换成流式。

use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::Path;
use std::time::Duration;

/// 单次请求的超时。
const TIMEOUT: Duration = Duration::from_secs(120);
/// 响应头上限，防止对端不断发头把我们撑爆。
const MAX_HEAD: usize = 64 * 1024;

/// 解析 `http://host[:port]/path`，返回 (host, port, path)。
pub fn parse_url(url: &str) -> Result<(String, u16, String), String> {
    let rest = url
        .strip_prefix("http://")
        .ok_or_else(|| format!("只支持 http:// 地址：{url}"))?;
    let (authority, path) = match rest.find('/') {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, "/"),
    };
    if authority.is_empty() {
        return Err(format!("地址缺少主机名：{url}"));
    }
    let (host, port) = match authority.rsplit_once(':') {
        Some((h, p)) if !p.is_empty() && p.chars().all(|c| c.is_ascii_digit()) => {
            let port = p.parse::<u16>().map_err(|_| format!("端口非法：{p}"))?;
            (h.to_string(), port)
        }
        _ => (authority.to_string(), 80),
    };
    Ok((host, port, path.to_string()))
}

/// 解析状态行 `HTTP/1.1 200 OK`，返回状态码。
pub fn parse_status(line: &str) -> Result<u16, String> {
    let mut parts = line.split_whitespace();
    let proto = parts.next().unwrap_or_default();
    if !proto.starts_with("HTTP/") {
        return Err(format!("不是 HTTP 响应：{line}"));
    }
    parts
        .next()
        .and_then(|c| c.parse::<u16>().ok())
        .ok_or_else(|| format!("状态行里没有状态码：{line}"))
}

fn find_header_end(buf: &[u8]) -> Option<usize> {
    buf.windows(4).position(|w| w == b"\r\n\r\n").map(|i| i + 4)
}

fn header_value<'a>(headers: &'a str, key: &str) -> Option<&'a str> {
    headers.lines().find_map(|line| {
        let (k, v) = line.split_once(':')?;
        if k.trim().eq_ignore_ascii_case(key) {
            Some(v.trim())
        } else {
            None
        }
    })
}

/// 一次性读取整个正文（适合 index.json 这种小文件）。
pub fn get(url: &str) -> Result<Vec<u8>, String> {
    let (host, port, path) = parse_url(url)?;
    let addr = format!("{host}:{port}");
    let mut stream = TcpStream::connect(&addr).map_err(|e| format!("连接 {addr} 失败：{e}"))?;
    stream.set_read_timeout(Some(TIMEOUT)).ok();
    stream.set_write_timeout(Some(TIMEOUT)).ok();

    let request = format!(
        "GET {path} HTTP/1.1\r\nHost: {host}\r\nUser-Agent: shui-pkg/0.1 (shuios)\r\n\
         Accept: */*\r\nConnection: close\r\n\r\n"
    );
    stream
        .write_all(request.as_bytes())
        .map_err(|e| format!("发送请求失败：{e}"))?;

    let mut raw = Vec::new();
    stream
        .read_to_end(&mut raw)
        .map_err(|e| format!("读取响应失败：{e}"))?;

    let end = find_header_end(&raw).ok_or("响应里没有完整的头部")?;
    if end > MAX_HEAD {
        return Err("响应头过大".to_string());
    }
    let head_text = String::from_utf8_lossy(&raw[..end]).to_string();
    let status = parse_status(head_text.lines().next().unwrap_or_default())?;
    if !(200..300).contains(&status) {
        return Err(format!("HTTP {status}：{url}"));
    }

    let body = &raw[end..];
    let chunked = header_value(&head_text, "transfer-encoding")
        .map(|v| v.eq_ignore_ascii_case("chunked"))
        .unwrap_or(false);
    if chunked {
        return dechunk(body);
    }
    if let Some(len) = header_value(&head_text, "content-length").and_then(|v| v.parse().ok()) {
        if body.len() < len {
            return Err(format!("正文不完整：期望 {len} 字节，实际 {}", body.len()));
        }
        return Ok(body[..len].to_vec());
    }
    Ok(body.to_vec())
}

/// 下载到文件，返回字节数。
pub fn download(url: &str, dest: &Path) -> Result<u64, String> {
    let data = get(url)?;
    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("创建 {} 失败：{e}", parent.display()))?;
    }
    std::fs::write(dest, &data).map_err(|e| format!("写入 {} 失败：{e}", dest.display()))?;
    Ok(data.len() as u64)
}

/// 解 `Transfer-Encoding: chunked` 正文。
pub fn dechunk(mut body: &[u8]) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    loop {
        let line_end = body
            .windows(2)
            .position(|w| w == b"\r\n")
            .ok_or("chunk 长度行不完整")?;
        let line = std::str::from_utf8(&body[..line_end]).map_err(|_| "chunk 长度不是 ASCII")?;
        let hex = line.split(';').next().unwrap_or("").trim();
        let size = usize::from_str_radix(hex, 16).map_err(|_| format!("chunk 长度非法：{hex}"))?;
        body = &body[line_end + 2..];
        if size == 0 {
            return Ok(out);
        }
        if body.len() < size {
            return Err("chunk 数据不完整".to_string());
        }
        out.extend_from_slice(&body[..size]);
        body = &body[size..];
        if body.starts_with(b"\r\n") {
            body = &body[2..];
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn 解析地址() {
        assert_eq!(
            parse_url("http://10.0.2.2:8099/repo/jq.sqfs").unwrap(),
            ("10.0.2.2".to_string(), 8099, "/repo/jq.sqfs".to_string())
        );
        assert_eq!(
            parse_url("http://example.com").unwrap(),
            ("example.com".to_string(), 80, "/".to_string())
        );
        assert!(parse_url("https://x/y").is_err());
        assert!(parse_url("http:///x").is_err());
    }

    #[test]
    fn 解析状态行() {
        assert_eq!(parse_status("HTTP/1.1 200 OK").unwrap(), 200);
        assert_eq!(parse_status("HTTP/1.1 404 Not Found").unwrap(), 404);
        assert!(parse_status("garbage").is_err());
    }

    #[test]
    fn 拆_chunked() {
        let body = b"4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n";
        assert_eq!(dechunk(body).unwrap(), b"Wikipedia");
    }

    #[test]
    fn 空_chunked() {
        assert_eq!(dechunk(b"0\r\n\r\n").unwrap(), Vec::<u8>::new());
    }

    #[test]
    fn 找头结束位置() {
        assert_eq!(find_header_end(b"HTTP/1.1 200 OK\r\n\r\nbody"), Some(19));
        assert_eq!(find_header_end(b"no header"), None);
    }
}
