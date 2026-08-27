import test from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, isAbsolute, join } from 'node:path'
import vm from 'node:vm'

function loadExportsUnderTest() {
  const source = readFileSync(new URL('../lib/index.js', import.meta.url), 'utf8')
  const bundledPathStart = source.indexOf('function bundledRuntimeRelativePath(platform, arch) {')
  const functionStart = source.indexOf('function resolveRuntimeLaunch(config, bundledRuntimeExecutable) {')
  const envStart = source.indexOf('function resolveRuntimeEnv(config) {')
  const promptStart = source.indexOf('const COMPUTER_USE_PROMPT = [')
  const promptEnd = source.indexOf('].join(" ");', promptStart)

  assert.notEqual(bundledPathStart, -1, 'bundledRuntimeRelativePath definition should exist')
  assert.notEqual(functionStart, -1, 'resolveRuntimeLaunch definition should exist')
  assert.notEqual(envStart, -1, 'resolveRuntimeEnv definition should exist')
  assert.notEqual(promptStart, -1, 'COMPUTER_USE_PROMPT definition should exist')
  assert.notEqual(promptEnd, -1, 'COMPUTER_USE_PROMPT terminator should exist')

  const snippet = [
    source.slice(bundledPathStart, promptStart),
    source.slice(promptStart, promptEnd + '].join(" ");'.length),
    'result = { bundledRuntimeRelativePath, resolveBundledRuntimeExecutable, resolveRuntimeLaunch, resolveRuntimeEnv, COMPUTER_USE_PROMPT };',
  ].join('\n')

  const context = { result: undefined, existsSync, isAbsolute, join, process }
  vm.runInNewContext(snippet, context)
  return context.result
}

function loadAccessGateUnderTest() {
  const source = readFileSync(new URL('../lib/index.js', import.meta.url), 'utf8')
  const functionStart = source.indexOf('function isComputerUseTool(toolName) {')
  const functionEnd = source.indexOf('function installUseTracker(ctx, usedAgents) {')

  assert.notEqual(functionStart, -1, 'isComputerUseTool definition should exist')
  assert.notEqual(functionEnd, -1, 'installUseTracker definition should exist')

  const snippet = [
    'const COMPUTER_USE_TOOL_PREFIX = "mcp__computer_use__";',
    source.slice(functionStart, functionEnd),
    'result = { classifyComputerUseAction, installAccessGate };',
  ].join('\n')

  const context = { result: undefined }
  vm.runInNewContext(snippet, context)
  return context.result
}

const {
  bundledRuntimeRelativePath,
  resolveBundledRuntimeExecutable,
  resolveRuntimeLaunch,
  resolveRuntimeEnv,
  COMPUTER_USE_PROMPT,
} = loadExportsUnderTest()

const { classifyComputerUseAction, installAccessGate } = loadAccessGateUnderTest()

function normalizeEnv(env) {
  return JSON.parse(JSON.stringify(env))
}

function normalizeLaunch(launch) {
  return JSON.parse(JSON.stringify(launch))
}

test('resolveRuntimeLaunch uses the integrated native runtime by default', () => {
  assert.deepEqual(normalizeLaunch(resolveRuntimeLaunch({}, 'C:\\pkg\\runtime\\open-computer-use.exe')), {
    command: 'C:\\pkg\\runtime\\open-computer-use.exe',
    args: ['mcp'],
    turnEndedArgv: ['C:\\pkg\\runtime\\open-computer-use.exe', 'turn-ended'],
  })
})

test('resolveRuntimeLaunch accepts an absolute local runtime executable', () => {
  assert.deepEqual(normalizeLaunch(resolveRuntimeLaunch({
    runtimeExecutable: 'D:\\dev\\open-computer-use.exe',
  }, 'C:\\pkg\\runtime\\open-computer-use.exe')), {
    command: 'D:\\dev\\open-computer-use.exe',
    args: ['mcp'],
    turnEndedArgv: ['D:\\dev\\open-computer-use.exe', 'turn-ended'],
  })
})

test('resolveRuntimeLaunch rejects a relative runtime executable path', () => {
  assert.throws(
    () => resolveRuntimeLaunch({ runtimeExecutable: '.\\open-computer-use.exe' }, 'C:\\pkg\\runtime\\open-computer-use.exe'),
    /must be an absolute path/,
  )
})

