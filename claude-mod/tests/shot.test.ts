import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { SERVERS, whatOf } from '../hooks/register'

const HOME = '/Users/me'
const DIR = `${HOME}/Screenshots`

// The world beneath the plugin: a ~/Screenshots folder, a shot MCP server
// that answers with a path, and a process runner that records argv.
// `placed` says whether the surface draws a pane; `panes` records each open and close.
function world(on: On, env: Record<string, string> = {}, { placed = false } = {}) {
  const ran: string[][] = []
  const toasts: string[] = []
  const panes: string[] = []
  mock.env(on, { HOME, ...env })
  on('fs.exists', () => ({ value: true }))
  on('fs.list', () => ({
    value: [
      { name: 'old.png', kind: 'file', size: 10, mtimeMs: 1_000, isLink: false },
      { name: 'notes.txt', kind: 'file', size: 10, mtimeMs: 9_000, isLink: false },
      { name: 'new.png', kind: 'file', size: 10, mtimeMs: 5_000, isLink: false },
    ],
  }))
  on('fs.read', () => ({
    value: JSON.stringify({
      shots: [{ path: `${DIR}/new.png`, description: 'Mux dashboard showing a failed upload', app: 'Google Chrome' }],
    }),
  }))
  on('fs.stat', () => ({ value: { kind: 'file', size: 10, mtimeMs: 7_000, isLink: false } }))
  on('process.run', (_$, e) => {
    ran.push([...e.argv])
    return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('ui.toast', (_$, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  on('ui.open', (_$, e) => {
    panes.push(`open ${e.id}`)
    return { value: placed ? { isPlaced: true } : ({ isPlaced: false, reason: 'narrow' } as never) }
  })
  on('ui.close', (_$, e) => {
    panes.push(`close ${e.id}`)
    return { value: undefined }
  })
  for (const tool of SERVERS.flatMap(s => [`${s}capture`, `${s}compose`])) {
    on('tool.call', { tool }, () => ({
      result: [{ type: 'text', text: '{}' }],
      text: `{"path" : "/tmp/${tool.endsWith('compose') ? 'edited' : 'raw'}.png", "width": 10}`,
    }) as never)
  }
  return { ran, toasts, panes }
}

test('composed mode opens edited images but leaves raw captures for the agent', { options: { auto_open: 'composed' } }, async ($, on) => {
  const { ran, toasts } = world(on)

  await $.tool.call({ tool: 'mcp__shot__capture', mode: 'window' } as never)
  await $.tool.call({ tool: 'mcp__shot__compose', input: '/tmp/raw.png' } as never)

  expect(ran).toEqual([['open', '/tmp/edited.png']])
  expect(toasts).toEqual(['shot: captured raw.png', 'shot: edited edited.png (opened)'])
})

test('captures through the plugin-bundled server are announced too', async ($, on) => {
  const { toasts } = world(on)

  await $.tool.call({ tool: 'mcp__plugin_shot_shot__capture', mode: 'window' } as never)

  expect(toasts).toEqual(['shot: captured raw.png'])
})

test('where no pane is drawn the capture falls back to a plain toast', async ($, on) => {
  const { toasts, panes } = world(on)

  await $.tool.call({ tool: 'mcp__shot__capture', mode: 'window' } as never)

  expect(toasts).toEqual(['shot: captured raw.png'])
  expect(panes).toEqual(['open shot-notice', 'close shot-notice'])
})

test('a capture notice opens that shot when clicked', async ($, on) => {
  const { ran, toasts, panes } = world(on, {}, { placed: true })
  mock.clock(on, { now: 60_000 })
  await $.tool.call({ tool: 'mcp__shot__capture', mode: 'window' } as never)
  expect(toasts).toEqual([])

  const mount = (requestId: string) =>
    $.ui.mount({
      plugin: 'shot',
      surface: 'terminal',
      component: 'Pane',
      requestId,
      props: { title: 'shot', isFocused: false, bodyColumns: 60, placement: 'inline', scroll: { offset: 0, bodyRows: 30 } } as never,
    })

  // Move the selection off the capture first, so the press has to bring it back.
  const history = await mount('shot-history')
  await history.press({ key: `shot:${DIR}/old.png` })
  await history.unmount()

  panes.length = 0
  const notice = await mount('shot-notice')
  expect((await notice.find({ key: 'notice' }))?.text).toBe('shot: captured raw.png  · click to view')
  ran.length = 0
  await notice.press({ key: 'notice' })
  await notice.unmount()
  expect(panes).toEqual(['close shot-notice'])
  expect(ran).toEqual([['open', '/tmp/raw.png']])

  const after = await mount('shot-history')
  expect(await after.find({ type: 'Text', text: 'raw.png' })).toBeDefined()
  await after.unmount()
})

test('an unclicked notice closes itself after four seconds', async ($, on) => {
  const { panes } = world(on, {}, { placed: true })
  const clock = mock.clock(on, { now: 0 })
  await $.tool.call({ tool: 'mcp__shot__capture', mode: 'window' } as never)

  await clock.advance(3_999)
  expect(panes).toEqual(['open shot-notice'])
  await clock.advance(1)
  expect(panes).toEqual(['open shot-notice', 'close shot-notice'])
})

test('auto-open is off by default', async ($, on) => {
  const { ran } = world(on)

  await $.tool.call({ tool: 'mcp__shot__compose', input: '/tmp/raw.png' } as never)

  expect(ran).toEqual([])
})

test('history pane lists pngs newest first and a pressed row opens', async ($, on) => {
  const { ran } = world(on)
  mock.clock(on, { now: 60_000 })
  await $.tool.call({ tool: 'mcp__shot__capture', mode: 'window' } as never)

  for (const surface of ['terminal', 'desktop'] as const) {
    ran.length = 0
    const ui = await $.ui.mount({
      plugin: 'shot',
      surface,
      component: 'Pane',
      requestId: 'shot-history',
      props: { title: 'Screenshots', isFocused: true, bodyColumns: 60, placement: 'dock', scroll: { offset: 0, bodyRows: 30 } } as never,
    })
    const rows = (await ui.findAll({ type: 'Button' }))
      .map(b => b.key)
      .filter(k => k?.startsWith('shot:'))
    // /tmp/raw.png (mtime 7000, outside ~/Screenshots) then new, then old; notes.txt is not a png
    expect(rows).toEqual(['shot:/tmp/raw.png', `shot:${DIR}/new.png`, `shot:${DIR}/old.png`])
    expect((await ui.find({ key: `shot:${DIR}/new.png` }))?.text).toMatch(/^Mux dashboard showing.*…$/)
    expect((await ui.find({ key: `shot:${DIR}/old.png` }))?.text).toContain('old')

    await ui.press({ key: `shot:${DIR}/old.png` })
    expect(ran).toEqual([['open', `${DIR}/old.png`]])
    await ui.press({ key: 'reveal' })
    expect(ran.at(-1)).toEqual(['open', '-R', `${DIR}/old.png`])
    await ui.unmount()
  }
})

test('what a shot shows: description, then app and window, then the filename without its stamp', () => {
  expect(whatOf(`${DIR}/x.png`, { description: 'Slack thread about docs', app: 'Slack' })).toEqual({ what: 'Slack thread about docs', isDescribed: true })
  expect(whatOf(`${DIR}/x.png`, { app: 'Slack', window: 'dx-eng' })).toEqual({ what: 'Slack · dx-eng', isDescribed: false })
  expect(whatOf(`${DIR}/x.png`, { app: 'iTerm', window: '◑ Shot mod' }).what).toBe('iTerm · Shot mod')
  expect(whatOf(`${DIR}/CleanShot 2026-09-11 at 7.45.43 AM@2x.png`).what).toBe('CleanShot capture')
  expect(whatOf(`${DIR}/Shot 2026-10-01 at 3.02.02 PM edited.png`).what).toBe('shot capture, edited')
  expect(whatOf('/tmp/pane-check.png').what).toBe('pane-check')
})

for (const [term, hinted] of [['iTerm.app', true], ['ghostty', false]] as const) {
  test(`in ${term} the pane ${hinted ? 'says why there is no picture' : 'draws the picture'}`, async ($, on) => {
    world(on, { TERM_PROGRAM: term })
    mock.clock(on, { now: 60_000 })
    await $.tool.call({ tool: 'mcp__shot__capture', mode: 'window' } as never)
    const ui = await $.ui.mount({
      plugin: 'shot',
      surface: 'terminal',
      component: 'Pane',
      requestId: 'shot-history',
      props: { title: 'Screenshots', isFocused: true, bodyColumns: 80, placement: 'dock', scroll: { offset: 0, bodyRows: 30 } } as never,
    })
    expect((await ui.find({ text: /outside Ghostty or kitty/ })) !== undefined).toBe(hinted)
    expect((await ui.find({ key: 'preview' })) !== undefined).toBe(!hinted)
    await ui.unmount()
  })
}
