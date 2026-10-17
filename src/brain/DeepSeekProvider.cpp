#include "brain/DeepSeekProvider.h"
#include "core/Config.h"
#include "core/Log.h"
#include "capability/Ledger.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QProcessEnvironment>
#include <QUrl>

#include <QNetworkAccessManager>
namespace shuios {

// ── Message ───────────────────────────────────────────────

QString Message::roleName() const
{
    switch (role) {
    case Role::System:    return QStringLiteral("system");
    case Role::Assistant: return QStringLiteral("assistant");
    case Role::User:      break;
    }
    return QStringLiteral("user");
}

Message Message::system(const QString &t)    { Message m; m.role = Role::System;    m.content = t; return m; }
Message Message::user(const QString &t)      { Message m; m.role = Role::User;      m.content = t; return m; }
Message Message::assistant(const QString &t) { Message m; m.role = Role::Assistant; m.content = t; return m; }

// ── DeepSeekProvider ──────────────────────────────────────

DeepSeekProvider::DeepSeekProvider(QObject *parent)
    : BrainClient(parent)
    , m_net(new QNetworkAccessManager(this))
{
    m_apiKey = resolveApiKey();
}

DeepSeekProvider::~DeepSeekProvider()
{
    abort();
}

QString DeepSeekProvider::resolveApiKey()
{
    // 1. 环境变量优先
    const QString env = QProcessEnvironment::systemEnvironment()
                            .value(QStringLiteral("SHUIOS_DEEPSEEK_KEY"));
    if (!env.isEmpty()) {
        return env;
    }
    // 2. 配置文件
    return Config::instance().value(QStringLiteral("deepseek_api_key")).toString();
}

void DeepSeekProvider::setApiKey(const QString &key)
{
    m_apiKey = key;
}

bool DeepSeekProvider::isReady() const
{
    return !m_apiKey.isEmpty();
}

void DeepSeekProvider::abort()
{
    m_aborted = true;
    if (m_reply) {
        m_reply->abort();
        m_reply->deleteLater();
        m_reply = nullptr;
    }
}

void DeepSeekProvider::chatStream(const QList<Message> &history)
{
    if (!isReady()) {
        emit failed(QStringLiteral(
            "大脑未配置：缺少 DeepSeek API Key。\n"
            "请设置环境变量 SHUIOS_DEEPSEEK_KEY，或在配置文件里填写 deepseek_api_key。"));
        return;
    }

    // 每次出网都记账 —— 这是唯一出网通路，所以一处即可审计
    Ledger::instance().append(QStringLiteral("BRAIN_REQUEST"),
        { { QStringLiteral("provider"), name() },
          { QStringLiteral("model"), m_model },
          { QStringLiteral("messages"), history.size() } });

    QJsonArray msgs;
    for (const Message &m : history) {
        msgs.append(QJsonObject{
            { QStringLiteral("role"),    m.roleName() },
            { QStringLiteral("content"), m.content },
        });
    }

    const QJsonObject body{
        { QStringLiteral("model"),       m_model },
        { QStringLiteral("messages"),    msgs },
        { QStringLiteral("stream"),      true },
        { QStringLiteral("temperature"), 0.7 },
    };

    QNetworkRequest req((QUrl(m_endpoint)));
    req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    req.setRawHeader("Authorization", "Bearer " + m_apiKey.toUtf8());
    req.setRawHeader("Accept", "text/event-stream");
    // 流式响应可能持续较久，给足超时
    req.setTransferTimeout(120000);

    m_buffer.clear();
    m_accumulated.clear();
    m_aborted = false;

    m_reply = m_net->post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(m_reply, &QNetworkReply::readyRead, this, &DeepSeekProvider::onReadyRead);
    connect(m_reply, &QNetworkReply::finished,  this, &DeepSeekProvider::onFinished);
}

void DeepSeekProvider::onReadyRead()
{
    if (!m_reply) return;

    m_buffer += QString::fromUtf8(m_reply->readAll());

    // SSE 以空行分隔事件；这里按 \n 切分逐行处理
    int idx;
    while ((idx = m_buffer.indexOf(QLatin1Char('\n'))) >= 0) {
        const QString line = m_buffer.left(idx).trimmed();
        m_buffer.remove(0, idx + 1);
        if (!line.isEmpty()) {
            handleSseLine(line.toUtf8());
        }
    }
}

void DeepSeekProvider::handleSseLine(const QByteArray &line)
{
    if (!line.startsWith("data:")) {
        return;   // 忽略注释行 / 事件类型行
    }

    QByteArray payload = line.mid(5).trimmed();
    if (payload == "[DONE]") {
        return;
    }

    const QJsonObject obj = QJsonDocument::fromJson(payload).object();
    const QJsonArray choices = obj.value(QStringLiteral("choices")).toArray();
    if (choices.isEmpty()) {
        return;
    }

    const QJsonObject delta = choices.first().toObject()
                                  .value(QStringLiteral("delta")).toObject();
    const QString text = delta.value(QStringLiteral("content")).toString();
    if (!text.isEmpty()) {
        m_accumulated += text;
        emit deltaReceived(text);
    }
}

void DeepSeekProvider::onFinished()
{
    if (!m_reply) return;

    const QNetworkReply::NetworkError err = m_reply->error();
    const int httpStatus = m_reply->attribute(
        QNetworkRequest::HttpStatusCodeAttribute).toInt();
    const QString errBody = QString::fromUtf8(m_reply->readAll());

    m_reply->deleteLater();
    m_reply = nullptr;

    if (m_aborted) {
        return;
    }

    if (err != QNetworkReply::NoError) {
        QString hint;
        if (httpStatus == 401) {
            hint = QStringLiteral("API Key 无效或已过期。");
        } else if (httpStatus == 402) {
            hint = QStringLiteral("账户余额不足。");
        } else if (httpStatus == 429) {
            hint = QStringLiteral("请求过于频繁，稍后再试。");
        } else if (httpStatus >= 500) {
            hint = QStringLiteral("服务端错误，稍后再试。");
        } else if (err == QNetworkReply::OperationCanceledError) {
            hint = QStringLiteral("请求超时或被取消。");
        }

        const QString msg = QStringLiteral("大脑请求失败 (HTTP %1)：%2 %3")
                                .arg(httpStatus)
                                .arg(m_reply ? m_reply->errorString() : QString())
                                .arg(hint);

        Ledger::instance().append(QStringLiteral("BRAIN_ERROR"),
            { { QStringLiteral("http"), httpStatus },
              { QStringLiteral("body"), errBody.left(500) } });

        emit failed(msg.trimmed());
        return;
    }

    Ledger::instance().append(QStringLiteral("BRAIN_DONE"),
        { { QStringLiteral("chars"), m_accumulated.size() } });

    emit completed(m_accumulated);
}

} // namespace shuios