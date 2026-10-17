#include "capability/CapabilityStore.h"
#include "capability/Ledger.h"
#include "core/Log.h"

#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QRandomGenerator>
#include <QSaveFile>
#include <QStandardPaths>

namespace shuios {

// ═══════════════════════════════════════════════════════════
//  分级工具
// ═══════════════════════════════════════════════════════════

QString levelName(Level l)
{
    switch (l) {
    case Level::Safe:   return QStringLiteral("SAFE");
    case Level::Normal: return QStringLiteral("NORMAL");
    case Level::Danger: return QStringLiteral("DANGER");
    case Level::Always: return QStringLiteral("ALWAYS");
    }
    return QStringLiteral("UNKNOWN");
}

Level levelFromName(const QString &name)
{
    const QString n = name.toUpper();
    if (n == QLatin1String("SAFE"))   return Level::Safe;
    if (n == QLatin1String("NORMAL")) return Level::Normal;
    if (n == QLatin1String("DANGER")) return Level::Danger;
    return Level::Always;
}

// ═══════════════════════════════════════════════════════════
//  Capability
// ═══════════════════════════════════════════════════════════

QString Capability::status() const
{
    if (revoked)                                    return QStringLiteral("REVOKED");
    if (QDateTime::currentSecsSinceEpoch() >= expiresAt) return QStringLiteral("EXPIRED");
    if (usesLeft == 0)                              return QStringLiteral("EXHAUSTED");
    return QStringLiteral("LIVE");
}

bool Capability::isLive() const
{
    return !revoked
        && QDateTime::currentSecsSinceEpoch() < expiresAt
        && (usesLeft < 0 || usesLeft > 0);
}

QString Capability::token() const
{
    return id + QLatin1Char('.') + secret;
}

// ═══════════════════════════════════════════════════════════
//  CheckResult
// ═══════════════════════════════════════════════════════════

CheckResult CheckResult::allow(const QString &id)
{
    CheckResult r;
    r.ok = true;
    r.reason = QStringLiteral("ok");
    r.capabilityId = id;
    return r;
}

CheckResult CheckResult::deny(const QString &id, const QString &why)
{
    CheckResult r;
    r.ok = false;
    r.reason = why;
    r.capabilityId = id;
    return r;
}

// ═══════════════════════════════════════════════════════════
//  能力登记表
// ═══════════════════════════════════════════════════════════

const QMap<QString, CapabilityDef> &CapabilityStore::registry()
{
    // 静态初始化一次。真实系统里这张表可能来自配置文件，
    // 但内置一份保证系统在没有配置时依然安全。
    static const QMap<QString, CapabilityDef> reg = {
        { QStringLiteral("fs.read"),      { QStringLiteral("fs.read"),      Level::Safe,   QStringLiteral("读取指定路径") } },
        { QStringLiteral("mem.read"),     { QStringLiteral("mem.read"),     Level::Safe,   QStringLiteral("读取长期记忆") } },

        { QStringLiteral("fs.write"),     { QStringLiteral("fs.write"),     Level::Normal, QStringLiteral("写入指定路径") } },
        { QStringLiteral("proc.spawn"),   { QStringLiteral("proc.spawn"),   Level::Normal, QStringLiteral("启动子进程") } },
        { QStringLiteral("mem.write"),    { QStringLiteral("mem.write"),    Level::Normal, QStringLiteral("写入长期记忆") } },

        { QStringLiteral("fs.delete"),    { QStringLiteral("fs.delete"),    Level::Danger, QStringLiteral("删除文件") } },
        { QStringLiteral("proc.kill"),    { QStringLiteral("proc.kill"),    Level::Danger, QStringLiteral("终止进程") } },
        { QStringLiteral("net.fetch"),    { QStringLiteral("net.fetch"),    Level::Danger, QStringLiteral("对外网络请求") } },
        { QStringLiteral("net.listen"),   { QStringLiteral("net.listen"),   Level::Danger, QStringLiteral("监听端口") } },
        { QStringLiteral("sys.pkg"),      { QStringLiteral("sys.pkg"),      Level::Danger, QStringLiteral("安装/卸载软件包") } },
        { QStringLiteral("sys.settings"), { QStringLiteral("sys.settings"), Level::Danger, QStringLiteral("修改系统设置") } },

        { QStringLiteral("pay.transfer"), { QStringLiteral("pay.transfer"), Level::Always, QStringLiteral("资金操作") } },
        { QStringLiteral("kernel.modify"),{ QStringLiteral("kernel.modify"),Level::Always, QStringLiteral("修改 shuios 内核本体") } },
        { QStringLiteral("cap.grant"),    { QStringLiteral("cap.grant"),    Level::Always, QStringLiteral("签发新的能力凭据") } },
    };
    return reg;
}

bool CapabilityStore::isKnown(const QString &capability)
{
    return registry().contains(capability);
}

// ═══════════════════════════════════════════════════════════
//  作用域匹配 —— 边界安全
//
//  这里是最容易写错、也最危险的地方。
//  如果只做 startsWith()，那么授权 /home/user/docs 之后，
//  /home/user/docs_evil/ 也会被放行 —— 权限逃逸。
// ═══════════════════════════════════════════════════════════

bool CapabilityStore::scopeMatches(const QString &granted, const QString &requested)
{
    if (granted == QLatin1String("*")) {
        return true;
    }

    // 归一化：去掉末尾斜杠，解析 . 和 ..
    const QString g = QDir::cleanPath(granted).chopped(1);
    const QString r = QDir::cleanPath(requested).chopped(1);

    if (r == g) {
        return true;
    }

    // 必须是 g 后面紧跟 '/' 才算子路径
    return r.startsWith(g + QLatin1Char('/'));
}

// ═══════════════════════════════════════════════════════════
//  CapabilityStore
// ═══════════════════════════════════════════════════════════

CapabilityStore::CapabilityStore(QObject *parent)
    : QObject(parent)
{
}

bool CapabilityStore::initialize(const QString &stateDir)
{
    if (stateDir.isEmpty()) {
        m_stateDir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)
                     + QStringLiteral("/state");
    } else {
        m_stateDir = stateDir;
    }

