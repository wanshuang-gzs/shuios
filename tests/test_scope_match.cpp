// ═══════════════════════════════════════════════════════════
//  权限边界测试 —— 最关键的一组
//
//  如果 scopeMatches 退化为 startsWith()，
//  授权 /home/user/docs 之后就能写 /home/user/docs_evil/，
//  这是真实的权限逃逸漏洞。必须守住。
// ═══════════════════════════════════════════════════════════

#include "capability/CapabilityStore.h"

#include <QCoreApplication>
#include <QDebug>

using namespace shuios;

static int g_fail = 0;

static void expect(bool actual, bool want, const QString &desc)
{
    const bool pass = (actual == want);
    if (!pass) ++g_fail;
    qInfo().noquote() << (pass ? "  ✓" : "  ✗") << desc
                      << QStringLiteral("(得到 %1, 期望 %2)")
                             .arg(actual ? "匹配" : "拒绝", want ? "匹配" : "拒绝");
}

int main(int argc, char *argv[])
{
    QCoreApplication app(argc, argv);

    qInfo().noquote() << "═══ 作用域匹配（边界安全）═══";

    // 精确匹配
    expect(CapabilityStore::scopeMatches("/home/user/docs", "/home/user/docs"),
           true, "完全相同");

    // 子路径放行
    expect(CapabilityStore::scopeMatches("/home/user/docs", "/home/user/docs/a.txt"),
           true, "子文件");
    expect(CapabilityStore::scopeMatches("/home/user/docs", "/home/user/docs/sub/b.txt"),
           true, "深层子路径");

    // 【核心】前缀陷阱：不是字符串前缀就算子路径
    expect(CapabilityStore::scopeMatches("/home/user/docs", "/home/user/docs_evil/x"),
           false, "前缀陷阱 docs_evil（必须拒绝）");
    expect(CapabilityStore::scopeMatches("/home/user/docs", "/home/user/docsX"),
           false, "前缀陷阱 docsX（必须拒绝）");

    // 完全不同
    expect(CapabilityStore::scopeMatches("/home/user/docs", "/etc/passwd"),
           false, "无关路径");

    // 通配
    expect(CapabilityStore::scopeMatches("*", "/anything/at/all"),
           true, "通配 *");

    // 尾部斜杠归一化
    expect(CapabilityStore::scopeMatches("/home/user/docs/", "/home/user/docs/a"),
           true, "尾部斜杠归一化");

    // 路径穿越
    expect(CapabilityStore::scopeMatches("/home/user/docs", "/home/user/docs/../secret"),
           false, ".. 路径穿越（cleanPath 后应被拒）");

    qInfo().noquote() << "";
    qInfo().noquote() << "═══ 能力登记表 ═══";

    const auto &reg = CapabilityStore::registry();
    expect(reg.contains("fs.write"), true, "fs.write 已登记");
    expect(reg.value("fs.write").level == Level::Normal, true, "fs.write 为 NORMAL");
    expect(reg.value("fs.delete").level == Level::Danger, true, "fs.delete 为 DANGER");
    expect(reg.value("kernel.modify").level == Level::Always, true, "kernel.modify 为 ALWAYS");

    qInfo().noquote() << "";
    if (g_fail == 0) {
        qInfo().noquote() << "全部通过 ✓";
        return 0;
    }
    qInfo().noquote() << QStringLiteral("%1 项失败 ✗").arg(g_fail);
    return 1;
}