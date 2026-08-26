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

const {
  bundledRuntimeRelativePath,
  resolveBundledRuntimeExecutable,
  resolveRuntimeLaunch,
  resolveRuntimeEnv,
  COMPUTER_USE_PROMPT,
} = loadExportsUnderTest()

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
})

test('COMPUTER_USE_PROMPT preserves v2, fallback, focus, and confirmation guidance', () => {
  assert.match(COMPUTER_USE_PROMPT, /activate_window/)
  assert.match(COMPUTER_USE_PROMPT, /get_window_state/)
  assert.match(COMPUTER_USE_PROMPT, /list_apps/)
  assert.match(COMPUTER_USE_PROMPT, /get_app_state/)
  assert.match(COMPUTER_USE_PROMPT, /refresh state after every action/)
  assert.match(COMPUTER_USE_PROMPT, /latest `observation_id`/)
  assert.match(COMPUTER_USE_PROMPT, /latest `screenshot_id`/)
  assert.match(COMPUTER_USE_PROMPT, /verify the target window still has focus before typing/)
  assert.match(COMPUTER_USE_PROMPT, /confirmation immediately before the final high-risk action/)
  assert.match(COMPUTER_USE_PROMPT, /re-observe before acting whenever a result is missing, ambiguous, or unknown/)
})
