#pragma once

#include <QString>
#include <QVariant>
#include <QSettings>

namespace shuios {

// 配置加载。优先级：环境变量 > 配置文件 > 默认值
class Config
{
public:
    static Config &instance();

    bool    initialize();
    QVariant value(const QString &key, const QVariant &def = {}) const;
    void    setValue(const QString &key, const QVariant &v);

    QString configPath() const { return m_path; }

private:
    Config() = default;
    Q_DISABLE_COPY(Config)
    QString m_path;
    mutable QSettings *m_settings = nullptr;
};

} // namespace shuios