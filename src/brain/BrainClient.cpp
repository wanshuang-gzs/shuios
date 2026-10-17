// ═══════════════════════════════════════════════════════════
//  BrainClient 的实现文件
//
// 【为什么需要这个文件】
// BrainClient 是带 Q_OBJECT 的抽象基类，有 signals 和虚函数。
//
// Qt AUTOMOC 只为【有对应 .cpp 的头文件】生成 moc 代码：
//   - staticMetaObject（元对象数据）
//   - 信号函数的实现（deltaReceived / completed / failed）
//   - qt_metacall / qt_metacast / metaObject()
//
// 若只有 BrainClient.h 而没有 BrainClient.cpp，链接时会报：
//   undefined reference to `shuios::BrainClient::staticMetaObject'
//   undefined reference to `shuios::BrainClient::deltaReceived(QString const&)'
//
// 【第二个坑】析构函数不能 `override = default` 写在头文件里 ——
// 那会内联展开，而 vtable 的锚点（key function）就落到每个
// 使用它的编译单元，容易与 moc 生成代码产生符号冲突。
// 正确做法：头文件只声明，定义放这里。
// ═══════════════════════════════════════════════════════════

#include "brain/BrainClient.h"

namespace shuios {

// ── BrainClient ───────────────────────────────────────────

BrainClient::BrainClient(QObject *parent)
    : QObject(parent)
{
}

BrainClient::~BrainClient() = default;

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

Message Message::system(const QString &t)
{
    Message m; m.role = Role::System; m.content = t; return m;
}

Message Message::user(const QString &t)
{
    Message m; m.role = Role::User; m.content = t; return m;
}

Message Message::assistant(const QString &t)
{
    Message m; m.role = Role::Assistant; m.content = t; return m;
}

} // namespace shuios