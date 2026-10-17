#include "actions/ActionRegistry.h"
#include "actions/FileActions.h"
#include "capability/CapabilityStore.h"
#include "capability/Ledger.h"
#include "core/Log.h"

namespace shuios {

ActionRegistry &ActionRegistry::instance()
{
    static ActionRegistry s;
    return s;
}

QList<ActionResult> ActionRegistry::execute(const Plan &plan, bool approved)
{
    QList<ActionResult> results;
    bool halt = false;

    const QString subject = QStringLiteral("agent:shuios");

    for (const PlanStep &step : plan.steps) {
        if (halt) {
            ActionResult r;
            r.status = QStringLiteral("SKIPPED");
            r.detail = QStringLiteral("前序步骤未通过，已中止");
            results << r;
            continue;
        }

        const bool risky = static_cast<int>(step.level) >= static_cast<int>(Level::Danger);

        // ── 关卡 1: 危险动作需要人类点头 ──────────────────
        if (risky && !approved) {
            ActionResult r;
            r.status = QStringLiteral("NEEDS_HUMAN");
            r.detail = QStringLiteral("%1 级动作，需要人类确认")
                           .arg(levelName(step.level));
            results << r;
            halt = true;    // 后面的步骤一律不执行
            Log::warn(QStringLiteral("动作被拦下，等待人类确认: %1").arg(step.op));
            continue;
        }

        results << runStep(step, plan, approved);
        if (!results.last().ok) {
            halt = true;
        }
    }
    return results;
}

ActionResult ActionRegistry::runStep(const PlanStep &step, const Plan &plan, bool approved)
{
    ActionResult res;

    if (!m_caps) {
        res.status = QStringLiteral("FAILED");
        res.detail = QStringLiteral("权限内核未装配");
        return res;
    }

    // ── 关卡 2: 申请凭据 ──────────────────────────────────
    QString err;
    const Capability cap = m_caps->grant(
        step.requires,
        step.scope,
        QStringLiteral("agent:shuios"),
        120,                       // 2 分钟有效
        1,                         // 只用一次
        QStringLiteral("intent=%1 op=%2").arg(plan.intent, step.op),
        // 只有人类 approved 时才允许签发 ALWAYS 级
        approved,
        &err);

    if (cap.id.isEmpty()) {
        res.status = QStringLiteral("CAP_DENIED");
        res.detail = err;
        Ledger::instance().append(QStringLiteral("STEP_DENIED"),
            { { QStringLiteral("op"), step.op }, { QStringLiteral("reason"), err } });
        return res;
    }

    // ── 关卡 3: 校验并消费凭据 ────────────────────────────
    const CheckResult chk = m_caps->check(cap.token(), step.requires, step.scope);
    if (!chk.ok) {
        res.status = QStringLiteral("CAP_CHECK_FAILED");
        res.detail = chk.reason;
        return res;
    }

    // ── 关卡 4: 真正执行 ──────────────────────────────────
    const QString path = step.args.value(QStringLiteral("path")).toString();

    if (step.op == QLatin1String("fs.list")) {
        res = FileActions::list(path);
    } else if (step.op == QLatin1String("fs.read")) {
        res = FileActions::read(path);
    } else if (step.op == QLatin1String("fs.mkdir")) {
        res = FileActions::mkdir(path);
    } else if (step.op == QLatin1String("fs.move")) {
        res = FileActions::move(path, path + QStringLiteral("/sorted"));
    } else if (step.op == QLatin1String("fs.delete")) {
        res = FileActions::remove(path);
    } else if (step.op == QLatin1String("file.classify")) {
        res = FileActions::classify(path);
    } else if (step.op == QLatin1String("text.extract")) {
        res = FileActions::read(path);
    } else if (step.op == QLatin1String("mem.write")) {
        res.ok = true;
        res.status = QStringLiteral("OK");
        res.data[QStringLiteral("note")] = QStringLiteral("记忆写入（v0.2 实现）");
    } else {
        res.status = QStringLiteral("FAILED");
        res.detail = QStringLiteral("未实现的动作: %1").arg(step.op);
    }

    res.data[QStringLiteral("capabilityId")] = cap.id;

    Ledger::instance().append(QStringLiteral("STEP_EXECUTED"),
        { { QStringLiteral("op"), step.op },
          { QStringLiteral("cap"), cap.id },
          { QStringLiteral("ok"), res.ok },
          { QStringLiteral("scope"), step.scope } });

    return res;
}

} // namespace shuios