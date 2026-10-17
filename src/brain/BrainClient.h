#pragma once

// ═══════════════════════════════════════════════════════════
//  shuios 大脑接口
//
//  shuios 是身体，大脑在云上。这里是身体与大脑之间【唯一】的通道。
//
//  为什么抽象: 今天用 DeepSeek，明天可能换别家，以后可能上本地推理。
//             换大脑不该重写身体。
// ═══════════════════════════════════════════════════════════

#include <QString>
#include <QList>
#include <QObject>
#include <functional>

namespace shuios {

enum class Role { System, User, Assistant };

struct Message {
    Role    role = Role::User;
    QString content;
    qint64  timestamp = 0;

    QString roleName() const;
    static Message system(const QString &text);
    static Message user(const QString &text);
    static Message assistant(const QString &text);
};

// ═══════════════════════════════════════════════════════════
class BrainClient : public QObject
{
    Q_OBJECT
public:
    explicit BrainClient(QObject *parent = nullptr) : QObject(parent) {}
    ~BrainClient() override = default;

    // 流式对话。边生成边回调，界面不卡顿。
    //  N100 单核弱，阻塞式请求会让界面"死"几秒，所以必须流式。
    virtual void chatStream(const QList<Message> &history) = 0;
    virtual void abort() = 0;

    virtual QString name() const = 0;
    virtual bool    isReady() const = 0;

signals:
    void deltaReceived(const QString &delta);   // 增量文本
    void completed(const QString &fullText);
    void failed(const QString &error);
};

} // namespace shuios