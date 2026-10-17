#include "capability/Ledger.h"
#include "core/Log.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMutexLocker>
#include <QTextStream>

#include <QJsonValue>
#include <QVariantMap>
namespace shuios {

Ledger &Ledger::instance()
{
    static Ledger s;
    return s;
}

bool Ledger::initialize(const QString &stateDir)
{
    QMutexLocker lock(&m_mutex);

    if (!QDir().mkpath(stateDir)) {
        Log::error(QStringLiteral("账本目录创建失败: %1").arg(stateDir));
        return false;
    }
    m_path = stateDir + QStringLiteral("/ledger.log");
    m_ready = true;
    Log::info(QStringLiteral("审计账本就绪: %1").arg(m_path));
    return true;
}

void Ledger::append(const QString &event, const QVariantMap &payload)
{
    QMutexLocker lock(&m_mutex);
    if (!m_ready) {
        return;
    }

    QJsonObject obj;
    obj.insert(QStringLiteral("t"), QDateTime::currentSecsSinceEpoch());
    obj.insert(QStringLiteral("ts"),
               QDateTime::currentDateTime().toString(Qt::ISODate));
    obj.insert(QStringLiteral("event"), event);

    QJsonObject p;
    for (auto it = payload.constBegin(); it != payload.constEnd(); ++it) {
        p.insert(it.key(), QJsonValue::fromVariant(it.value()));
    }
    obj.insert(QStringLiteral("payload"), p);

    QFile f(m_path);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Append)) {
        Log::error(QStringLiteral("账本写入失败: %1").arg(m_path));
        return;
    }
    f.write(QJsonDocument(obj).toJson(QJsonDocument::Compact));
    f.write("\n");
    f.flush();
    // 关键：立即落盘。崩溃也不能丢审计记录。
    f.close();
}

QString Ledger::tail(int n) const
{
    QMutexLocker lock(&m_mutex);
    QFile f(m_path);
    if (!f.open(QIODevice::ReadOnly)) {
        return QStringLiteral("(账本为空)");
    }

    // 简单实现：整体读入取尾部。真实系统应做倒序分块读，
    // 但账本通常不大，v0.1 这样足够。
    const QList<QByteArray> lines = f.readAll().split('\n');
    const int start = qMax(0, lines.size() - n - 1);

    QString out;
    QTextStream ts(&out);
    for (int i = start; i < lines.size(); ++i) {
        if (lines[i].trimmed().isEmpty()) continue;
        const QJsonObject o = QJsonDocument::fromJson(lines[i]).object();
        ts << o.value(QStringLiteral("ts")).toString() << "  "
           << o.value(QStringLiteral("event")).toString() << "  "
           << QString::fromUtf8(QJsonDocument(o.value(QStringLiteral("payload")).toObject())
                                    .toJson(QJsonDocument::Compact))
           << "\n";
    }
    return out;
}

} // namespace shuios