import test from "node:test"
import assert from "node:assert/strict"
import { chooseTier, deterministicTier, makePromptHandler } from "../plugin/index.js"

const models = Object.fromEntries(["local", "standard", "advanced", "fallback", "classifier", "file_search"]
  .map(id => [id, { providerID: "test", id }]))

function handler(settings = { enabled: true, models }) {
  const switched = []
  const decisions = []
  let calls = 0
  const ctx = { session: { switchModel: async value => switched.push(value) } }
  return {
    switched, decisions,
    get calls() { return calls },
    run: makePromptHandler(ctx, {
      readSettingsFn: async () => settings,
      layaFn: async () => { calls++; return { local: 0.1, standard: 0.8, advanced: 0.1 } },
      recordFn: async value => decisions.push(value),
    }),
  }
}

test("obvious prompts skip Laya before model selection", async () => {
  const router = handler()
  await router.run({ sessionID: "s1", prompt: { text: "你好" } })
  await router.run({ sessionID: "s1", prompt: { text: "请做安全审计" } })
  assert.equal(router.calls, 0)
  assert.deepEqual(router.switched.map(item => item.model.id), ["local", "advanced"])
  assert.deepEqual(router.decisions.map(item => item.classifier), ["rule", "rule"])
})

test("ambiguous prompt invokes Laya and conservative tier selection", async () => {
  const router = handler()
  await router.run({ sessionID: "s2", prompt: { text: "看看这个组件应该怎么改" } })
  assert.equal(router.calls, 1)
  assert.equal(router.switched[0].model.id, "standard")
  assert.equal(chooseTier("检查这个需求", 0, { local: 0.9, standard: 0.05, advanced: 0.05 }), "local")
  assert.equal(deterministicTier("修复这个应用", 0), null)
})

test("manual directive is removed even when routing is disabled", async () => {
  const router = handler({ enabled: false, models })
  const event = { sessionID: "s3", prompt: { text: "!manual 帮我分析代码" } }
  await router.run(event)
  assert.equal(event.prompt.text, "帮我分析代码")
  assert.equal(router.switched.length, 0)
})

test("local gateway is ready before switching the session model", async () => {
  const originalFetch = globalThis.fetch
  const events = []
  globalThis.fetch = async url => {
    events.push(String(url))
    return { ok: true, json: async () => String(url).endsWith("/control/start")
      ? { model_state: "running" } : { data: [{ id: "qwen-local" }] } }
  }
  try {
    const settings = { enabled: true, models: { ...models, local: { providerID: "local-mlx", id: "qwen-local" } },
      localModel: { providerID: "local-mlx", gatewayURL: "http://127.0.0.1:8787" } }
    const ctx = { session: { switchModel: async () => events.push("switch") } }
    const run = makePromptHandler(ctx, { readSettingsFn: async () => settings,
      layaFn: async () => { throw new Error("Laya must not run") }, recordFn: async () => {} })
    await run({ sessionID: "s4", prompt: { text: "你好" } })
    assert.deepEqual(events, ["http://127.0.0.1:8787/control/start", "http://127.0.0.1:8787/v1/models", "switch"])
  } finally { globalThis.fetch = originalFetch }
})
