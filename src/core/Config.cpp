#include "core/Config.h"
#include "core/Log.h"

#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QStandardPaths>

#include <QSettings>
namespace shuios {

Config &Config::instance()
{
    static Config s;
    return s;
}

bool Config::initialize()
{
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::AppConfigLocation);
    QDir().mkpath(dir);
    m_path = dir + QStringLiteral("/config.json");

    // 用 QSettings 的 IniFormat 读 JSON 太别扭，这里手工读一次
    // 但对外仍以 QSettings 接口暴露，便于 write-back。
    m_settings = new QSettings(m_path, QSettings::IniFormat);
    Log::info(QStringLiteral("配置路径: %1").arg(m_path));
    return true;
}

QVariant Config::value(const QString &key, const QVariant &def) const
{
    if (!m_settings) return def;
    return m_settings->value(key, def);
}

void Config::setValue(const QString &key, const QVariant &v)
{
    if (!m_settings) return;
    m_settings->setValue(key, v);
    m_settings->sync();
}

} // namespace shuios