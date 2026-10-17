#include "compositor/WindowManager.h"
#include "core/Log.h"

namespace shuios {

WindowManager::WindowManager(QObject *parent)
    : QObject(parent)
{
}

void WindowManager::setMode(Mode m)
{
    if (m_mode == m) return;
    m_mode = m;
    Log::info(QStringLiteral("窗口模式切换为 %1")
                  .arg(m == Mode::Fullscreen ? QStringLiteral("全屏")
                     : m == Mode::Tiling   ? QStringLiteral("平铺")
                                           : QStringLiteral("浮动")));
    emit modeChanged(m);
}

bool WindowManager::shouldShow(const QString &appId) const
{
    // v0.2: 这里接入权限层，决定哪些应用可以显示。
    // 例如被标记为"不可信"的应用不允许全屏接管。
    Q_UNUSED(appId)
    return true;
}

} // namespace shuios