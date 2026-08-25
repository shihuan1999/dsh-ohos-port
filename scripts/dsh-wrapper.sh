#!/system/bin/sh
# dsh (DeepSeek Harness) root-agent wrapper for OHOS riscv64
export HOME=/data/dsh/home
export DSH_HOME=/data/dsh/home
export TMPDIR=/data/dsh/tmp
export LD_LIBRARY_PATH=/data/dsh/lib
export PATH=/data/dsh/bin:/bin:/sbin:/system/bin:$PATH
# LLM endpoint: on-device mock (127.0.0.1:8000) by default; point to a PC relay when a real key is used
export DEEPSEEK_BASE_URL=${DEEPSEEK_BASE_URL:-http://127.0.0.1:8000}
export DEEPSEEK_API_KEY=${DEEPSEEK_API_KEY:-mock-key}
exec /data/dsh/bin/node --expose-internals /data/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js "$@"
