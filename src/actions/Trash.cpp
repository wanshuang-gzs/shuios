#include "actions/Trash.h"
#include "core/Log.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QStandardPaths>

namespace shuios {

Trash &Trash::instance()
{
    static Trash s;
    return s;
}

bool Trash::initialize(const QString &stateDir)
{
    const QString base = stateDir.isEmpty()
        ? QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)
        : stateDir;
    m_trashDir = base + QStringLiteral("/trash");
    const bool ok = QDir().mkpath(m_trashDir);
    Log::info(QStringLiteral("垃圾桶: %1").arg(m_trashDir));
    return ok;
}

QString Trash::move(const QString &path, QString *errorOut)
{
    auto fail = [&](const QString &m) {
        if (errorOut) *errorOut = m;
        Log::warn(QStringLiteral("入垃圾桶失败: %1").arg(m));
        return QString();
    };

    if (m_trashDir.isEmpty()) {
        return fail(QStringLiteral("垃圾桶未初始化"));
    }

    QFileInfo info(path);
    if (!info.exists()) {
        return fail(QStringLiteral("路径不存在: %1").arg(path));
    }

    // 条目名保留时间戳 + 原名，避免冲突
    const QString stamp = QDateTime::currentDateTime()
                              .toString(QStringLiteral("yyyyMMdd_hhmmss_zzz"));
    const QString baseName = info.fileName().isEmpty()
                                 ? QStringLiteral("root")
                                 : info.fileName();
    const QString entryId = QStringLiteral("%1_%2").arg(stamp, baseName);
    const QString dest = m_trashDir + QLatin1Char('/') + entryId;

    if (!QFile::rename(path, dest)) {
        // rename 跨文件系统会失败，退化为 copy+remove
        Log::info(QStringLiteral("rename 失败，尝试复制模式: %1").arg(path));
        if (info.isDir()) {
            return fail(QStringLiteral("暂不支持跨分区的目录删除，请手动处理: %1").arg(path));
        }
        if (!QFile::copy(path, dest)) {
            return fail(QStringLiteral("复制到垃圾桶失败: %1").arg(path));
        }
        QFile::remove(path);
    }

    // 记录原路径，便于恢复
    QFile meta(m_trashDir + QLatin1Char('/') + entryId + QStringLiteral(".meta"));
    if (meta.open(QIODevice::WriteOnly)) {
        meta.write(QJsonDocument(QJsonObject{
            { QStringLiteral("original"),  path },
            { QStringLiteral("deletedAt"), QDateTime::currentSecsSinceEpoch() },
            { QStringLiteral("isDir"),     info.isDir() },
        }).toJson(QJsonDocument::Compact));
        meta.close();
    }

    Log::info(QStringLiteral("已移入垃圾桶: %1 → %2").arg(path, dest));
    return dest;
}

bool Trash::restore(const QString &entryId, const QString &destPath, QString *errorOut)
{
    const QString src = m_trashDir + QLatin1Char('/') + entryId;
    if (!QFileInfo::exists(src)) {
        if (errorOut) *errorOut = QStringLiteral("垃圾桶中无此条目: %1").arg(entryId);
        return false;
    }
    if (!QFile::rename(src, destPath)) {
        if (errorOut) *errorOut = QStringLiteral("恢复失败，目标可能已存在: %1").arg(destPath);
        return false;
    }
    QFile::remove(m_trashDir + QLatin1Char('/') + entryId + QStringLiteral(".meta"));
    Log::info(QStringLiteral("已恢复: %1 → %2").arg(entryId, destPath));
    return true;
}

QList<QVariantMap> Trash::list() const
{
    QList<QVariantMap> out;
    QDir dir(m_trashDir);
    const QFileInfoList entries = dir.entryInfoList(QDir::AllEntries | QDir::NoDotAndDotDot,
                                                    QDir::Time);
    for (const QFileInfo &fi : entries) {
        if (fi.suffix() == QLatin1String("meta")) continue;

        QVariantMap item;
        item[QStringLiteral("id")]   = fi.fileName();
        item[QStringLiteral("path")] = fi.absoluteFilePath();
        item[QStringLiteral("isDir")] = fi.isDir();

        QFile meta(fi.absoluteFilePath() + QStringLiteral(".meta"));
        if (meta.open(QIODevice::ReadOnly)) {
            const QJsonObject o = QJsonDocument::fromJson(meta.readAll()).object();
            item[QStringLiteral("original")]  = o.value(QStringLiteral("original")).toString();
            item[QStringLiteral("deletedAt")] = o.value(QStringLiteral("deletedAt")).toDouble();
            meta.close();
        }
        out << item;
    }
    return out;
}

} // namespace shuios