#!/bin/sh
# shuios-firstboot: 首次启动初始化（只运行一次）。
set -u

MARK=/var/lib/shuios/.firstboot-done
log() { echo "shuios-firstboot: $*"; }

mkdir -p /workspace /var/lib/shuios/models /var/log/shuios/agents

if [ ! -f /workspace/README.md ]; then
    cat > /workspace/README.md <<'EOF'
# 欢迎来到 shuios（氵系统）

这是一个面向 AI 的极简 Linux 发行版：根文件系统只读不可变，
所有需要长期保留的东西都放在这个 `/workspace` 目录里。

## 立刻可以做的三件事

1. 看系统状态：`shui-ctl status`
2. 直接调用系统工具：`shui-ctl call fs.list '{"path":"/workspace"}'`
3. 用自然语言指挥它：运行 `shui`，然后输入一句话，例如
   “看看 /workspace 里有什么，并统计有多少个文件”

## 放模型

把 `.gguf` 模型文件放进 `/var/lib/shuios/models/`（同样是持久化的），
本地推理服务就能用它。

## 记住

- `/workspace` 和 `/var/lib/shuios` 持久化；其余路径重启即恢复出厂状态。
- 智能体由 `shuiosd` 托管，受 cgroup v2 内存/CPU/进程数限制。
EOF
    log "已写入 /workspace/README.md"
fi

if [ -z "$(ls -A /var/lib/shuios/models 2>/dev/null)" ]; then
    cat > /var/lib/shuios/models/README.txt <<'EOF'
把 .gguf 模型文件放进这个目录。
shui 的自然语言能力依赖本机推理服务（llama.cpp 的 OpenAI 兼容接口）。
EOF
    log "模型仓库为空，已放置说明"
fi

touch "$MARK"
log "首次启动初始化完成"
exit 0