    if (!QDir().mkpath(m_stateDir)) {
        Log::error(QStringLiteral("无法创建状态目录: %1").arg(m_stateDir));
        return false;
    }

    const bool loaded = load();
    Ledger::instance().initialize(m_stateDir);
    Log::info(QStringLiteral("权限内核就绪，状态目录 %1，已加载 %2 枚凭据")
                  .arg(m_stateDir).arg(m_caps.size()));
    return loaded;
}

Capability CapabilityStore::grant(const QString &capability,
                                  const QString &scope,
                                  const QString &subject,
                                  int ttlSeconds,
                                  int uses,
                                  const QString &note,
                                  bool humanApproved,
                                  QString *errorOut)
{
    auto fail = [&](const QString &msg) {
        if (errorOut) *errorOut = msg;
        Ledger::instance().append(QStringLiteral("GRANT_DENIED"),
                                  {{ QStringLiteral("capability"), capability },
                                   { QStringLiteral("reason"), msg }});
        Log::warn(QStringLiteral("拒绝签发 %1: %2").arg(capability, msg));
        return Capability{};
    };

    if (!isKnown(capability)) {
        return fail(QStringLiteral("未知能力: %1").arg(capability));
    }

    const CapabilityDef def = registry().value(capability);

    // ── 铁律：ALWAYS 级能力，AI 不能自主签发 ──────────────
    if (def.level == Level::Always && !humanApproved) {
        return fail(QStringLiteral(
            "能力 %1 属于 ALWAYS 级，AI 不能自主签发 —— 必须人类显式批准")
            .arg(capability));
    }

    const qint64 now = QDateTime::currentSecsSinceEpoch();

    Capability cap;
    cap.id        = QStringLiteral("cap-%1").arg(++m_seq, 5, 10, QLatin1Char('0'));
    cap.name      = capability;
    cap.scope     = scope;
    cap.subject   = subject;
    cap.level     = def.level;
    cap.issuedAt  = now;
    cap.expiresAt = now + (ttlSeconds > 0 ? ttlSeconds : 600);
    cap.usesLeft  = uses;
    cap.note      = note;
    // 128 位随机密钥
    cap.secret    = QString::number(QRandomGenerator::global()->generate64(), 16)
                  + QString::number(QRandomGenerator::global()->generate64(), 16);

    m_caps.insert(cap.id, cap);
    save();

    Ledger::instance().append(QStringLiteral("GRANT"),
                              {{ QStringLiteral("id"), cap.id },
                               { QStringLiteral("capability"), capability },
                               { QStringLiteral("scope"), scope },
                               { QStringLiteral("subject"), subject },
                               { QStringLiteral("ttl"), ttlSeconds },
                               { QStringLiteral("level"), levelName(cap.level) },
                               { QStringLiteral("human"), humanApproved }});

    Log::info(QStringLiteral("签发凭据 %1 [%2] scope=%3 subject=%4 ttl=%5s")
                  .arg(cap.id, levelName(cap.level), scope, subject)
                  .arg(ttlSeconds));

    emit capabilityGranted(cap);
    return cap;
}

