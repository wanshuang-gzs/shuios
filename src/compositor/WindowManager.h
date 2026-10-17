#pragma once

#include <QObject>
#include <QString>

namespace shuios {

// 窗口策略。v0.1 只有一个全屏窗口（AI 界面），
// 但策略接口先立好，v0.2 加多窗口时不用改调用方。
class WindowManager : public QObject
{
    Q_OBJECT
public:
    enum class Mode { Fullscreen, Tiling, Floating };

    explicit WindowManager(QObject *parent = nullptr);

    Mode mode() const { return m_mode; }
    void setMode(Mode m);

    // 是否允许该应用显示。权限层可以否决。
    bool shouldShow(const QString &appId) const;

signals:
    void modeChanged(Mode m);

private:
    Mode m_mode = Mode::Fullscreen;
};

} // namespace shuios