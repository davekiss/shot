import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'
import type { Engine } from 'claude-code/testing'

import { TOOLS, hintTail, whatOf } from '../hooks/register'

const HOME = '/Users/me'
const DIR = `${HOME}/Screenshots`

// The world beneath the plugin: a ~/Screenshots folder, a shot MCP server
// that answers with a path, and a process runner that records argv.
// `placed` says whether the surface draws a pane; `panes` records each open and close.
function world(on: On, env: Record<string, string> = {}, { placed = false, captures = ['raw'] } = {}) {
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
  // Each capture answers with the next name in `captures`, the last repeating.
  let shot = 0
  const answer = (name: string) => ({ result: [{ type: 'text', text: '{}' }], text: `{"path" : "/tmp/${name}.png", "width": 10}` }) as never
  on('tool.call', { tool: TOOLS.capture }, () => answer(captures[Math.min(shot++, captures.length - 1)] ?? 'raw'))
  on('tool.call', { tool: TOOLS.compose }, () => answer('edited'))
  // The engine's own band and hint, for when the strip steps aside.
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => {
    const { Box } = $.ui.resolve(e)
    return <Box key="engine" />
  })
  return { ran, toasts, panes }
}

// The strip above the prompt, drawn the way the engine would raise it.
const strip = ($: Engine, surface: 'terminal' | 'desktop' = 'terminal') =>
  $.ui.mount({
    plugin: 'shot',
    surface,
    component: 'AbovePrompt',
    props: { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 140, scroll: { offset: 0, bodyRows: 10 }, view: {} } as never,
  })

const chips = async (ui: Awaited<ReturnType<typeof strip>>) =>
  (await ui.findAll({ type: 'Button' })).map(b => b.key).filter(k => k?.startsWith('recent:'))

test('composed mode opens edited images but leaves raw captures for the agent', { options: { auto_open: 'composed' } }, async ($, on) => {
  const { ran } = world(on)

  await $.tool.call({ tool: 'mcp__shot__capture', mode: 'window' } as never)
  await $.tool.call({ tool: 'mcp__shot__compose', input: '/tmp/raw.png' } as never)

  expect(ran).toEqual([['open', '/tmp/edited.png']])
})

test('new shots land on the strip newest first, and a pressed chip opens that shot', async ($, on) => {
  const { ran } = world(on)
  mock.clock(on, { now: 60_000 })
  await $.tool.call({ tool: 'mcp__plugin_shot_shot__capture', mode: 'window' } as never)
  await $.tool.call({ tool: 'mcp__shot__compose', input: '/tmp/raw.png' } as never)

  for (const surface of ['terminal', 'desktop'] as const) {
    ran.length = 0
    const ui = await strip($, surface)
    expect(await chips(ui)).toEqual(['recent:/tmp/edited.png', 'recent:/tmp/raw.png'])
    await ui.press({ key: 'recent:/tmp/raw.png' })
    expect(ran).toEqual([['open', '/tmp/raw.png']])
    await ui.unmount()
  }
})

test('the strip keeps the last three shots', async ($, on) => {
  world(on, {}, { captures: ['a', 'b', 'c', 'd'] })
  mock.clock(on, { now: 60_000 })
  for (let i = 0; i < 4; i++) await $.tool.call({ tool: 'mcp__shot__capture', mode: 'window' } as never)
  const ui = await strip($)
  expect(await chips(ui)).toEqual(['recent:/tmp/d.png', 'recent:/tmp/c.png', 'recent:/tmp/b.png'])
  await ui.unmount()
})

test('dismissing the strip leaves it gone until the next shot brings it back', async ($, on) => {
  world(on)
  mock.clock(on, { now: 60_000 })
  await $.tool.call({ tool: 'mcp__shot__capture', mode: 'window' } as never)
  const ui = await strip($)
  await ui.press({ key: 'recent-hide' })
  await ui.unmount()

  const hidden = await strip($)
  expect(await chips(hidden)).toEqual([])
  await hidden.unmount()

  await $.tool.call({ tool: 'mcp__shot__compose', input: '/tmp/raw.png' } as never)
  const back = await strip($)
  expect(await chips(back)).toEqual(['recent:/tmp/edited.png', 'recent:/tmp/raw.png'])
  await back.unmount()
})

test('the hint reminder counts recent shots and fades after half an hour', () => {
  const minute = 60_000
  const list = [{ path: '/tmp/b.png', verb: 'edited' as const, at: 50 * minute }, { path: '/tmp/a.png', verb: 'captured' as const, at: 10 * minute }]
  expect(hintTail(list, 52 * minute)).toBe('▣ 1 new shot · /shot history')
  expect(hintTail(list, 30 * minute)).toBe('▣ 2 new shots · /shot history')
  expect(hintTail(list, 90 * minute)).toBeUndefined()
  expect(hintTail([], 0)).toBeUndefined()
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
