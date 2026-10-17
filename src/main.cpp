// ═══════════════════════════════════════════════════════════
//  氵系统 / shuios — 主入口
//
//  装配顺序很重要：
//    配置 → 日志 → 账本 → 垃圾桶 → 权限内核 → 动作引擎 → 大脑 → 身体
//  权限内核必须在动作引擎之前就绪，否则引擎没有关卡可守。
// ═══════════════════════════════════════════════════════════

#include "core/Config.h"
#include "core/Log.h"
#include "capability/CapabilityStore.h"
#include "capability/Ledger.h"
#include "actions/ActionRegistry.h"
#include "actions/Trash.h"
#include "brain/DeepSeekProvider.h"
#include "intent/IntentParser.h"
#include "compositor/ShimCompositor.h"
#include "compositor/WindowManager.h"

#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QStandardPaths>

using namespace shuios;

// 给 QML 用的门面对象：把权限、意图、大脑封装成简洁的接口
class ShuiosFacade : public QObject
{
    Q_OBJECT

public:
    explicit ShuiosFacade(QObject *parent = nullptr) : QObject(parent) {}

    void setBrain(BrainClient *b)  { m_brain = b; }
    void setCaps(CapabilityStore *s) { m_caps = s; }
    void setCompositor(ShimCompositor *c) { m_compositor = c; }
    void setWindowManager(WindowManager *w) { m_wm = w; }

    // ── 给 QML 调用的方法 ─────────────────────────────────

    Q_INVOKABLE bool brainReady() const
    {
        return m_brain && m_brain->isReady();
    }

    Q_INVOKABLE QString brainName() const
    {
        return m_brain ? m_brain->name() : QStringLiteral("(未配置)");
    }

    // 解析用户输入 → 返回 plan 的 JSON，QML 拿去渲染确认框
    Q_INVOKABLE QString planFor(const QString &input)
    {
        const Plan p = IntentParser::parse(input);
        return planToJson(p);
    }

    // 执行已确认的 plan
    Q_INVOKABLE QString executePlan(const QString &planJson, bool approved)
    {
        const Plan p = planFromJson(planJson);
        const QList<ActionResult> results = ActionRegistry::instance().execute(p, approved);
        return resultsToJson(results);
    }

    // 发送对话
    Q_INVOKABLE void sendMessage(const QString &text)
    {
        if (!m_brain) return;
        m_history << Message::user(text);
        m_brain->chatStream(m_history);
    }

    Q_INVOKABLE void clearHistory() { m_history.clear(); }

    Q_INVOKABLE QString ledgerTail(int n) const
    {
        return Ledger::instance().tail(n);
    }

    Q_INVOKABLE QString trashList() const
    {
        QVariantList out;
        for (const QVariantMap &m : Trash::instance().list()) {
            out << m;
        }
        return QString::fromUtf8(
            QJsonDocument(QJsonArray::fromVariantList(out)).toJson(QJsonDocument::Compact));
    }

    Q_INVOKABLE QString capabilityList() const
    {
        QVariantList out;
        if (m_caps) {
            for (const Capability &c : m_caps->list()) {
                out << QVariantMap{
                    { QStringLiteral("id"),        c.id },
                    { QStringLiteral("name"),      c.name },
                    { QStringLiteral("scope"),     c.scope },
                    { QStringLiteral("level"),     levelName(c.level) },
                    { QStringLiteral("status"),    c.status() },
                    { QStringLiteral("consumed"),  c.consumed },
                };
            }
        }
        return QString::fromUtf8(
            QJsonDocument(QJsonArray::fromVariantList(out)).toJson(QJsonDocument::Compact));
    }

