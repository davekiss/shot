import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, ToolCallResult } from 'claude-code'

import type { Shot } from '../types'

const PANE = 'shot-history'
export const SERVERS = ['mcp__shot__', 'mcp__plugin_shot_shot__'] as const
const NOTICE = 'shot-notice'
const NOTICE_MS = 4000
const MODES = ['off', 'composed', 'all'] as const
type AutoOpen = (typeof MODES)[number]

const shots = atom({ plugin: 'shot', key: 'shots' } as const, [])
const selected = atom({ plugin: 'shot', key: 'selected' } as const, null)
const notice = atom({ plugin: 'shot', key: 'notice' } as const, null)
let noticeTimer: { cancel: () => void } | undefined

const TERMINAL_APPS: Record<string, string> = {
  'iTerm.app': 'iTerm',
  Apple_Terminal: 'Terminal',
  ghostty: 'Ghostty',
  WezTerm: 'WezTerm',
  vscode: 'Code',
}

export const pathFromResult = (text: string | undefined): string | undefined =>
  text?.match(/"path"\s*:\s*"((?:[^"\\]|\\.)+)"/)?.[1]?.replace(/\\\//g, '/')

export const shouldOpen = (mode: AutoOpen, tool: 'capture' | 'compose') =>
  mode === 'all' || (mode === 'composed' && tool === 'compose')

const RED = '#E4312B'
const MONTHS = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC']
const pad2 = (n: number) => String(n).padStart(2, '0')

export const clockTime = (ms: number) => {
  const d = new Date(ms)
  return `${pad2(d.getHours())}:${pad2(d.getMinutes())}`
}

export const dayLabel = (ms: number, now: number) => {
  const d = new Date(ms)
  const today = new Date(now)
  const yesterday = new Date(now - 86_400_000)
  if (d.toDateString() === today.toDateString()) return 'TODAY'
  if (d.toDateString() === yesterday.toDateString()) return 'YEST'
  return `${MONTHS[d.getMonth()]} ${d.getDate()}${d.getFullYear() === today.getFullYear() ? '' : ` '${String(d.getFullYear()).slice(2)}`}`
}

type IndexRecord = { path?: string; description?: string; app?: string; window?: string; mtime?: number; bytes?: number }

// One line on what a screenshot shows: the description shot's index holds
// (an agent's or the describer's), else the app and window it was taken from,
// else what its filename says once the timestamp the row already shows is gone.
export const whatOf = (path: string, rec?: IndexRecord): { what: string; isDescribed: boolean } => {
  if (rec?.description) return { what: rec.description, isDescribed: true }
  // Older records keep the status glyph an app put before its title ("◐ Shot mod").
  const window = rec?.window?.replace(/^[\p{So}\p{Sm}\s]+/u, '')
  if (rec?.app) return { what: window ? `${rec.app} · ${window}` : rec.app, isDescribed: false }
  const file = path.split('/').pop() ?? path
  const stamped = file.match(/^(Shot|CleanShot|Screenshot) \d{4}-\d{2}-\d{2} at [\d.]+ ?(?:AM|PM)?(?:@\dx)?(.*)\.png$/i)
  if (stamped) {
    const app = stamped[1] === 'Shot' ? 'shot' : stamped[1] ?? ''
    const rest = (stamped[2] ?? '').trim()
    return { what: rest === '' ? `${app} capture` : `${app} capture, ${rest}`, isDescribed: false }
  }
  return { what: file.replace(/\.png$/i, ''), isDescribed: false }
}

const fit = (text: string, width: number) =>
  text.length <= width ? text.padEnd(width) : `${text.slice(0, Math.max(1, width - 1))}…`

export const bytes = (n: number) =>
  n >= 1_048_576 ? `${(n / 1_048_576).toFixed(1)} MB` : `${Math.max(1, Math.round(n / 1024))} KB`

export const folder = (path: string, root: string) => {
  const dir = path.slice(0, path.lastIndexOf('/'))
  return dir === root ? '~/Screenshots' : dir.replace(root.replace(/\/Screenshots$/, ''), '~')
}

async function home($: EngineInterface) {
  return (await $.env.get('HOME')) ?? ''
}

async function binary($: EngineInterface, configured: unknown) {
  // The plugin's own launcher finds a local build, a shot on PATH, or downloads the release.
  if (!configured) return `${$.plugin.root}/bin/shot`
  return String(configured).replace(/^~/, await home($))
}

