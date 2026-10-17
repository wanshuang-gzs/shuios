#pragma once

#include "actions/ActionRegistry.h"

namespace shuios {

// 文件类动作的具体实现
namespace FileActions {
    ActionResult list(const QString &path);
    ActionResult read(const QString &path);
    ActionResult mkdir(const QString &path);
    ActionResult move(const QString &src, const QString &dst);
    ActionResult remove(const QString &path);      // 走垃圾桶
    ActionResult classify(const QString &path);
}

} // namespace shuios