CheckResult CapabilityStore::check(const QString &token,
                                   const QString &capability,
                                   const QString &scope)
{
    const int dot = token.indexOf(QLatin1Char('.'));
    if (dot <= 0) {
        return CheckResult::deny(QString(), QStringLiteral("凭据格式非法"));
    }

    const QString cid    = token.left(dot);
    const QString secret = token.mid(dot + 1);

    auto deny = [&](const QString &why) {
        Ledger::instance().append(QStringLiteral("DENY"),
                                  {{ QStringLiteral("id"), cid },
                                   { QStringLiteral("reason"), why },
                                   { QStringLiteral("requested"), capability }});
        emit accessDenied(why);
        return CheckResult::deny(cid, why);
    };

    if (!m_caps.contains(cid)) {
        return deny(QStringLiteral("凭据不存在"));
    }

    Capability cap = m_caps.value(cid);

    if (cap.secret != secret) {
        return deny(QStringLiteral("凭据密钥不匹配（伪造？）"));
    }

    const QString st = cap.status();
    if (st != QLatin1String("LIVE")) {
        return deny(QStringLiteral("凭据状态 %1").arg(st));
    }

    if (cap.name != capability) {
        return deny(QStringLiteral("凭据只授权 %1，本次请求 %2")
                        .arg(cap.name, capability));
    }

    if (!scopeMatches(cap.scope, scope)) {
        return deny(QStringLiteral("越权：凭据作用域 %1，请求 %2")
                        .arg(cap.scope, scope));
    }

    // ── 放行：消费一次 ────────────────────────────────────
    if (cap.usesLeft > 0) {
        cap.usesLeft--;
    }
    cap.consumed++;
    m_caps.insert(cid, cap);
    save();

    Ledger::instance().append(QStringLiteral("ALLOW"),
                              {{ QStringLiteral("id"), cid },
                               { QStringLiteral("capability"), capability },
                               { QStringLiteral("scope"), scope },
                               { QStringLiteral("consumed"), cap.consumed }});

    emit capabilityConsumed(cid, capability);
    return CheckResult::allow(cid);
}

bool CapabilityStore::revoke(const QString &capabilityId)
{
    if (!m_caps.contains(capabilityId)) {
        return false;
    }
    m_caps[capabilityId].revoked = true;
    save();
    Ledger::instance().append(QStringLiteral("REVOKE"),
                              {{ QStringLiteral("id"), capabilityId }});
    return true;
}

int CapabilityStore::sweep()
{
    QStringList dead;
    for (auto it = m_caps.constBegin(); it != m_caps.constEnd(); ++it) {
        if (!it.value().isLive()) {
            dead << it.key();
        }
    }
    for (const QString &id : dead) {
        m_caps.remove(id);
    }
    if (!dead.isEmpty()) {
        save();
        Ledger::instance().append(QStringLiteral("SWEEP"),
                                  {{ QStringLiteral("count"), dead.size() }});
    }
    return dead.size();
}

