// ═══════════════════════════════════════════════════════════
//  BrainClient 的实现文件
//
// 【为什么需要这个文件】
// BrainClient 是带 Q_OBJECT 的抽象基类。Qt 的 AUTOMOC 只为
// 【有对应 .cpp 的头文件】生成 moc 代码 —— 如果只有 BrainClient.h
// 而没有 BrainClient.cpp，链接时会报:
//
//   undefined reference to `shuios::BrainClient::staticMetaObject'
//   undefined reference to `shuios::BrainClient::deltaReceived(QString const&)'
//
// 因为信号函数的实现和元对象数据都由 moc 生成，moc 没跑就没符号。
//
// 这个 .cpp 的作用就是让 AUTOMOC 认领 BrainClient.h，
// 同时把虚析构函数的定义放在这里（避免 vtable 被内联到每个 .o）。
// ═══════════════════════════════════════════════════════════

#include "brain/BrainClient.h"

namespace shuios {

BrainClient::~BrainClient() = default;

} // namespace shuios