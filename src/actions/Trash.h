#pragma once

#include <QString>
#include <QVariantMap>

namespace shuios {

// ═══════════════════════════════════════════════════════════
//  垃圾桶 —— AI 会犯错，所以默认不真删
//
//  "删除"实际是移动到 trash 目录，保留原路径信息，
//  支持 undo 恢复。这是 shuios 的默认安全策略。
// ═══════════════════════════════════════════════════════════

class Trash
{
public:
    static Trash &instance();

    bool initialize(const QString &stateDir = QString());

    // 把 path 移入垃圾桶。返回可恢复的位置。
    QString move(const QString &path, QString *errorOut = nullptr);

    // 从垃圾桶恢复。entryId 是垃圾桶里的目录名。
    bool restore(const QString &entryId, const QString &destPath,
                 QString *errorOut = nullptr);

    // 列出垃圾桶条目
    QList<QVariantMap> list() const;

    QString path() const { return m_trashDir; }

private:
    Trash() = default;
    Q_DISABLE_COPY(Trash)
    QString m_trashDir;
};

} // namespace shuios