#include "actions/FileActions.h"
#include "actions/Trash.h"
#include "core/Log.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QTextStream>

#include <QVariantMap>
namespace shuios {
namespace FileActions {

static ActionResult okResult(const QVariantMap &data = {})
{
    ActionResult r;
    r.ok = true;
    r.status = QStringLiteral("OK");
    r.data = data;
    return r;
}

static ActionResult fail(const QString &why)
{
    ActionResult r;
    r.ok = false;
    r.status = QStringLiteral("FAILED");
    r.detail = why;
    return r;
}

ActionResult list(const QString &path)
{
    QDir dir(path);
    if (!dir.exists()) {
        return fail(QStringLiteral("不是目录: %1").arg(path));
    }
    const QStringList entries = dir.entryList(QDir::AllEntries | QDir::NoDotAndDotDot,
                                              QDir::DirsFirst | QDir::Name);
    return okResult({
        { QStringLiteral("path"),    path },
        { QStringLiteral("count"),   entries.size() },
        { QStringLiteral("entries"), entries.mid(0, 100) },
    });
}

ActionResult read(const QString &path)
{
    QFileInfo info(path);
    if (!info.isFile()) {
        return fail(QStringLiteral("不是文件: %1").arg(path));
    }
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) {
        return fail(QStringLiteral("无法打开: %1").arg(path));
    }
    const QString head = QString::fromUtf8(f.read(4096));
    return okResult({
        { QStringLiteral("path"),  path },
        { QStringLiteral("bytes"), static_cast<double>(info.size()) },
        { QStringLiteral("head"),  head },
    });
}

ActionResult mkdir(const QString &path)
{
    if (!QDir().mkpath(path)) {
        return fail(QStringLiteral("创建目录失败: %1").arg(path));
    }
    return okResult({ { QStringLiteral("created"), path } });
}

ActionResult move(const QString &src, const QString &dst)
{
    QDir dir(src);
    if (!dir.exists()) {
        return fail(QStringLiteral("源目录不存在: %1").arg(src));
    }

    int moved = 0;
    const QStringList names = dir.entryList(QDir::Files | QDir::NoDotAndDotDot, QDir::Name);
    for (const QString &name : names) {
        const QString full = dir.absoluteFilePath(name);
        if (full.startsWith(dst)) {
            continue;   // 别把 sorted/ 自己搬进自己
        }
        QString ext = QFileInfo(name).suffix().toLower();
        if (ext.isEmpty()) ext = QStringLiteral("other");

        const QString targetDir = dst + QLatin1Char('/') + ext;
        QDir().mkpath(targetDir);

        QFile f(full);
        if (f.rename(targetDir + QLatin1Char('/') + name)) {
            moved++;
        } else {
            Log::warn(QStringLiteral("移动失败: %1").arg(full));
        }
    }
    return okResult({ { QStringLiteral("moved"), moved } });
}

ActionResult remove(const QString &path)
{
    // 【关键】不真删。移入垃圾桶，支持恢复。
    QString err;
    const QString dest = Trash::instance().move(path, &err);
    if (dest.isEmpty()) {
        return fail(err.isEmpty() ? QStringLiteral("删除失败") : err);
    }
    return okResult({
        { QStringLiteral("path"), path },
        { QStringLiteral("recoverable_at"), dest },
        { QStringLiteral("note"), QStringLiteral("已移入垃圾桶，可用 shuios undo 恢复") },
    });
}

ActionResult classify(const QString &path)
{
    QDir dir(path);
    if (!dir.exists()) {
        return fail(QStringLiteral("不是目录: %1").arg(path));
    }
    QVariantMap buckets;
    const QFileInfoList files = dir.entryInfoList(QDir::Files | QDir::NoDotAndDotDot, QDir::Name);
    for (const QFileInfo &fi : files) {
        QString ext = fi.suffix().toLower();
        if (ext.isEmpty()) ext = QStringLiteral("other");
        buckets[ext] = buckets.value(ext).toInt() + 1;
    }
    return okResult({ { QStringLiteral("buckets"), buckets },
                      { QStringLiteral("total"), files.size() } });
}

} // namespace FileActions
} // namespace shuios