#pragma once

#include <QObject>
#include <QQuickItem>

namespace shuios {

// ═══════════════════════════════════════════════════════════
//  合成器 —— shuios 的"身体"
//
//  这是 shuios 与普通应用的根本区别:
//  它不是跑在某个桌面上的程序，它【就是】那个桌面。
//  显示服务器 + 窗口管理 + AI 界面，同一个进程。
// ═══════════════════════════════════════════════════════════

class ShimCompositor : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QQuickItem *rootItem READ rootItem WRITE setRootItem NOTIFY rootItemChanged)

public:
    explicit ShimCompositor(QObject *parent = nullptr);
    ~ShimCompositor() override;

    // 初始化 Wayland 显示服务器
    bool start();

    QQuickItem *rootItem() const { return m_rootItem; }
    void setRootItem(QQuickItem *item);

signals:
    void rootItemChanged();
    void clientConnected(const QString &appId);
    void clientDisconnected(const QString &appId);

private:
    QQuickItem *m_rootItem = nullptr;
    bool m_running = false;
};

} // namespace shuios