#pragma once

// ═══════════════════════════════════════════════════════════
//  shuios 审计账本
//
//  append-only，每次写入立即 fsync。
//  目的不是"记录日志"，是「不可否认」——
//  系统做过什么、AI 申请过什么、谁批准的，事后无法篡改。
// ═══════════════════════════════════════════════════════════

#include <QString>
#include <QVariantMap>
#include <QMutex>

namespace shuios {

class Ledger
{
public:
    static Ledger &instance();

    bool initialize(const QString &stateDir);

    // 追加一条记录。线程安全，写入后 fsync。
    void append(const QString &event, const QVariantMap &payload = {});

    // 读取最近 n 条（调试/界面用）
    QString tail(int n = 50) const;

    QString path() const { return m_path; }

private:
    Ledger() = default;
    Q_DISABLE_COPY(Ledger)

    QString m_path;
    mutable QMutex m_mutex;
    bool m_ready = false;
};

} // namespace shuios