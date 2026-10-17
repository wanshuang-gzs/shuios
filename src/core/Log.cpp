#include "core/Log.h"

#include <QDateTime>
#include <QDebug>

namespace shuios {

static LogLevel g_level = LogLevel::Info;

void Log::setLevel(LogLevel l) { g_level = l; }

static void emit_line(const char *tag, const QString &msg)
{
    qInfo().noquote() << QStringLiteral("[%1] [%2] %3")
        .arg(QDateTime::currentDateTime().toString(QStringLiteral("hh:mm:ss")),
             QString::fromLatin1(tag), msg);
}

void Log::debug(const QString &msg) { if (g_level <= LogLevel::Debug) emit_line("DEBUG", msg); }
void Log::info(const QString &msg)  { if (g_level <= LogLevel::Info)  emit_line("INFO",  msg); }
void Log::warn(const QString &msg)  { if (g_level <= LogLevel::Warn)  emit_line("WARN",  msg); }
void Log::error(const QString &msg) {                                  emit_line("ERROR", msg); }

} // namespace shuios