    // 把 AI 回复加入历史（供流式结束后调用）
    Q_INVOKABLE void appendAssistant(const QString &text)
    {
        m_history << Message::assistant(text);
    }

signals:
    // 大脑信号转发给 QML
    void deltaReceived(const QString &delta);
    void responseCompleted(const QString &full);
    void responseFailed(const QString &error);

private:
    static QString planToJson(const Plan &p)
    {
        QJsonObject o;
        o.insert(QStringLiteral("intent"),     p.intent);
        o.insert(QStringLiteral("confidence"), p.confidence);
        o.insert(QStringLiteral("rawInput"),   p.rawInput);
        o.insert(QStringLiteral("valid"),      p.isValid());
        o.insert(QStringLiteral("maxLevel"),   levelName(p.maxLevel()));
        o.insert(QStringLiteral("needsHuman"), p.requiresHuman());

        QJsonArray warns;
        for (const QString &w : p.warnings) warns.append(w);
        o.insert(QStringLiteral("warnings"), warns);

        QJsonArray steps;
        for (const PlanStep &s : p.steps) {
            QJsonObject so;
            so.insert(QStringLiteral("op"),          s.op);
            so.insert(QStringLiteral("description"), s.description);
            so.insert(QStringLiteral("scope"),       s.scope);
            so.insert(QStringLiteral("requires"),    s.requires);
            so.insert(QStringLiteral("level"),       levelName(s.level));
            so.insert(QStringLiteral("args"),
                      QJsonObject::fromVariantMap(s.args));
            steps.append(so);
        }
        o.insert(QStringLiteral("steps"), steps);
        return QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact));
    }

    static Plan planFromJson(const QString &json)
    {
        Plan p;
        const QJsonObject o = QJsonDocument::fromJson(json.toUtf8()).object();
        p.intent     = o.value(QStringLiteral("intent")).toString();
        p.confidence = o.value(QStringLiteral("confidence")).toDouble();
        p.rawInput   = o.value(QStringLiteral("rawInput")).toString();

        const QJsonArray steps = o.value(QStringLiteral("steps")).toArray();
        for (const QJsonValue &v : steps) {
            const QJsonObject so = v.toObject();
            PlanStep s;
            s.op          = so.value(QStringLiteral("op")).toString();
            s.description = so.value(QStringLiteral("description")).toString();
            s.scope       = so.value(QStringLiteral("scope")).toString();
            s.requires    = so.value(QStringLiteral("requires")).toString();
            s.level       = levelFromName(so.value(QStringLiteral("level")).toString());
            s.args        = so.value(QStringLiteral("args")).toObject().toVariantMap();
            p.steps << s;
        }
        return p;
    }

    static QString resultsToJson(const QList<ActionResult> &results)
    {
        QJsonArray arr;
        for (const ActionResult &r : results) {
            QJsonObject o;
            o.insert(QStringLiteral("status"), r.status);
            o.insert(QStringLiteral("detail"), r.detail);
            o.insert(QStringLiteral("ok"),     r.ok);
            o.insert(QStringLiteral("data"),   QJsonObject::fromVariantMap(r.data));
            arr.append(o);
        }
        return QString::fromUtf8(QJsonDocument(arr).toJson(QJsonDocument::Compact));
    }

    BrainClient      *m_brain = nullptr;
    CapabilityStore  *m_caps = nullptr;
    ShimCompositor   *m_compositor = nullptr;
    WindowManager    *m_wm = nullptr;
    QList<Message>    m_history;
};

#include "main.moc"

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    app.setApplicationName(QStringLiteral("shuios"));
    app.setApplicationDisplayName(QStringLiteral("氵系统"));
    app.setOrganizationName(QStringLiteral("shuios"));

    // ── 1. 配置与日志 ─────────────────────────────────────
    Config::instance().initialize();
    Log::setLevel(LogLevel::Info);
    Log::info(QStringLiteral("氵系统 shuios v0.1.0 启动"));

    // ── 2. 账本（必须最先就绪，后续一切都要记账）───────────
    const QString stateDir = QStandardPaths::writableLocation(
                                 QStandardPaths::AppDataLocation) + QStringLiteral("/state");
    Ledger::instance().initialize(stateDir);

    // ── 3. 垃圾桶 ─────────────────────────────────────────
    Trash::instance().initialize(stateDir);

    // ── 4. 权限内核 ───────────────────────────────────────
    auto *caps = new CapabilityStore(&app);
    caps->initialize(stateDir);

    // ── 5. 动作引擎 ───────────────────────────────────────
    ActionRegistry::instance().setCapabilityStore(caps);

    // ── 6. 大脑 ───────────────────────────────────────────
    auto *brain = new DeepSeekProvider(&app);
    if (!brain->isReady()) {
        Log::warn(QStringLiteral("大脑未配置 —— 缺少 DeepSeek API Key"));
        Log::warn(QStringLiteral("  设置方式: export SHUIOS_DEEPSEEK_KEY=sk-xxxx"));
    }

    // ── 7. 身体 ───────────────────────────────────────────
    auto *compositor = new ShimCompositor(&app);
    auto *wm = new WindowManager(&app);
    compositor->start();

    // ── 8. QML 门面 ───────────────────────────────────────
    auto *facade = new ShuiosFacade(&app);
    facade->setBrain(brain);
    facade->setCaps(caps);
    facade->setCompositor(compositor);
    facade->setWindowManager(wm);

    QObject::connect(brain, &BrainClient::deltaReceived, facade, &ShuiosFacade::deltaReceived);
    QObject::connect(brain, &BrainClient::completed,     facade, &ShuiosFacade::responseCompleted);
    QObject::connect(brain, &BrainClient::failed,        facade, &ShuiosFacade::responseFailed);

    // 黑白简约风格
    QQuickStyle::setStyle(QStringLiteral("Basic"));

    // ── 9. 加载界面 ───────────────────────────────────────
    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("Shuios"), facade);

    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed,
                     &app, []() {
                         Log::error(QStringLiteral("界面加载失败"));
                         QCoreApplication::exit(-1);
                     }, Qt::QueuedConnection);

    engine.loadFromModule("Shuios", "Main");

    if (engine.rootObjects().isEmpty()) {
        Log::error(QStringLiteral("QML 根对象为空 —— 检查 qml/ 是否正确打包"));
        return -1;
    }

    Log::info(QStringLiteral("氵系统已就绪"));
    return app.exec();
}