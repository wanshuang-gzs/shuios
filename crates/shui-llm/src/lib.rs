//! OpenAI 兼容推理客户端。
//!
//! 本地 llama.cpp 走 `http://127.0.0.1:8080`；远程提供商走 HTTPS。
//! 远程请求交给镜像自带的 curl（链接 OpenSSL + CA 根证书），这样
//! Rust 侧不用引入 TLS 栈。API key 只写进 0600 的临时请求头文件，
//! **不会出现在命令行参数里**（`ps` 看不到）。

use std::fs;
use std::io::Read;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

const MAX_RESPONSE_BYTES: u64 = 8 * 1024 * 1024;

/// 一次 chat/completions 调用的结果。
#[derive(Debug, Clone)]
pub struct ChatReply {
    pub content: String,
    pub usage: Option<serde_json::Value>,
}

/// 推理端点是否只在本机回环地址。
///
/// 回环端点允许 `http://`（本地 llama.cpp）；其它地址必须 HTTPS，
/// 否则 Bearer token 会以明文经过网络。
pub fn is_loopback(endpoint: &str) -> bool {
    let Some(rest) = endpoint.trim().strip_prefix("http://") else {
        return false;
    };
    let authority = rest.split('/').next().unwrap_or("");
    let host = if let Some(h) = authority.strip_prefix('[') {
        h.split(']').next().unwrap_or("")
    } else {
        authority.rsplit_once(':').map(|(h, _)| h).unwrap_or(authority)
    };
    matches!(host, "127.0.0.1" | "localhost" | "::1")
}

/// 校验并规范化推理端点。
///
/// 远程（非回环）端点必须是 HTTPS；不接受 URL 里的用户名/密码、
/// 查询串或片段，避免把 key 发到意料之外的地址。
pub fn validate_endpoint(endpoint: &str) -> Result<String, String> {
    let s = endpoint.trim().trim_end_matches('/');
    if s.is_empty() {
        return Err("推理端点不能为空".to_string());
    }
    let (scheme, rest) = if let Some(r) = s.strip_prefix("https://") {
        ("https", r)
    } else if let Some(r) = s.strip_prefix("http://") {
        ("http", r)
    } else {
        return Err("推理端点必须以 http:// 或 https:// 开头".to_string());
    };
    if s.contains('?') || s.contains('#') {
        return Err("推理端点不能带查询串或片段（只需填到 /v1）".to_string());
    }
    let authority = rest.split('/').next().unwrap_or("");
    if authority.is_empty() {
        return Err("推理端点缺少主机名".to_string());
    }
    if authority.contains('@') {
        return Err("推理端点不要在 URL 里写用户名/密码".to_string());
    }
    if s.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err("推理端点包含空白或控制字符".to_string());
    }
    if scheme == "http" && !is_loopback(s) {
        return Err(
            "远程推理端点必须使用 https://（明文 http 会把 API 密钥暴露在网络上）"
                .to_string(),
        );
    }
    Ok(s.to_string())
}

/// 由基础地址拼出 `/chat/completions` 的完整 URL。
///
/// 兼容三种写法：
/// * `http://127.0.0.1:8080`            → `/v1/chat/completions`
/// * `https://api.deepseek.com/v1`     → `/v1/chat/completions`
/// * `https://host/v1/chat/completions` → 原样使用
pub fn chat_url(endpoint: &str) -> Result<String, String> {
    let base = validate_endpoint(endpoint)?;
    if base.ends_with("/chat/completions") {
        return Ok(base);
    }
    if base.ends_with("/v1") {
        return Ok(format!("{base}/chat/completions"));
    }
    Ok(format!("{base}/v1/chat/completions"))
}

