#pragma once

// ═══════════════════════════════════════════════════════════
//  计划 (Plan) 数据结构
//
//  用户说人话 → 系统产出 plan → 人类审阅 → 才执行
//
//  plan 不是内部实现细节，是【给用户看的合同】。
//  每一步都标明：做什么、什么范围、多危险、需要什么权限。
// ═══════════════════════════════════════════════════════════

#include "capability/CapabilityStore.h"

#include <QString>
#include <QList>

namespace shuios {

struct PlanStep {
    QString op;          // "fs.write"
    QString description; // "移动 47 个文件到 sorted/"
    QString scope;       // 作用路径
    QString requires;    // 需要的能力名
    Level   level = Level::Safe;
    QVariantMap args;
};

struct Plan {
    QString     rawInput;      // 用户原话
    QString     intent;        // "fs.organize"
    double      confidence = 0.0;
    QStringList warnings;
    QList<PlanStep> steps;

    Level maxLevel() const;
    bool  requiresHuman() const;   // 是否含 DANGER 及以上
    bool  isValid() const { return !steps.isEmpty() && confidence > 0.0; }
};

} // namespace shuios