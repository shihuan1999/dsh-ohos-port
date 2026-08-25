// Device-side mock LLM server for dsh (OpenAI-compatible /v1 on 127.0.0.1:8000)
// Usage: node mock-llm.mjs [behavior,behavior,...]  (default: success)
// Env: MOCK_TOOL_NAME / MOCK_TOOL_ARGUMENTS customize the tool_call_success payload.
import { startMockLlmServer } from '/data/dsh/node_modules/@deepseek-ai/dsh-llm-mock-server/lib/index.js'

const sequence = (process.argv[2] || 'success').split(',')
const opts = {
  host: '127.0.0.1',
  port: 8000,
  sequence,
  successText: 'Mock reply from OHOS riscv64 dsh (no external network needed).',
}
if (process.env.MOCK_TOOL_NAME) {
  opts.toolName = process.env.MOCK_TOOL_NAME
  opts.toolArguments = process.env.MOCK_TOOL_ARGUMENTS || '{}'
}
try { opts.repeatLast = true } catch {}
const handle = await startMockLlmServer(opts)
const recorded = handle.requests ?? []
console.log(`mock-llm ready on 127.0.0.1:8000 sequence=[${sequence.join(',')}] tool=${opts.toolName ?? '-'}`)
setInterval(() => {}, 1 << 30)
