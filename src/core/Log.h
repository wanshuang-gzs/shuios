#pragma once

#include <QString>

namespace shuios {

enum class LogLevel { Debug, Info, Warn, Error };

class Log
{
public:
    static void setLevel(LogLevel l);
    static void debug(const QString &msg);
    static void info(const QString &msg);
    static void warn(const QString &msg);
    static void error(const QString &msg);
};

} // namespace shuios