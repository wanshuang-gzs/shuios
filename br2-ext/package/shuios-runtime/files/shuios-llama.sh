#!/bin/sh
# shuios-llama: 拉起本地推理服务。
#
# 模型选择由 shuiosd 决定（shuios-proto 里的 pick_model 策略：
# 优先 .gguf、优先能装下的最大模型、都装不下则退回最小），这里不重复实现。
set -u

MODEL=""
if [ -x /usr/bin/shui-ctl ]; then
	MODEL=$(/usr/bin/shui-ctl model-select 2>/dev/null)
fi

# shuiosd 不可用时的兜底：直接挑最大的 .gguf
if [ -z "$MODEL" ]; then
	MODEL=$(ls -S /var/lib/shuios/models/*.gguf 2>/dev/null | head -n 1)
fi

if [ -z "$MODEL" ] || [ ! -f "$MODEL" ]; then
	echo "shuios-llama: 没有可用的 .gguf 模型，退出" >&2
	echo "shuios-llama: 把模型放进 /var/lib/shuios/models/ 后 systemctl restart shuios-llama" >&2
	exit 1
fi

if [ ! -x /usr/bin/llama-server ]; then
	echo "shuios-llama: 未安装 llama-server（deconfig 里 BR2_PACKAGE_LLAMA_CPP 需要为 y）" >&2
	exit 1
fi

PORT="${SHUIOS_LLAMA_PORT:-8080}"
CTX="${SHUIOS_LLAMA_CTX:-4096}"
THREADS="${SHUIOS_LLAMA_THREADS:-$(nproc 2>/dev/null || echo 2)}"

echo "shuios-llama: 使用模型 $MODEL"
echo "shuios-llama: 监听 127.0.0.1:$PORT（ctx=$CTX threads=$THREADS）"

exec /usr/bin/llama-server \
	-m "$MODEL" \
	--host 127.0.0.1 \
	--port "$PORT" \
	-c "$CTX" \
	-t "$THREADS" \
	--no-warmup
