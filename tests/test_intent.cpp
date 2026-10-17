// ═══════════════════════════════════════════════════════════
//  意图解析测试
//
//  重点验证中文语序（目标在动词前）与路径捕获的准确性。
//  「看看 /var/log」必须捕获 /var/log，而不是 /log。
// ═══════════════════════════════════════════════════════════

#include "intent/IntentParser.h"

#include <QCoreApplication>
#include <QDebug>

using namespace shuios;

static int g_fail = 0;

static void expectIntent(const QString &input, const QString &wantIntent,
                         const QString &wantScope)
{
    const Plan p = IntentParser::parse(input);

    bool pass = (p.intent == wantIntent);
    QString gotScope;
    if (!p.steps.isEmpty()) {
        gotScope = p.steps.first().scope;
    }
    if (pass && !wantScope.isEmpty()) {
        pass = (gotScope == wantScope);
    }

    if (!pass) ++g_fail;
    qInfo().noquote() << (pass ? "  ✓" : "  ✗") << input;
    if (!pass) {
        qInfo().noquote() << QStringLiteral("      意图 %1 (期望 %2), 作用域 %3 (期望 %4)")
                                 .arg(p.intent, wantIntent, gotScope, wantScope);
    } else {
        qInfo().noquote() << QStringLiteral("      → %1 @ %2  等级 %3")
                                 .arg(p.intent, gotScope, levelName(p.maxLevel()));
    }
}

int main(int argc, char *argv[])
{
    QCoreApplication app(argc, argv);

    qInfo().noquote() << "═══ 中文语序（目标在动词前）═══";
    expectIntent("帮我把 /data/reports 整理一下", "fs.organize", "/data/reports");
    expectIntent("清理 /tmp/cache",              "fs.cleanup",  "/tmp/cache");
    expectIntent("看看 /var/log 里有什么",        "fs.list",     "/var/log");
    expectIntent("查看 /etc/hostname",           "fs.read",     "/etc/hostname");
    expectIntent("总结 /docs/notes.txt",         "text.summarize", "/docs/notes.txt");

    qInfo().noquote() << "";
    qInfo().noquote() << "═══ 英文语序（动词在前）═══";
    expectIntent("ls /var/log",       "fs.list",     "/var/log");
    expectIntent("cat /etc/hosts",    "fs.read",     "/etc/hosts");
    expectIntent("organize /tmp/demo","fs.organize", "/tmp/demo");

    qInfo().noquote() << "";
    qInfo().noquote() << "═══ 应当拒绝（不猜测执行）═══";
    {
        const Plan p = IntentParser::parse("给我把服务器重启一下");
        const bool pass = !p.isValid();
        if (!pass) ++g_fail;
        qInfo().noquote() << (pass ? "  ✓" : "  ✗")
                          << "无法理解的指令被拒绝执行";
    }

    qInfo().noquote() << "";
    qInfo().noquote() << "═══ 危险等级判定 ═══";
    {
        const Plan cleanup = IntentParser::parse("清理 /tmp/cache");
        const bool pass = cleanup.requiresHuman();
        if (!pass) ++g_fail;
        qInfo().noquote() << (pass ? "  ✓" : "  ✗")
                          << "清理被标为需要人类确认";
    }
    {
        const Plan list = IntentParser::parse("看看 /var/log");
        const bool pass = !list.requiresHuman();
        if (!pass) ++g_fail;
        qInfo().noquote() << (pass ? "  ✓" : "  ✗")
                          << "只读操作无需人类确认";
    }

    qInfo().noquote() << "";
    if (g_fail == 0) {
        qInfo().noquote() << "全部通过 ✓";
        return 0;
    }
    qInfo().noquote() << QStringLiteral("%1 项失败 ✗").arg(g_fail);
    return 1;
}