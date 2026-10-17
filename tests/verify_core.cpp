// 独立验证程序 —— 不含 Qt 依赖
//
// 【重要发现】std::regex 用 ECMAScript 语法，不支持 lookbehind (?<!...)。
// 所以这里改为「捕获组 + 后置校验」：
//   先用宽松正则在候选位置捕获，再手工检查左边界。
// 这与 Qt 版（QRegularExpression 基于 PCRE，支持 lookbehind）行为等价，
// 可以交叉验证两版算法是否一致。
//
// 编译: g++ -std=c++17 -o verify verify_core.cpp

#include <iostream>
#include <string>
#include <vector>
#include <regex>

static int g_fail = 0;

// ══ 作用域匹配 ══
static bool scopeMatches(const std::string &granted, const std::string &requested)
{
    if (granted == "*") return true;

    auto clean = [](std::string s) {
        std::vector<std::string> parts;
        std::string cur;
        for (char c : s) {
            if (c == '/') {
                if (cur == "..") { if (!parts.empty()) parts.pop_back(); }
                else if (cur != "." && !cur.empty()) parts.push_back(cur);
                cur.clear();
            } else cur += c;
        }
        if (cur == "..") { if (!parts.empty()) parts.pop_back(); }
        else if (cur != "." && !cur.empty()) parts.push_back(cur);
        std::string out;
        for (auto &p : parts) out += "/" + p;
        return out.empty() ? std::string("/") : out;
    };

    std::string g = clean(granted), r = clean(requested);
    if (r == g) return true;
    return r.rfind(g + "/", 0) == 0;
}

static void expect(bool got, bool want, const std::string &desc)
{
    bool pass = (got == want);
    if (!pass) ++g_fail;
    std::cout << (pass ? "  [OK] " : "  [FAIL] ") << desc
              << "  (得到=" << (got ? "匹配" : "拒绝")
              << " 期望=" << (want ? "匹配" : "拒绝") << ")\n";
}

// ══ 意图解析 ══
// 不带 lookbehind 的路径模式
static const std::string PATH_RX =
    R"((/[A-Za-z0-9_\-./]*[A-Za-z0-9_\-.]|[A-Za-z0-9_\-]+\.[A-Za-z0-9]{1,6}))";

// 左边界校验：路径起点前不能是字母/数字/下划线/点/斜杠
static bool leftBoundaryOk(const std::string &text, size_t pathStart)
{
    if (pathStart == 0) return true;
    char c = text[pathStart - 1];
    return !(std::isalnum(static_cast<unsigned char>(c)) || c == '_' || c == '.' || c == '/');
}

struct Pat { std::regex rx; std::string intent; };

static const std::vector<Pat> &patterns()
{
    auto before = [](const std::string &verbs) {
        return std::regex(std::string("(?:把|将)?\\s*") + PATH_RX
                          + "(?=\\s{0,3}(?:" + verbs + ")\\s*$|[，,。]?\\s*(?:" + verbs + "))");
    };
    auto after = [](const std::string &verbs) {
        return std::regex(std::string("(?:") + verbs + ")[^\\s/]{0,4}[\\s，,：:]*" + PATH_RX);
    };

    static const std::vector<Pat> pats = {
        { before("整理|归类|分类"),            "fs.organize" },
        { before("清理|清空|删除|删掉|移除"),  "fs.cleanup" },
        { before("总结|摘要|归纳一下|归纳"),    "text.summarize" },
        { after("整理|归类|分类"),             "fs.organize" },
        { after("清理|清空|删除|删掉|移除"),   "fs.cleanup" },
        { after("总结|摘要|归纳一下|归纳"),     "text.summarize" },
        { after("列出|列一下|看看|看下|显示"),  "fs.list" },
        { after("读取|打开|查看|看一下|读一下"), "fs.read" },
        { std::regex(std::string("^(?:ls|list)\\s+") + PATH_RX), "fs.list" },
        { std::regex(std::string("^(?:cat|read)\\s+") + PATH_RX), "fs.read" },
        { after("organize"),                   "fs.organize" },
        { after("clean\\s*up|remove|delete"),  "fs.cleanup" },
    };
    return pats;
}

static std::pair<std::string, std::string> parse(const std::string &text)
{
    for (const Pat &p : patterns()) {
        std::smatch m;
        if (!std::regex_search(text, m, p.rx)) continue;

        for (int i = (int)m.size() - 1; i >= 1; --i) {
            if (!m[i].matched) continue;
            size_t start = static_cast<size_t>(m.position(i));
            // 左边界校验 —— 替代 lookbehind
            if (!leftBoundaryOk(text, start)) continue;
            return { p.intent, m[i].str() };
        }
    }
    return { "unknown", "" };
}

int main()
{
    std::cout << "=== 作用域匹配 ===\n";
    expect(scopeMatches("/home/user/docs", "/home/user/docs"),        true,  "完全相同");
    expect(scopeMatches("/home/user/docs", "/home/user/docs/a.txt"),  true,  "子文件");
    expect(scopeMatches("/home/user/docs", "/home/user/docs/sub/b"),  true,  "深层子路径");
    expect(scopeMatches("/home/user/docs", "/home/user/docs_evil/x"), false, "前缀陷阱 docs_evil");
    expect(scopeMatches("/home/user/docs", "/home/user/docsX"),       false, "前缀陷阱 docsX");
    expect(scopeMatches("/home/user/docs", "/etc/passwd"),            false, "无关路径");
    expect(scopeMatches("*",               "/anything"),              true,  "通配");
    expect(scopeMatches("/home/user/docs/","/home/user/docs/a"),      true,  "尾斜杠归一化");
    expect(scopeMatches("/home/user/docs", "/home/user/docs/../secret"), false, "路径穿越");

    std::cout << "\n=== 意图解析 ===\n";

    struct C { const char *text; const char *intent; const char *path; };
    const std::vector<C> cases = {
        { "帮我把 /data/reports 整理一下", "fs.organize",    "/data/reports" },
        { "清理 /tmp/cache",              "fs.cleanup",     "/tmp/cache" },
        { "看看 /var/log 里有什么",        "fs.list",        "/var/log" },
        { "查看 /etc/hostname",           "fs.read",        "/etc/hostname" },
        { "总结 /docs/notes.txt",         "text.summarize","/docs/notes.txt" },
        { "ls /var/log",                  "fs.list",        "/var/log" },
        { "cat /etc/hosts",               "fs.read",        "/etc/hosts" },
        { "organize /tmp/demo",           "fs.organize",    "/tmp/demo" },
    };

    for (const C &c : cases) {
        auto res = parse(c.text);
        bool pass = (res.first == c.intent) && (res.second == c.path);
        if (!pass) ++g_fail;
        std::cout << (pass ? "  [OK] " : "  [FAIL] ") << c.text << "\n";
        if (pass) std::cout << "      -> " << res.first << " @ " << res.second << "\n";
        else std::cout << "      得到 (" << res.first << ", " << res.second << ")"
                       << "  期望 (" << c.intent << ", " << c.path << ")\n";
    }

    {
        auto res = parse("给我把服务器重启一下");
        bool pass = (res.first == "unknown");
        if (!pass) ++g_fail;
        std::cout << (pass ? "  [OK] " : "  [FAIL] ") << "无法理解的指令被拒绝执行\n";
    }

    std::cout << "\n";
    if (g_fail == 0) { std::cout << "全部通过\n"; return 0; }
    std::cout << g_fail << " 项失败\n";
    return 1;
}