test('bundledRuntimeRelativePath maps supported Windows architectures', () => {
  assert.equal(bundledRuntimeRelativePath('win32', 'x64'), join('runtime', 'bin', 'win32-x64', 'open-computer-use.exe'))
  assert.equal(bundledRuntimeRelativePath('win32', 'arm64'), join('runtime', 'bin', 'win32-arm64', 'open-computer-use.exe'))
  assert.throws(() => bundledRuntimeRelativePath('linux', 'x64'), /supports Windows only/)
  assert.throws(() => bundledRuntimeRelativePath('win32', 'ia32'), /no integrated Windows runtime/)
})

test('resolveBundledRuntimeExecutable validates the packaged binary', () => {
  const packageRoot = mkdtempSync(join(tmpdir(), 'dsh-computer-use-'))
  try {
    const runtimePath = join(packageRoot, bundledRuntimeRelativePath('win32', 'x64'))
    mkdirSync(dirname(runtimePath), { recursive: true })
    writeFileSync(runtimePath, '')
    assert.equal(resolveBundledRuntimeExecutable(packageRoot, 'win32', 'x64'), runtimePath)
    assert.throws(() => resolveBundledRuntimeExecutable(packageRoot, 'win32', 'arm64'), /integrated runtime is missing/)
  } finally {
    rmSync(packageRoot, { recursive: true, force: true })
  }
})

test('resolveRuntimeEnv enables foreground verification by default', () => {
  assert.deepEqual(normalizeEnv(resolveRuntimeEnv({})), {
    OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS: '1',
    OPEN_COMPUTER_USE_WINDOWS_ALLOW_UIA_TEXT_FALLBACK: '1',
    OPEN_COMPUTER_USE_WINDOWS_ALLOW_APP_LAUNCH: '0',
    OPEN_COMPUTER_USE_WINDOWS_INTERACTION_MODE: 'foreground-verified',
    OPEN_COMPUTER_USE_WINDOWS_VISUAL_INDICATOR: '1',
    OPEN_COMPUTER_USE_WINDOWS_ACTION_LOCK_TIMEOUT_MS: '5000',
  })
})

test('resolveRuntimeEnv keeps unrelated env and lets explicit config win', () => {
  const env = resolveRuntimeEnv({
    env: {
      KEEP_ME: 'yes',
      OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS: '0',
      OPEN_COMPUTER_USE_WINDOWS_ALLOW_UIA_TEXT_FALLBACK: '0',
      OPEN_COMPUTER_USE_WINDOWS_ALLOW_APP_LAUNCH: '0',
      OPEN_COMPUTER_USE_WINDOWS_INTERACTION_MODE: 'background-best-effort',
    },
    interactionMode: 'foreground-verified',
    allowAppLaunch: true,
  })

  assert.equal(env.KEEP_ME, 'yes')
  assert.equal(env.OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS, '1')
  assert.equal(env.OPEN_COMPUTER_USE_WINDOWS_ALLOW_UIA_TEXT_FALLBACK, '1')
  assert.equal(env.OPEN_COMPUTER_USE_WINDOWS_ALLOW_APP_LAUNCH, '1')
  assert.equal(env.OPEN_COMPUTER_USE_WINDOWS_INTERACTION_MODE, 'foreground-verified')
  assert.equal(env.OPEN_COMPUTER_USE_WINDOWS_VISUAL_INDICATOR, '1')
  assert.equal(env.OPEN_COMPUTER_USE_WINDOWS_ACTION_LOCK_TIMEOUT_MS, '5000')
})

test('resolveRuntimeEnv forwards an explicit foreground action lock timeout', () => {
  const env = resolveRuntimeEnv({ actionLockTimeoutMs: 12_345 })
  assert.equal(env.OPEN_COMPUTER_USE_WINDOWS_ACTION_LOCK_TIMEOUT_MS, '12345')
})

test('resolveRuntimeEnv disables focus flags in background mode', () => {
  const env = resolveRuntimeEnv({
    interactionMode: 'background-best-effort',
    allowAppLaunch: false,
  })

  assert.equal(env.OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS, '0')
  assert.equal(env.OPEN_COMPUTER_USE_WINDOWS_ALLOW_UIA_TEXT_FALLBACK, '0')
  assert.equal(env.OPEN_COMPUTER_USE_WINDOWS_ALLOW_APP_LAUNCH, '0')
  assert.equal(env.OPEN_COMPUTER_USE_WINDOWS_INTERACTION_MODE, 'background-best-effort')
  assert.equal(env.OPEN_COMPUTER_USE_WINDOWS_VISUAL_INDICATOR, '1')
})