QList<Capability> CapabilityStore::list(const QString &subject, bool liveOnly) const
{
    QList<Capability> out;
    for (const Capability &c : m_caps) {
        if (!subject.isEmpty() && c.subject != subject) continue;
        if (liveOnly && !c.isLive()) continue;
        out << c;
    }
    std::sort(out.begin(), out.end(), [](const Capability &a, const Capability &b) {
        return a.issuedAt > b.issuedAt;
    });
    return out;
}

// ── 持久化 ────────────────────────────────────────────────

bool CapabilityStore::load()
{
    const QString path = m_stateDir + QStringLiteral("/caps.json");
    QFile f(path);
    if (!f.exists()) {
        return true;   // 首次运行
    }
    if (!f.open(QIODevice::ReadOnly)) {
        Log::error(QStringLiteral("无法读取凭据库: %1").arg(path));
        return false;
    }

    const QJsonObject root = QJsonDocument::fromJson(f.readAll()).object();
    m_seq = root.value(QStringLiteral("seq")).toInt(0);

    const QJsonObject caps = root.value(QStringLiteral("caps")).toObject();
    for (auto it = caps.constBegin(); it != caps.constEnd(); ++it) {
        const QJsonObject o = it.value().toObject();
        Capability c;
        c.id        = it.key();
        c.name      = o.value(QStringLiteral("name")).toString();
        c.scope     = o.value(QStringLiteral("scope")).toString();
        c.subject   = o.value(QStringLiteral("subject")).toString();
        c.level     = levelFromName(o.value(QStringLiteral("level")).toString());
        c.issuedAt  = static_cast<qint64>(o.value(QStringLiteral("issuedAt")).toDouble());
        c.expiresAt = static_cast<qint64>(o.value(QStringLiteral("expiresAt")).toDouble());
        c.usesLeft  = o.value(QStringLiteral("usesLeft")).toInt(-1);
        c.secret    = o.value(QStringLiteral("secret")).toString();
        c.consumed  = o.value(QStringLiteral("consumed")).toInt(0);
        c.revoked   = o.value(QStringLiteral("revoked")).toBool(false);
        c.note      = o.value(QStringLiteral("note")).toString();
        m_caps.insert(c.id, c);
    }
    return true;
}

bool CapabilityStore::save()
{
    QJsonObject caps;
    for (auto it = m_caps.constBegin(); it != m_caps.constEnd(); ++it) {
        const Capability &c = it.value();
        caps.insert(c.id, QJsonObject{
            { QStringLiteral("name"),      c.name },
            { QStringLiteral("scope"),     c.scope },
            { QStringLiteral("subject"),   c.subject },
            { QStringLiteral("level"),     levelName(c.level) },
            { QStringLiteral("issuedAt"),  static_cast<double>(c.issuedAt) },
            { QStringLiteral("expiresAt"), static_cast<double>(c.expiresAt) },
            { QStringLiteral("usesLeft"),  c.usesLeft },
            { QStringLiteral("secret"),    c.secret },
            { QStringLiteral("consumed"),  c.consumed },
            { QStringLiteral("revoked"),   c.revoked },
            { QStringLiteral("note"),      c.note },
        });
    }

    const QJsonObject root{
        { QStringLiteral("seq"),  m_seq },
        { QStringLiteral("caps"), caps },
    };

    // QSaveFile: 原子写入，避免崩溃时文件损坏
    QSaveFile f(m_stateDir + QStringLiteral("/caps.json"));
    if (!f.open(QIODevice::WriteOnly)) {
        Log::error(QStringLiteral("无法写入凭据库"));
        return false;
    }
    f.write(QJsonDocument(root).toJson(QJsonDocument::Indented));
    if (!f.commit()) {
        Log::error(QStringLiteral("凭据库提交失败"));
        return false;
    }
    return true;
}

} // namespace shuios