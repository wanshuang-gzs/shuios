#pragma once

#include "intent/Plan.h"

#include <QString>
#include <QVariantMap>
#include <functional>

namespace shuios {

class CapabilityStore;

struct ActionResult {
    bool    ok = false;
    QString status;        // OK / NEEDS_HUMAN / CAP_DENIED / FAILED / SKIPPED
    QString detail;
    QVariantMap data;
};

// ═══════════════════════════════════════════════════════════
//  动作执行引擎
//
//  每个动作执行前，必须:
//    ① 向权限内核申请一枚【该动作专属】的凭据
//    ② 校验凭据 —— 不通过则动作不发生
//    ③ 执行
//    ④ 记账
//
//  DANGER 级动作若 humanApproved=false，直接停下，后续步骤跳过。
// ═══════════════════════════════════════════════════════════

class ActionRegistry
{
public:
    static ActionRegistry &instance();

    void setCapabilityStore(CapabilityStore *store) { m_caps = store; }

    // 执行整个 plan。approved 等价于"人类按下了确认"。
    QList<ActionResult> execute(const Plan &plan, bool approved);

private:
    ActionRegistry() = default;
    ActionRegistry(const ActionRegistry &) = delete;

    ActionResult runStep(const PlanStep &step, const Plan &plan, bool approved);

    CapabilityStore *m_caps = nullptr;
};

} // namespace shuios