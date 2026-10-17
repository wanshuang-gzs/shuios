#pragma once

#include "brain/BrainClient.h"

#include <QNetworkAccessManager>

namespace shuios {

// ═══════════════════════════════════════════════════════════
//  DeepSeek 提供者
//
//  API Key 来源（按优先级）:
//    1. 环境变量 SHUIOS_DEEPSEEK_KEY
//    2. 配置文件 ~/.config/shuios/config.json 的 deepseek_api_key
//
//  【绝不】把密钥编译进二进制。
// ═══════════════════════════════════════════════════════════

class DeepSeekProvider : public BrainClient
{
    Q_OBJECT
public:
    explicit DeepSeekProvider(QObject *parent = nullptr);
    ~DeepSeekProvider() override;

    void chatStream(const QList<Message> &history) override;
    void abort() override;

    QString name() const override { return QStringLiteral("DeepSeek"); }
    bool    isReady() const override;

    void setApiKey(const QString &key);
    void setModel(const QString &model) { m_model = model; }
    void setEndpoint(const QString &url) { m_endpoint = url; }

    // 从环境变量 / 配置文件加载密钥
    static QString resolveApiKey();

private slots:
    void onReadyRead();
    void onFinished();

private:
    void handleSseLine(const QByteArray &line);

    QNetworkAccessManager *m_net = nullptr;
    QNetworkReply         *m_reply = nullptr;
    QString m_apiKey;
    QString m_model = QStringLiteral("deepseek-chat");
    QString m_endpoint = QStringLiteral("https://api.deepseek.com/v1/chat/completions");
    QString m_buffer;       // SSE 行缓冲
    QString m_accumulated;  // 累计全文
    bool    m_aborted = false;
};

} // namespace shuios