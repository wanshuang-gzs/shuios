#include "compositor/ShimCompositor.h"
#include "core/Log.h"

namespace shuios {

ShimCompositor::ShimCompositor(QObject *parent)
    : QObject(parent)
{
}

ShimCompositor::~ShimCompositor() = default;

bool ShimCompositor::start()
{
    // v0.1 说明:
    //
    // 真实实现需要在 QML 侧实例化 WaylandCompositor 并挂上
    // XdgShell / WlShell 等扩展，QML 类型比 C++ 更省事:
    //
    //   WaylandCompositor {
    //       XdgShell { onToplevelCreated: ... }
    //       ...
    //   }
    //
    // 这里保留 C++ 入口，是因为窗口策略（平铺/全屏切换）、
    // 权限拦截（控制哪些应用可以出网）最终要落在 C++ 侧。
    // v0.1 先由 QML 承担 compositor 主体，此处在装配阶段留钩子。
    //
    // 【这一整块我无法在本机验证 —— 需要你在 N100 上编译运行确认。】

    Log::info(QStringLiteral("合成器启动中…"));
    m_running = true;
    Log::info(QStringLiteral("合成器已就绪（v0.1：由 QML 承载 WaylandCompositor）"));
    return true;
}

void ShimCompositor::setRootItem(QQuickItem *item)
{
    if (m_rootItem == item) return;
    m_rootItem = item;
    emit rootItemChanged();
}

} // namespace shuios