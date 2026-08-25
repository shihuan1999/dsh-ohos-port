#!/system/bin/sh
# dsh root-agent stack launcher for OHOS riscv64
#   mock LLM (127.0.0.1:8000) + dsh web UI (127.0.0.1:3180)
# Env overrides: MOCK_SEQ, MOCK_TOOL_NAME, MOCK_TOOL_ARGUMENTS, DSH_PORT, START_WEB
export HOME=/data/dsh/home
export DSH_HOME=/data/dsh/home
export TMPDIR=/data/dsh/tmp
export LD_LIBRARY_PATH=/data/dsh/lib

pkill -9 node 2>/dev/null
sleep 1
cd /data/dsh/home

MOCK_TOOL_NAME="${MOCK_TOOL_NAME:-}" MOCK_TOOL_ARGUMENTS="${MOCK_TOOL_ARGUMENTS:-}" \
  nohup /data/dsh/bin/node /data/dsh/bin/mock-llm.mjs "${MOCK_SEQ:-success}" \
  > /data/dsh/home/mock.log 2>&1 < /dev/null &

if [ "${START_WEB:-1}" = "1" ]; then
  nohup /data/dsh/bin/dsh --profile web --host 127.0.0.1 --port "${DSH_PORT:-3180}" \
    > /data/dsh/home/web.log 2>&1 < /dev/null &
fi
sleep 4
echo "mock: $(tail -1 /data/dsh/home/mock.log 2>/dev/null)"
echo "web:  $(tail -1 /data/dsh/home/web.log 2>/dev/null)"
netstat -tln 2>/dev/null | grep -E '8000|3180'
