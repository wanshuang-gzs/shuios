#include "intent/IntentParser.h"
#include "core/Log.h"

#include <QDir>
#include <QFileInfo>

namespace shuios {

// ── Plan ──────────────────────────────────────────────────

Level Plan::maxLevel() const
{
    Level m = Level::Safe;
    for (const PlanStep &s : steps) {
        if (static_cast<int>(s.level) > static_cast<int>(m)) m = s.level;
    }
    return m;
}

bool Plan::requiresHuman() const
{
    return static_cast<int>(maxLevel()) >= static_cast<int>(Level::Danger);
}

// ── 路径正则 ──────────────────────────────────────────────
//
// 【教训 1】中文里目标常在动词【前】("把 X 整理")，
// 而英文语序是动词在前("organize X")。两种都要支持。
//
// 【教训 2】左边界断言 (?<![A-Za-z0-9_\-./]) 必不可少 ——
// 否则贪婪匹配会把 /var/log 啃成 /log。
// 注意: 该断言依赖 PCRE。QRegularExpression 基于 PCRE，支持；
// 但 std::regex(ECMAScript) 不支持，移植时需改成
// 「捕获组 + 手工左边界校验」（见 tests/verify_core.cpp）。
//
static const char *PATH_RX =
    R"((?<![A-Za-z0-9_\-./])(/[A-Za-z0-9_\-./]*[A-Za-z0-9_\-.]|[A-Za-z0-9_\-]+\.[A-Za-z0-9]{1,6}))";

// 构建"目标在前"的模式: <path><动词>   —— 中文口语最常用
// 例: "把 /data/reports 整理一下"
static QRegularExpression beforeRx(const QString &verbs)
{
    return QRegularExpression(
        QStringLiteral("(?:把|将)?\\s*%1(?=\\s{0,3}(?:%2)\\s*$|[，,。]?\\s*(?:%2))")
            .arg(QString::fromUtf8(PATH_RX), verbs));
}

// 构建"动词在前"的模式: <动词><path>   —— 书面语 / 英文
// 例: "看看 /var/log 里有什么"、"organize /tmp/demo"
//
// 注意 [^\s/]{0,4} ：允许动词和路径之间夹少量非空格字符，
// 但【不能】夹斜杠，否则 "看看 /var/log" 会从 / 处重新起算。
static QRegularExpression afterRx(const QString &verbs)
{
    return QRegularExpression(
        QStringLiteral("(?:%1)[^\\s/]{0,4}[\\s，,：:]*%2")
            .arg(verbs, QString::fromUtf8(PATH_RX)));
}

const QList<IntentParser::Pattern> &IntentParser::patterns()
{
    static const QList<Pattern> pats = {
        // ── 中文口语：目标在前（最常见）────────────────────
        { beforeRx(QStringLiteral("整理|归类|分类")),           QStringLiteral("fs.organize"),  0.88 },
        { beforeRx(QStringLiteral("清理|清空|删除|删掉|移除")), QStringLiteral("fs.cleanup"),   0.86 },
        { beforeRx(QStringLiteral("总结|摘要|归纳一下|归纳")),   QStringLiteral("text.summarize"),0.82 },

        // ── 中文书面 / 英文：动词在前 ────────────────────
        { afterRx(QStringLiteral("整理|归类|分类")),           QStringLiteral("fs.organize"),  0.86 },
        { afterRx(QStringLiteral("清理|清空|删除|删掉|移除")), QStringLiteral("fs.cleanup"),   0.84 },
        { afterRx(QStringLiteral("总结|摘要|归纳一下|归纳")),   QStringLiteral("text.summarize"),0.80 },
        { afterRx(QStringLiteral("列出|列一下|看看|看下|显示")), QStringLiteral("fs.list"),     0.80 },
        { afterRx(QStringLiteral("读取|打开|查看|看一下|读一下")), QStringLiteral("fs.read"),    0.78 },
        { QRegularExpression(QStringLiteral("^(?:ls|list)\\s+%1").arg(QString::fromUtf8(PATH_RX))),
          QStringLiteral("fs.list"),   0.90 },
        { QRegularExpression(QStringLiteral("^(?:cat|read)\\s+%1").arg(QString::fromUtf8(PATH_RX))),
          QStringLiteral("fs.read"),   0.90 },
        { afterRx(QStringLiteral("organize")),                 QStringLiteral("fs.organize"),  0.85 },
        { afterRx(QStringLiteral("clean\\s*up|remove|delete")),QStringLiteral("fs.cleanup"),   0.82 },
    };
    return pats;
}

// ── 步骤构造 ──────────────────────────────────────────────

static QList<PlanStep> stepsFor(const QString &intent, const QString &path)
{
    QList<PlanStep> s;

    auto add = [&](const QString &op, const QString &desc,
                   const QString &scope, const QString &req, Level lvl) {
        PlanStep st;
        st.op = op; st.description = desc; st.scope = scope;
        st.requires = req; st.level = lvl;
        st.args[QStringLiteral("path")] = scope;
        s << st;
    };

    if (intent == QLatin1String("fs.list")) {
        add(QStringLiteral("fs.list"), QStringLiteral("列目录 %1").arg(path),
            path, QStringLiteral("fs.read"), Level::Safe);
    } else if (intent == QLatin1String("fs.read")) {
        add(QStringLiteral("fs.read"), QStringLiteral("读取 %1").arg(path),
            path, QStringLiteral("fs.read"), Level::Safe);
    } else if (intent == QLatin1String("fs.cleanup")) {
        add(QStringLiteral("fs.list"), QStringLiteral("先扫描，确认将删除什么"),
            path, QStringLiteral("fs.read"), Level::Safe);
        add(QStringLiteral("fs.delete"), QStringLiteral("移入垃圾桶（可恢复）"),
            path, QStringLiteral("fs.delete"), Level::Danger);
    } else if (intent == QLatin1String("fs.organize")) {
        const QString sub = path + QStringLiteral("/sorted");
        add(QStringLiteral("fs.list"), QStringLiteral("盘点现状"),
            path, QStringLiteral("fs.read"), Level::Safe);
        add(QStringLiteral("file.classify"), QStringLiteral("按类型分组"),
            path, QStringLiteral("fs.read"), Level::Safe);
        add(QStringLiteral("fs.mkdir"), QStringLiteral("建立 sorted/ 目录"),
            sub, QStringLiteral("fs.write"), Level::Normal);
        add(QStringLiteral("fs.move"), QStringLiteral("移动文件到分类子目录"),
            path, QStringLiteral("fs.write"), Level::Normal);
    } else if (intent == QLatin1String("text.summarize")) {
        add(QStringLiteral("fs.read"), QStringLiteral("读取正文"),
            path, QStringLiteral("fs.read"), Level::Safe);
        add(QStringLiteral("text.extract"), QStringLiteral("抽取纯文本"),
            path, QStringLiteral("fs.read"), Level::Safe);
        add(QStringLiteral("mem.write"), QStringLiteral("生成摘要写入记忆"),
            QStringLiteral("/ai/memory"), QStringLiteral("mem.write"), Level::Normal);
    }
    return s;
}

// ── 主入口 ────────────────────────────────────────────────

Plan IntentParser::parse(const QString &input)
{
    Plan plan;
    plan.rawInput = input.trimmed();

    for (const Pattern &p : patterns()) {
        const QRegularExpressionMatch m = p.regex.match(plan.rawInput);
        if (!m.hasMatch()) continue;

        QString path = m.captured(m.lastCapturedIndex());
        if (path.isEmpty()) continue;

        // 相对路径挂到当前目录
        if (!path.startsWith(QLatin1Char('/'))) {
            path = QDir::current().absoluteFilePath(path);
        }
        path = QDir::cleanPath(path);

        plan.intent     = p.intent;
        plan.confidence = p.confidence;
        plan.steps      = stepsFor(p.intent, path);
        break;
    }

    if (plan.steps.isEmpty()) {
        plan.confidence = 0.0;
        plan.warnings << QStringLiteral(
            "未能识别为已知意图 —— shuios 拒绝猜测执行。\n"
            "可以试试：整理 <目录> / 清理 <目录> / 看看 <目录> / 查看 <文件>");
        return plan;
    }

    if (plan.confidence < 0.80) {
        plan.warnings << QStringLiteral("置信度 %1% 偏低，建议先确认")
                             .arg(static_cast<int>(plan.confidence * 100));
    }

    Log::debug(QStringLiteral("意图解析: %1 → %2 (%3%), 等级 %4")
                   .arg(input, plan.intent)
                   .arg(static_cast<int>(plan.confidence * 100))
                   .arg(levelName(plan.maxLevel())));
    return plan;
}

bool IntentParser::scopeLike(const QString &path)
{
    return path.startsWith(QLatin1Char('/')) && !path.contains(QStringLiteral(".."));
}

} // namespace shuios