/// 发起一次非流式 chat/completions 请求。
///
/// `api_key` 为空时只对回环端点有效（本地模型不需要密钥）。
pub fn chat(
    endpoint: &str,
    api_key: Option<&str>,
    model: &str,
    messages: &[serde_json::Value],
    temperature: f64,
    timeout: Duration,
    max_tokens: Option<u32>,
) -> Result<ChatReply, String> {
    let url = chat_url(endpoint)?;
    if model.trim().is_empty() {
        return Err("模型名不能为空".to_string());
    }
    if messages.is_empty() {
        return Err("messages 不能为空".to_string());
    }
    if !(0.0..=2.0).contains(&temperature) {
        return Err("temperature 必须在 0 到 2 之间".to_string());
    }
    let key = api_key.unwrap_or("").trim();
    if !key.is_empty() && key.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err("API 密钥包含空白或控制字符".to_string());
    }
    if key.is_empty() && !is_loopback(endpoint) {
        return Err("未配置 API 密钥：打开 设置 → AI，或运行 shui-ctl ai set --key-stdin".to_string());
    }

    let mut payload = serde_json::json!({
        "model": model.trim(),
        "messages": messages,
        "temperature": temperature,
        "stream": false,
    });
    if let Some(n) = max_tokens {
        payload["max_tokens"] = serde_json::json!(n);
    }
    let body = serde_json::to_vec(&payload).map_err(|e| format!("构造请求失败: {e}"))?;

    let secure = url.starts_with("https://");
    let tmp = TempDir::new()?;
    let headers = tmp.path.join("headers");
    let body_path = tmp.path.join("body.json");
    let resp_path = tmp.path.join("response.json");

    let mut hdr = String::from(
        "Content-Type: application/json\nAccept: application/json\nUser-Agent: shuios/0.1 shui\n",
    );
    if !key.is_empty() {
        hdr.push_str(&format!("Authorization: Bearer {key}\n"));
    }
    write_private(&headers, hdr.as_bytes())?;
    write_private(&body_path, &body)?;

    let max_secs = timeout.as_secs().max(5);
    let connect_secs = (max_secs / 4).clamp(5, 15);
    let proto = if secure { "=https" } else { "=http" };
    let mut cmd = Command::new("/usr/bin/curl");
    cmd.arg("--silent")
        .arg("--show-error")
        .arg("--globoff")
        .arg("--compressed")
        .arg("--proto")
        .arg(proto)
        .arg("--connect-timeout")
        .arg(connect_secs.to_string())
        .arg("--max-time")
        .arg(max_secs.to_string())
        .arg("--header")
        .arg(format!("@{}", headers.display()))
        .arg("--data-binary")
        .arg(format!("@{}", body_path.display()))
        .arg("--output")
        .arg(&resp_path)
        .arg("--write-out")
        .arg("%{http_code}")
        .arg(&url);

    let started = Instant::now();
    let out = cmd.output().map_err(|e| format!("无法启动 curl（镜像里缺 curl？）: {e}"))?;
    let elapsed = started.elapsed();

    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr).trim().to_string();
        return Err(curl_error(out.status.code().unwrap_or(-1), &err));
    }
    let status: u16 = String::from_utf8_lossy(&out.stdout)
        .trim()
        .parse()
        .unwrap_or(0);
    let body_text = read_limited(&resp_path)?;

    if !(200..300).contains(&status) {
        let snippet = truncate(&body_text, 500);
        return Err(format!(
            "推理服务返回 HTTP {status}：{}",
            if snippet.is_empty() { "(空响应)" } else { &snippet }
        ));
    }

    let v: serde_json::Value =
        serde_json::from_str(&body_text).map_err(|e| format!("响应不是合法 JSON: {e}"))?;
    let content = v
        .get("choices")
        .and_then(|c| c.get(0))
        .and_then(|c| c.get("message"))
        .and_then(|m| m.get("content"))
        .and_then(|c| c.as_str())
        .ok_or_else(|| {
            format!(
                "响应缺少 choices[0].message.content（耗时 {} ms）：{}",
                elapsed.as_millis(),
                truncate(&body_text, 500)
            )
        })?;
    Ok(ChatReply {
        content: content.to_string(),
        usage: v.get("usage").cloned(),
    })
}

fn curl_error(code: i32, stderr: &str) -> String {
    let hint = match code {
        6 => "无法解析主机名（检查网络/DNS）",
        7 => "连接失败（检查网络或推理服务是否启动）",
        28 => "请求超时",
        35 => "TLS 握手失败",
        60 => "TLS 证书校验失败（检查系统时间与 CA 证书）",
        77 => "读取 CA 证书失败",
        _ => "网络请求失败",
    };
    if stderr.is_empty() {
        format!("{hint}（curl 退出码 {code}）")
    } else {
        format!("{hint}（curl 退出码 {code}）：{stderr}")
    }
}

fn truncate(s: &str, max_chars: usize) -> String {
    let t = s.trim();
    let mut out: String = t.chars().take(max_chars).collect();
    if t.chars().count() > max_chars {
        out.push('…');
    }
    out
}

fn read_limited(path: &Path) -> Result<String, String> {
    let meta = fs::metadata(path).map_err(|e| format!("读取响应失败: {e}"))?;
    if meta.len() > MAX_RESPONSE_BYTES {
        return Err(format!("响应过大（{} 字节）", meta.len()));
    }
    let mut f = fs::File::open(path).map_err(|e| format!("读取响应失败: {e}"))?;
    let mut buf = Vec::with_capacity(meta.len() as usize);
    f.read_to_end(&mut buf).map_err(|e| format!("读取响应失败: {e}"))?;
    Ok(String::from_utf8_lossy(&buf).to_string())
}

