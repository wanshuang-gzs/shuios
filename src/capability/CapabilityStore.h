#pragma once

// ═══════════════════════════════════════════════════════════
//  shuios 权限内核 —— 能力凭据系统
//
//  设计核心:
//    AI 进程永远不持有长期权限。每个动作申请一枚【限时·限域·限次】
//    的凭据。凭据校验不通过 = 动作不会发生。
//
//  这是 shuios 与普通 Linux 桌面最本质的区别。
//  Unix:  你要么是 root(能做任何事)，要么被关在沙箱(什么都做不了)
//  shuios: 你可以"在 ~/Downloads 下写 5 个文件，2 分钟内有效"
// ═══════════════════════════════════════════════════════════

#include <QString>
#include <QDateTime>
#include <QList>
#include <QMap>
#include <QObject>

namespace shuios {

// ── 能力分级 ──────────────────────────────────────────────
enum class Level {
    Safe,     // 只读。静默放行
    Normal,   // 有限写入。首次确认后可记住
    Danger,   // 破坏性/涉网。每次都要人类点头
    Always    // AI 永不可自主获得（改内核、资金操作）
};

QString levelName(Level l);
Level   levelFromName(const QString &name);

// ── 能力登记项 ────────────────────────────────────────────
struct CapabilityDef {
    QString name;        // "fs.write"
    Level   level;
    QString description; // 中文说明，给界面显示用
};

// ── 一枚凭据 ──────────────────────────────────────────────
struct Capability {
    QString   id;          // "cap-00042"
    QString   name;        // "fs.write"
    QString   scope;       // "/home/user/downloads"
    QString   subject;     // "agent:shuios"
    Level     level = Level::Safe;
    qint64    issuedAt = 0;
    qint64    expiresAt = 0;
    int       usesLeft = -1;   // -1 = 不限次数
    QString   secret;          // 校验密钥
    int       consumed = 0;
    bool      revoked = false;
    QString   note;

    QString status() const;         // LIVE / EXPIRED / EXHAUSTED / REVOKED
    bool    isLive() const;
    QString token() const;          // "cap-00042.<secret>"
};

// ── 校验结果 ──────────────────────────────────────────────
struct CheckResult {
    bool    ok = false;
    QString reason;
    QString capabilityId;

    static CheckResult allow(const QString &id);
    static CheckResult deny(const QString &id, const QString &why);
};

// ═══════════════════════════════════════════════════════════
class CapabilityStore : public QObject {
    Q_OBJECT
public:
    explicit CapabilityStore(QObject *parent = nullptr);

    // 初始化：加载磁盘上的凭据库
    bool initialize(const QString &stateDir = QString());

    // ── 签发 ──────────────────────────────────────────────
    // humanApproved: 是否声明"这是人类本人的决定"。
    //   ALWAYS 级能力若为 false，直接拒绝 —— AI 签不出来。
    Capability grant(const QString &capability,
                     const QString &scope,
                     const QString &subject,
                     int ttlSeconds = 600,
                     int uses = -1,
                     const QString &note = QString(),
                     bool humanApproved = false,
                     QString *errorOut = nullptr);

    // ── 校验并消费 ────────────────────────────────────────
    CheckResult check(const QString &token,
                      const QString &capability,
                      const QString &scope);

    // ── 管理 ──────────────────────────────────────────────
    bool revoke(const QString &capabilityId);
    int  sweep();                                    // 清理失效凭据
    QList<Capability> list(const QString &subject = QString(),
                           bool liveOnly = false) const;

    // ── 能力登记表 ────────────────────────────────────────
    static const QMap<QString, CapabilityDef> &registry();
    static bool isKnown(const QString &capability);

    // ── 作用域匹配（静态公开，便于单元测试）────────────────
    // 【关键】边界安全比较，不是字符串前缀：
    //   授权 /home/user/docs
    //     /home/user/docs/a.txt   → 匹配
    //     /home/user/docs_evil/x  → 不匹配  ← 简单 startswith 会误判！
    static bool scopeMatches(const QString &granted, const QString &requested);

signals:
    void capabilityGranted(const Capability &cap);
    void capabilityConsumed(const QString &id, const QString &name);
    void accessDenied(const QString &reason);

private:
    bool load();
    bool save();
    QString m_stateDir;
    QMap<QString, Capability> m_caps;
    int m_seq = 0;
};

} // namespace shuios