test('resolveRuntimeEnv can disable the desktop control indicator explicitly', () => {
  const env = resolveRuntimeEnv({ visualIndicator: false })
  assert.equal(env.OPEN_COMPUTER_USE_WINDOWS_VISUAL_INDICATOR, '0')
})

test('COMPUTER_USE_PROMPT preserves v2, fallback, focus, and confirmation guidance', () => {
  assert.match(COMPUTER_USE_PROMPT, /activate_window/)
  assert.match(COMPUTER_USE_PROMPT, /get_window_state/)
  assert.match(COMPUTER_USE_PROMPT, /list_apps/)
  assert.match(COMPUTER_USE_PROMPT, /get_app_state/)
  assert.match(COMPUTER_USE_PROMPT, /refresh state after every action/)
  assert.match(COMPUTER_USE_PROMPT, /latest `observation_id`/)
  assert.match(COMPUTER_USE_PROMPT, /latest `screenshot_id`/)
  assert.match(COMPUTER_USE_PROMPT, /SetFocus/)
  assert.match(COMPUTER_USE_PROMPT, /FocusedElement/)
  assert.match(COMPUTER_USE_PROMPT, /ModalWindows/)
  assert.match(COMPUTER_USE_PROMPT, /modal_window_required/)
  assert.match(COMPUTER_USE_PROMPT, /expected_postcondition/)
  assert.match(COMPUTER_USE_PROMPT, /ActionStatus: unknown/)
  assert.match(COMPUTER_USE_PROMPT, /never blindly retry a side-effecting action/)
  assert.match(COMPUTER_USE_PROMPT, /verify the target window still has focus before typing/)
  assert.match(COMPUTER_USE_PROMPT, /confirmation immediately before the final high-risk action/)
  assert.match(COMPUTER_USE_PROMPT, /re-observe before acting whenever a result is missing, ambiguous, or unknown/)
})

test('Computer Use ownership is released when the owning Agent turn stops', async () => {
  const handlers = new Map()
  const ctx = {
    on(event, handler) {
      handlers.set(event, handler)
    },
    get() {
      return undefined
    },
  }
  const continueDecision = { kind: 'continue' }
  const firstAgent = { session: { id: 'session-a' } }
  const secondAgent = { session: { id: 'session-b' } }

  installAccessGate(ctx, 'allow')

  const preExecute = handlers.get('tools/pre-execute')
  assert.equal(typeof preExecute, 'function')
  assert.equal(typeof handlers.get('agent/turn-stopping'), 'function')

  assert.deepEqual(
    await preExecute(
      { name: 'mcp__computer_use__click', callId: 'call-a', agent: firstAgent, arguments: { action_intent: { kind: 'navigate', summary: 'Open the first window' } } },
      async () => continueDecision,
    ),
    continueDecision,
  )

  handlers.get('agent/turn-stopping')({ agent: firstAgent })

  assert.deepEqual(
    await preExecute(
      { name: 'mcp__computer_use__click', callId: 'call-b', agent: secondAgent, arguments: { action_intent: { kind: 'navigate', summary: 'Open the second window' } } },
      async () => continueDecision,
    ),
    continueDecision,
  )
})

test('Computer Use mutating calls receive stable action identity before dispatch', async () => {
  const handlers = new Map()
  const ctx = {
    on(event, handler) {
      handlers.set(event, handler)
    },
    get() {
      return undefined
    },
  }
  const agent = { session: { id: 'session-a' } }
  installAccessGate(ctx, 'allow')
  const preExecute = handlers.get('tools/pre-execute')
  const call = {
    name: 'mcp__computer_use__type_text',
    callId: 'call-action-1',
    agent,
    arguments: {
      text: 'hello',
      action_intent: { kind: 'edit', summary: 'Type text into the focused editor' },
    },
  }

  assert.deepEqual(await preExecute(call, async () => ({ kind: 'continue' })), { kind: 'continue' })
  assert.equal(call.arguments.action_id, 'call-action-1')
  assert.equal(call.arguments.idempotency_key, 'call-action-1')

  const explicit = {
    name: 'mcp__computer_use__click',
    callId: 'call-action-2',
    agent,
    arguments: {
      action_id: 'logical-action',
      idempotency_key: 'logical-operation',
      action_intent: { kind: 'navigate', summary: 'Open settings' },
    },
  }
  await preExecute(explicit, async () => ({ kind: 'continue' }))
  assert.equal(explicit.arguments.action_id, 'logical-action')
  assert.equal(explicit.arguments.idempotency_key, 'logical-operation')
})

