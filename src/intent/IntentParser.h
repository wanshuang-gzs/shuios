#pragma once

#include "intent/Plan.h"

#include <QString>
#include <QRegularExpression>
#include <QList>

namespace shuios {

// ═══════════════════════════════════════════════════════════
//  意图解析器
//
//  v0.1 是规则引擎（确定性、零依赖、启动即用），
//  解析不出来就【明说】，绝不猜测执行。
//
//  下一步可以在这里挂一个端侧小模型做兜底，
//  但产出仍然必须是 plan，而不是直接动作。
// ═══════════════════════════════════════════════════════════

class IntentParser
{
public:
    static Plan parse(const QString &input);

    // 供单元测试使用
    static bool scopeLike(const QString &path);

private:
    struct Pattern {
        QRegularExpression regex;
        QString intent;
        double  confidence;
    };

    static const QList<Pattern> &patterns();
};

} // namespace shuios