async function readIndex($: EngineInterface, root: string): Promise<Map<string, IndexRecord>> {
  try {
    const raw = JSON.parse(await $.fs.read(`${root}/.shot-index.json`)) as { shots?: IndexRecord[] }
    return new Map((raw.shots ?? []).filter(r => r.path).map(r => [r.path as string, r]))
  } catch {
    return new Map()
  }
}

// Reads ~/Screenshots from disk, so shots taken by any agent or app show up,
// plus every file shot's index knows elsewhere (an agent's scratch captures).
// Descriptions come from that index, which shot keeps.
async function refresh($: EngineInterface, extra?: string) {
  const root = `${await home($)}/Screenshots`
  const index = await readIndex($, root)
  const entries = (await $.fs.exists(root)) ? await $.fs.list(root) : []
  const shot = (path: string, mtimeMs: number, size: number): Shot => ({
    path, name: path.split('/').pop() ?? path, mtimeMs, size, ...whatOf(path, index.get(path)),
  })
  const onDisk = entries
    .filter(f => f.kind === 'file' && /\.png$/i.test(f.name) && !f.name.startsWith('.'))
    .map(f => shot(`${root}/${f.name}`, f.mtimeMs, f.size))
  const elsewhere = [...index.values()]
    .filter(r => r.path !== undefined && !r.path.startsWith(`${root}/`))
    .map(r => shot(r.path as string, (r.mtime ?? 0) * 1000, r.bytes ?? 0))
  if (extra !== undefined && !extra.startsWith(`${root}/`) && !elsewhere.some(s => s.path === extra)) {
    const stat = await $.fs.stat(extra)
    elsewhere.push(shot(extra, stat.mtimeMs, stat.size))
  }
  const next = [...onDisk, ...elsewhere].sort((a, b) => b.mtimeMs - a.mtimeMs).slice(0, 200)
  await update($, shots, prev =>
    prev.length === next.length &&
    prev.every((s, i) => s.path === next[i]?.path && s.mtimeMs === next[i]?.mtimeMs && s.what === next[i]?.what)
      ? prev
      : next,
  )
}

async function open($: EngineInterface, path: string, reveal = false) {
  return $.process.run(reveal ? ['open', '-R', path] : ['open', path])
}

async function openPane($: EngineInterface) {
  return $.ui.open({ id: PANE, title: 'Screenshots', focus: true })
}

// A toast takes no press (a click only dismisses it), so a capture announces
// itself in a one-row pane whose whole line opens the shot in Preview. It
// closes itself as a toast would, and is a plain toast where no pane is drawn.
async function announce($: EngineInterface, path: string, text: string) {
  await update($, notice, () => ({ path, text }))
  noticeTimer?.cancel()
  const placed = await $.ui.open({ id: NOTICE, title: 'shot', rows: 1 })
  if (!placed.isPlaced) {
    await $.ui.close({ id: NOTICE })
    $.ui.toast(text)
    return
  }
  noticeTimer = $.clock.after(NOTICE_MS, () => void $.ui.close({ id: NOTICE }))
}

// Every capture or compose call, from any session's model, lands in the
// history; the toast is transient and auto-open follows the setting.
async function afterShotTool<R extends ToolCallResult>(
  $: EngineInterface,
  ran: R,
  tool: 'capture' | 'compose',
  mode: AutoOpen,
): Promise<R> {
  const path = ran.deny === undefined && ran.isError !== true ? pathFromResult(ran.text) : undefined
  if (path === undefined) return ran

  await refresh($, path)
  await update($, selected, () => path)
  const opened = shouldOpen(mode, tool)
  if (opened) await open($, path)
  await announce($, path, `shot: ${tool === 'compose' ? 'edited' : 'captured'} ${path.split('/').pop()}${opened ? ' (opened)' : ''}`)

  return ran
}