fn write_private(path: &Path, data: &[u8]) -> Result<(), String> {
    let mut f = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .map_err(|e| format!("创建临时请求文件失败: {e}"))?;
    use std::io::Write;
    f.write_all(data).map_err(|e| format!("写临时请求文件失败: {e}"))?;
    f.flush().map_err(|e| format!("写临时请求文件失败: {e}"))
}

/// 请求结束即删除；即使提前返回也不会把密钥留在磁盘上。
struct TempDir {
    path: PathBuf,
}

impl TempDir {
    fn new() -> Result<Self, String> {
        let base = std::env::temp_dir();
        let mut last_err = None;
        for n in 0..32u32 {
            let nanos = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.subsec_nanos())
                .unwrap_or(0);
            let path = base.join(format!("shui-ai-{}-{nanos}-{n}", std::process::id()));
            match fs::DirBuilder::new().mode(0o700).create(&path) {
                Ok(()) => return Ok(Self { path }),
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                    last_err = Some(e);
                }
                Err(e) => return Err(format!("创建临时目录失败: {e}")),
            }
        }
        Err(format!(
            "创建临时目录失败: {}",
            last_err.map(|e| e.to_string()).unwrap_or_default()
        ))
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

/// 从模型输出里抽取第一个 `{...}` 形式的工具调用。
pub fn extract_tool_call(text: &str) -> Option<(String, serde_json::Value)> {
    let bytes = text.as_bytes();
    let start = text.find('{')?;
    let mut depth = 0i32;
    let mut end = None;
    for (idx, ch) in bytes.iter().enumerate().skip(start) {
        match ch {
            b'{' => depth += 1,
            b'}' => {
                depth -= 1;
                if depth == 0 {
                    end = Some(idx + 1);
                    break;
                }
            }
            _ => {}
        }
    }
    let end = end?;
    let candidate = &text[start..end];
    let v: serde_json::Value = serde_json::from_str(candidate).ok()?;
    let tool = v.get("tool").or_else(|| v.get("name"))?.as_str()?.to_string();
    // 只接受形似工具调用的对象，避免把普通 JSON 当命令执行。
    if !tool.contains('.') {
        return None;
    }
    let args = v
        .get("arguments")
        .or_else(|| v.get("args"))
        .cloned()
        .unwrap_or(serde_json::json!({}));
    Some((tool, args))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loopback_detection() {
        assert!(is_loopback("http://127.0.0.1:8080"));
        assert!(is_loopback("http://localhost"));
        assert!(is_loopback("http://[::1]:8080"));
        assert!(!is_loopback("http://192.168.1.2:8080"));
        assert!(!is_loopback("https://api.deepseek.com/v1"));
    }

    #[test]
    fn url_building_accepts_root_v1_and_full() {
        assert_eq!(
            chat_url("http://127.0.0.1:8080").unwrap(),
            "http://127.0.0.1:8080/v1/chat/completions"
        );
        assert_eq!(
            chat_url("https://api.deepseek.com/v1/").unwrap(),
            "https://api.deepseek.com/v1/chat/completions"
        );
        assert_eq!(
            chat_url("https://host/v1/chat/completions").unwrap(),
            "https://host/v1/chat/completions"
        );
    }

    #[test]
    fn endpoint_rejects_plain_http_remote() {
        let e = validate_endpoint("http://api.example.com/v1").unwrap_err();
        assert!(e.contains("https://"), "{e}");
    }

    #[test]
    fn endpoint_accepts_https_remote_and_local_http() {
        assert!(validate_endpoint("https://api.example.com/v1").is_ok());
        assert!(validate_endpoint("http://127.0.0.1:8080").is_ok());
        assert!(validate_endpoint("http://localhost:8080").is_ok());
    }

    #[test]
    fn endpoint_rejects_scheme_query_and_userinfo() {
        assert!(validate_endpoint("ftp://example.com").is_err());
        assert!(validate_endpoint("https://example.com/v1?x=1").is_err());
        assert!(validate_endpoint("https://user:pass@example.com/v1").is_err());
    }

    #[test]
    fn chat_without_key_rejects_remote_before_network() {
        let err = chat(
            "https://example.com/v1",
            None,
            "m",
            &[serde_json::json!({"role":"user","content":"hi"})],
            0.0,
            Duration::from_secs(5),
            Some(1),
        )
        .unwrap_err();
        assert!(err.contains("未配置 API 密钥"), "{err}");
    }

    #[test]
    fn tool_call_with_arguments() {
        let reply = r#"{"tool":"fs.list","arguments":{"path":"/tmp"}}"#;
        let (tool, args) = extract_tool_call(reply).unwrap();
        assert_eq!(tool, "fs.list");
        assert_eq!(args["path"], serde_json::json!("/tmp"));
    }

    #[test]
    fn tool_call_accepts_name_alias() {
        let reply = r#"{"name":"fs.read","args":{"path":"/etc/os-release"}}"#;
        let (tool, args) = extract_tool_call(reply).unwrap();
        assert_eq!(tool, "fs.read");
        assert_eq!(args["path"], serde_json::json!("/etc/os-release"));
    }

    #[test]
    fn tool_call_without_arguments_defaults_to_empty_object() {
        let reply = r#"{"tool":"sys.info"}"#;
        let (tool, args) = extract_tool_call(reply).unwrap();
        assert_eq!(tool, "sys.info");
        assert_eq!(args, serde_json::json!({}));
    }

    #[test]
    fn tool_call_inside_prose_is_found() {
        let reply = "我先看看目录。{\"tool\":\"fs.list\",\"arguments\":{}} 然后再总结。";
        let (tool, _) = extract_tool_call(reply).unwrap();
        assert_eq!(tool, "fs.list");
    }

    #[test]
    fn plain_json_is_not_a_tool_call() {
        assert!(extract_tool_call(r#"{"foo":1}"#).is_none());
        assert!(extract_tool_call("没有任何 JSON").is_none());
        assert!(extract_tool_call(r#"{"tool":"nodot"}"#).is_none());
    }

    #[test]
    fn nested_json_in_string_does_not_break_matching() {
        let reply = r#"{"tool":"fs.write","arguments":{"path":"/tmp/a","content":"{\"k\":1}"}}"#;
        let (tool, args) = extract_tool_call(reply).unwrap();
        assert_eq!(tool, "fs.write");
        assert_eq!(args["path"], serde_json::json!("/tmp/a"));
    }

    /// 起一个一次性 HTTP 服务，验证 curl 路径、Authorization 头和响应解析。
    fn mock_server(status: u16, body: &'static str) -> (String, std::thread::JoinHandle<String>) {
        use std::io::{Read, Write};
        use std::net::TcpListener;
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let handle = std::thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            let mut data = Vec::new();
            let mut tmp = [0u8; 4096];
            loop {
                let n = s.read(&mut tmp).unwrap();
                if n == 0 {
                    break;
                }
                data.extend_from_slice(&tmp[..n]);
                if let Some(pos) = data.windows(4).position(|w| w == b"\r\n\r\n") {
                    let head = String::from_utf8_lossy(&data[..pos]).to_string();
                    let len = head
                        .lines()
                        .find_map(|l| {
                            l.to_ascii_lowercase()
                                .strip_prefix("content-length:")
                                .map(|v| v.trim().parse::<usize>().unwrap_or(0))
                        })
                        .unwrap_or(0);
                    if data.len() >= pos + 4 + len {
                        break;
                    }
                }
            }
            let resp = format!(
                "HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            s.write_all(resp.as_bytes()).unwrap();
            String::from_utf8_lossy(&data).to_string()
        });
        (format!("http://{addr}"), handle)
    }

    #[test]
    fn chat_round_trip_through_curl() {
        let (endpoint, handle) = mock_server(
            200,
            r#"{"choices":[{"message":{"content":"OK"}}],"usage":{"total_tokens":3}}"#,
        );
        let reply = chat(
            &endpoint,
            Some("sk-test"),
            "m",
            &[serde_json::json!({"role":"user","content":"hi"})],
            0.0,
            Duration::from_secs(10),
            Some(8),
        )
        .unwrap();
        assert_eq!(reply.content, "OK");
        let req = handle.join().unwrap();
        assert!(req.contains("Authorization: Bearer sk-test"), "{req}");
        assert!(req.contains("\"model\":\"m\""), "{req}");
        assert!(req.contains("\"max_tokens\":8"), "{req}");
    }

    #[test]
    fn http_error_status_is_reported() {
        let (endpoint, handle) = mock_server(401, r#"{"error":{"message":"bad key"}}"#);
        let err = chat(
            &endpoint,
            Some("sk-test"),
            "m",
            &[serde_json::json!({"role":"user","content":"hi"})],
            0.0,
            Duration::from_secs(10),
            Some(8),
        )
        .unwrap_err();
        assert!(err.contains("HTTP 401"), "{err}");
        assert!(err.contains("bad key"), "{err}");
        let _ = handle.join();
    }
}