test('Computer Use action risk classification fails closed without a declared intent', () => {
  assert.deepEqual(
    JSON.parse(JSON.stringify(classifyComputerUseAction('mcp__computer_use__get_window_state', {}))),
    { level: 'none' },
  )
  assert.deepEqual(
    JSON.parse(JSON.stringify(classifyComputerUseAction('mcp__computer_use__click', {}))),
    { level: 'unclassified' },
  )
  assert.deepEqual(
    JSON.parse(JSON.stringify(classifyComputerUseAction('mcp__computer_use__click', {
      action_intent: { kind: 'navigate', summary: 'Open settings' },
    }))),
    { level: 'low', kind: 'navigate', summary: 'Open settings' },
  )
  assert.deepEqual(
    JSON.parse(JSON.stringify(classifyComputerUseAction('mcp__computer_use__click', {
      action_intent: { kind: 'send', summary: 'Send the prepared DingTalk message' },
    }))),
    { level: 'high', kind: 'send', summary: 'Send the prepared DingTalk message' },
  )
})

test('high-risk Computer Use actions require an explicit UI confirmation under allow access', async () => {
  const handlers = new Map()
  const questions = []
  const agent = { session: { id: 'session-a' } }
  const ctx = {
    on(event, handler) {
      handlers.set(event, handler)
    },
    get(name) {
      if (name !== 'userQuestions') return undefined
      return {
        async ask(request) {
          questions.push(request)
          return { answers: [{ id: 'confirm_computer_use_action', selected: ['确认执行'] }] }
        },
      }
    },
  }
  installAccessGate(ctx, 'allow', 'confirm')
  const preExecute = handlers.get('tools/pre-execute')
  const continueDecision = { kind: 'continue' }

  assert.deepEqual(
    await preExecute({
      name: 'mcp__computer_use__click',
      callId: 'call-low',
      agent,
      arguments: { action_intent: { kind: 'navigate', summary: 'Open settings' } },
    }, async () => continueDecision),
    continueDecision,
  )
  assert.equal(questions.length, 0)

  assert.deepEqual(
    await preExecute({
      name: 'mcp__computer_use__click',
      callId: 'call-high',
      agent,
      arguments: { action_intent: { kind: 'send', summary: 'Send the prepared DingTalk message' } },
    }, async () => continueDecision),
    continueDecision,
  )
  assert.equal(questions.length, 1)
  assert.match(questions[0].questions[0].detail, /Send the prepared DingTalk message/)
  assert.deepEqual(JSON.parse(JSON.stringify(questions[0].questions[0].intent)), { kind: 'plan-review', approve: '确认执行' })
})

test('high-risk confirmation rejection and missing intent deny before execution', async () => {
  const handlers = new Map()
  const agent = { session: { id: 'session-a' } }
  const ctx = {
    on(event, handler) {
      handlers.set(event, handler)
    },
    get(name) {
      if (name !== 'userQuestions') return undefined
      return {
        async ask() {
          return { answers: [{ id: 'confirm_computer_use_action', selected: ['取消'] }] }
        },
      }
    },
  }
  installAccessGate(ctx, 'allow', 'confirm')
  const preExecute = handlers.get('tools/pre-execute')
  const next = async () => ({ kind: 'continue' })

  const unclassified = await preExecute({ name: 'mcp__computer_use__press_key', callId: 'missing', agent, arguments: {} }, next)
  assert.equal(unclassified.kind, 'deny')
  assert.match(unclassified.reason, /action_intent/)

  const rejected = await preExecute({
    name: 'mcp__computer_use__click',
    callId: 'rejected',
    agent,
    arguments: { action_intent: { kind: 'delete', summary: 'Delete the selected file' } },
  }, next)
  assert.equal(rejected.kind, 'deny')
  assert.match(rejected.reason, /not confirmed/)
})