export const register: Register = (on, options) => {
  const mode = (MODES as readonly string[]).includes(String(options.auto_open))
    ? (options.auto_open as AutoOpen)
    : 'off'

  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'shot',
      description: 'Capture this terminal window with shot (/shot screen for the display, /shot history for the pane)',
    })
    await refresh($)
    $.clock.every(10_000, () => refresh($))

    return next(e)
  })

  on('command.run', { command: 'shot' }, async ($, e) => {
    const arg = e.args.trim()
    if (arg === 'history' || arg === 'list') {
      await refresh($)
      await openPane($)
      return { text: 'Screenshot history opened.' }
    }

    const term = (await $.env.get('TERM_PROGRAM')) ?? ''
    const request =
      arg === 'screen'
        ? { mode: 'screen', preview: false }
        : { mode: 'window', preview: false, ...(TERMINAL_APPS[term] ? { app: TERMINAL_APPS[term] } : {}) }
    const ran = await $.process.run([await binary($, options.binary), 'capture', JSON.stringify(request)])
    const path = pathFromResult(ran.stdout)
    if (ran.exitCode !== 0 || path === undefined) {
      return { text: `shot failed: ${(ran.stderr || ran.stdout).trim().slice(0, 300)}` }
    }

    await refresh($, path)
    await update($, selected, () => path)
    if (shouldOpen(mode, 'capture')) await open($, path)
    await announce($, path, `shot: captured ${path.split('/').pop()}`)

    return { text: `Saved ${path}` }
  })

  // The server is mcp__shot__ when added with `claude mcp add`, and
  // mcp__plugin_shot_shot__ when it comes bundled with this plugin.
  for (const server of SERVERS) {
    for (const tool of ['capture', 'compose'] as const) {
      on('tool.call', { tool: `${server}${tool}` }, async ($, e, next) => afterShotTool($, await next(e), tool, mode))
    }
  }

  // Arrows and Tab walk the rows: the ring landing on a row selects it, and a
  // click or Enter on a row opens it.
  on('ui.focus', { requestId: PANE }, async ($, e, next) => {
    if (e.element?.startsWith('shot:')) await update($, selected, () => e.element?.slice(5) ?? null)
    return next(e)
  })

  on('ui.render', { component: 'Pane', requestId: NOTICE }, async ($, e) => {
    const { Box, Button } = $.ui.resolve(e)
    const shown = await read($, notice)
    if (shown === null) return <Box />
    return (
      <Box>
        <Button
          key="notice"
          plain
          label={`${shown.text}  · click to view`}
          onPress={async () => {
            noticeTimer?.cancel()
            await update($, selected, () => shown.path)
            await $.ui.close({ id: NOTICE })
            await open($, shown.path)
          }}
        />
      </Box>
    )
  })

  // Swiss: one grid, flush left, weight and space for hierarchy, a single red
  // accent for the one thing that is selected, hairline rules between zones.
  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    const list = await read($, shots)
    const current = (await read($, selected)) ?? list[0]?.path ?? null
    const now = await $.clock.now()
    const root = `${await home($)}/Screenshots`
    const width = Math.max(24, e.props.bodyColumns)
    // The pane's own body height, minus header 2, column heads 1, list margins 2,
    // detail 11 (three lines of description), slack 2.
    const rows = Math.max(4, ((e.props.scroll as { bodyRows?: number } | undefined)?.bodyRows ?? 30) - 18)
    // Image draws only where the terminal speaks kitty graphics; elsewhere it
    // would be a blank box stealing rows from the list.
    const term = `${(await $.env.get('TERM_PROGRAM')) ?? ''} ${(await $.env.get('TERM')) ?? ''}`
    const preview = e.surface === 'terminal' && current !== null && /ghostty|kitty/i.test(term)
    const listRows = preview ? Math.max(4, Math.floor(rows / 2)) : rows
    const index = Math.max(0, list.findIndex(s => s.path === current))
    const start = Math.max(0, Math.min(index - Math.floor(listRows / 2), list.length - listRows))
    const shown = list.slice(start, start + listRows)
    const shot = list[index]
    const nextMode: AutoOpen = MODES[(MODES.indexOf(mode) + 1) % MODES.length] ?? 'off'
    const pick = (path: string) => update($, selected, () => path)
    // j/k carry the focus ring with the selection, so Enter opens what is shown.
    const step = async (by: number) => {
      const s = list[index + by]
      if (s === undefined) return
      await pick(s.path)
      await $.ui.focus({ requestId: PANE, key: `shot:${s.path}` })
    }
    const rule = <Text dimColor>{'─'.repeat(Math.max(1, width - 1))}</Text>

    // Ledger grid: date · gap 2 · marker 2 · time 5 · gap 2 · what · gap 2 · size 6.
    // The date hangs in its own column on a day's first row only, so days cost
    // no extra lines; what a shot shows is the widest column, because it is the
    // one people (and agents) read.
    const days = shown.map(s => dayLabel(s.mtimeMs, now))
    const dateWidth = Math.max(5, ...days.map(d => d.length))
    const whatWidth = Math.max(8, width - 1 - (dateWidth + 2) - 2 - 5 - 2 - 2 - 6)
    const heads = (
      <Box>
        <Text dimColor>
          {' '.repeat(dateWidth + 4)}
          {'TIME'.padEnd(7)}
          {fit('WHAT', whatWidth)}
          {'  '}
          {'SIZE'.padStart(6)}
        </Text>
      </Box>
    )
    const body = shown.map((s, i) => {
      const isOn = s.path === current
      const day = days[i] ?? ''
      return (
        <Box key={`row:${s.path}`}>
          <Text bold>{(day === days[i - 1] ? '' : day).padEnd(dateWidth + 2)}</Text>
          <Text color={RED}>{isOn ? '▌ ' : '  '}</Text>
          <Text color={isOn ? RED : undefined} dimColor={!isOn} bold={isOn}>
            {clockTime(s.mtimeMs)}
          </Text>
          <Text>{'  '}</Text>
          <Button
            key={`shot:${s.path}`}
            plain
            dimColor={!isOn || !s.isDescribed}
            label={fit(s.what, whatWidth)}
            {...(isOn ? { autoFocus: true as const } : {})}
            onPress={async () => {
              await pick(s.path)
              await open($, s.path)
            }}
          />
          <Text dimColor>{'  '}{bytes(s.size).padStart(6)}</Text>
        </Box>
      )
    })

    return (
      <Box flexDirection="column">
        <Box>
          <Text bold>SCREENSHOTS  </Text>
          <Text color={RED} bold>
            {String(list.length)}
          </Text>
        </Box>
        {rule}
        {list.length === 0 ? (
          <Box flexDirection="column" marginY={1}>
            <Text>Nothing here yet.</Text>
            <Text dimColor>/shot captures this window into ~/Screenshots.</Text>
          </Box>
        ) : (
          <Box flexDirection="column" marginY={1}>
            {heads}
            {body}
          </Box>
        )}
        {shot !== undefined && (
          <Box flexDirection="column">
            {rule}
            <Box marginTop={1} height={3} overflow="hidden">
              {shot.isDescribed ? (
                <Text wrap="wrap">{shot.what}</Text>
              ) : (
                <Text dimColor wrap="wrap">
                  {shot.what}. No description yet: shot's describer or the agent that took it adds one.
                </Text>
              )}
            </Box>
            <Box marginTop={1}>
              <Text bold wrap="truncate-middle">
                {shot.name}
              </Text>
            </Box>
            <Box gap={2}>
              <Box flexShrink={0} gap={2}>
                <Text dimColor>SIZE</Text>
                <Text>{bytes(shot.size)}</Text>
                <Text dimColor>IN</Text>
              </Box>
              <Text wrap="truncate-start">{folder(shot.path, root)}</Text>
            </Box>
            <Box marginTop={1} gap={3}>
              <Button key="open" hotkey="o" plain label="open" onPress={() => open($, shot.path)} />
              <Button key="reveal" hotkey="r" plain label="reveal" onPress={() => open($, shot.path, true)} />
              <Button
                key="copy"
                hotkey="c"
                plain
                label="copy path"
                onPress={async () => {
                  await $.ui.copy({ text: shot.path, surface: e.surface })
                  $.ui.toast('shot: path copied')
                }}
              />
              <Button key="prev" hotkey="k" plain label="up" onPress={() => step(-1)} />
              <Button key="next" hotkey="j" plain label="down" onPress={() => step(1)} />
            </Box>
            <Box marginTop={1} gap={3}>
              <Button
                key="auto-open"
                hotkey="a"
                plain
                dimColor
                label={`auto-open ${mode}`}
                onPress={() => $.config.set({ key: 'shot.auto_open', value: nextMode })}
              />
              {e.surface === 'terminal' && !preview && (
                <Text key="no-preview" dimColor wrap="truncate-end">
                  no inline preview outside Ghostty or kitty
                </Text>
              )}
            </Box>
          </Box>
        )}
        {preview && e.surface === 'terminal' && shot !== undefined && (() => {
          const { Image } = $.ui.resolve(e)
          return (
            <Box marginTop={1}>
              <Image
                key="preview"
                source={{ file: shot.path, format: 'png', generation: Math.floor(shot.mtimeMs) }}
                columns={Math.min(255, width)}
                rows={Math.min(255, Math.max(1, rows - listRows))}
                alt=" "
              />
            </Box>
          )
        })()}
      </Box>
    )
  })
}
