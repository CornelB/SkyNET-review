// ABOUTME: Words for a tribunal run's band above the prompt
// ABOUTME: Pure functions over the Bash command that starts or waits on a run, the status.json it writes, and local lens subagents

export type Cell = { lens: string; seat: string; status: string; detail?: string; ended?: string; error?: string }
export type RunStatus = { state: string; pid: number; started: string; total: number; done: number; cells: Cell[]; models?: Record<string, string> }
export type Band = { count: string; bar: string; clock: string; event?: string }
export type Failure = { lens: string; reason: string; error?: string }
export type SeatRow = { seat: string; model: string; state: 'running' | 'ok' | 'failed'; count: string; clock: string; failures: Failure[] }

const LIVE_STATES = new Set(['prepared', 'running'])
const BAR_CELLS = 8

// The run dir a `run-tribunal.sh start` or `wait` names: its last word before
// any shell operator. Other subcommands (discover, cancel, run) and a command
// that only names the script (a grep, a cat) are not followed. Only an
// absolute dir is followed, since the mod has no cwd to resolve one against.
export function tribunalRunDir(command: string): string | undefined {
  const match = /\bbash\s+["']?[^\s"']*run-tribunal\.sh["']?\s+(?:start|wait)\b([^;&|<>\n]*)/.exec(command)
  if (!match) return undefined
  const words = (match[1] ?? '').trim().split(/\s+/)
  // `wait <dir> 2>&1` leaves the redirect's fd number as the last word.
  if (/^\d$/.test(words.at(-1) ?? '')) words.pop()
  const last = words.at(-1)?.replace(/^["']|["']$/g, '')
  return last && last.startsWith('/') ? last.replace(/\/+$/, '') : undefined
}

// status.json as run-tribunal.sh writes it (through a tmp file and a rename,
// so a read never sees half of it). Anything else reads as no status yet.
export function parseStatus(text: string): RunStatus | undefined {
  let raw: unknown
  try {
    raw = JSON.parse(text)
  } catch {
    return undefined
  }
  if (typeof raw !== 'object' || raw === null) return undefined
  const r = raw as Record<string, unknown>
  if (typeof r.state !== 'string' || !Array.isArray(r.cells)) return undefined
  const cells = r.cells.filter((c): c is Cell => typeof c === 'object' && c !== null && typeof c.lens === 'string' && typeof c.seat === 'string' && typeof c.status === 'string')
  return {
    state: r.state,
    pid: typeof r.pid === 'number' ? r.pid : 0,
    started: typeof r.started === 'string' ? r.started : '',
    total: typeof r.cells_total === 'number' ? r.cells_total : cells.length,
    done: typeof r.cells_done === 'number' ? r.cells_done : cells.filter(c => c.status !== 'running').length,
    cells,
    models: seatModels(r),
  }
}

const text = (v: unknown): string => (typeof v === 'string' ? v : '')

// The model each seat runs: codex and claude-cli from the rule the run
// applied, any other seat from the first part of what discover said of it.
function seatModels(r: Record<string, unknown>): Record<string, string> {
  const models: Record<string, string> = {}
  const info = typeof r.seat_info === 'object' && r.seat_info !== null ? (r.seat_info as Record<string, unknown>) : {}
  for (const [seat, said] of Object.entries(info)) models[seat] = text(said).split(',')[0]?.trim() ?? ''
  const pinned = (model: unknown, effort: unknown) => [text(model), text(effort)].filter(Boolean).join(' ')
  if (models.codex !== undefined && text(r.codex_model)) models.codex = pinned(r.codex_model, r.codex_effort)
  if (models['claude-cli'] !== undefined && text(r.claude_model)) models['claude-cli'] = pinned(r.claude_model, r.claude_effort)
  return models
}

// One row per tribunal seat, in the order its cells come: live while any of
// its lenses runs, failed once one ended without a valid report. Its clock
// counts from the run's start to its last lens ending.
export function seatRows(status: RunStatus, followedSinceMs: number, nowMs: number): SeatRow[] {
  const startedMs = Date.parse(status.started)
  const fromMs = Number.isNaN(startedMs) ? followedSinceMs : startedMs
  const bySeat = new Map<string, Cell[]>()
  for (const c of status.cells) if (c.seat !== 'local') bySeat.set(c.seat, [...(bySeat.get(c.seat) ?? []), c])
  return [...bySeat].map(([seat, cells]) => {
    const done = cells.filter(c => c.status !== 'running')
    const failed = done.filter(c => c.status !== 'ok')
    const state = done.length < cells.length ? 'running' : failed.length > 0 ? 'failed' : 'ok'
    const endedMs = Math.max(...done.map(c => Date.parse(c.ended ?? '')).filter(ms => !Number.isNaN(ms)))
    const toMs = state === 'running' || !Number.isFinite(endedMs) ? nowMs : endedMs
    return {
      seat,
      model: status.models?.[seat] ?? '',
      state,
      count: `${done.length} of ${cells.length}`,
      clock: clock(fromMs, toMs),
      failures: failed.map(c => ({ lens: c.lens, reason: `${c.status}${c.detail ? `: ${c.detail}` : ''}`, ...(c.error ? { error: c.error } : {}) })),
    }
  })
}

// The lens a local-mode subagent reviews for, from the agent type it was
// spawned as (`review-board:security-reviewer`); undefined for any other agent.
export function lensOf(subagentType: string): string | undefined {
  return /^review-board:([a-z]+)-reviewer$/.exec(subagentType)?.[1]
}

// A local run as the band reads a tribunal's status.json: one cell per lens
// subagent, seat `local`, live while any of them still runs.
export function localStatus(cells: Cell[], started: string): RunStatus {
  const done = cells.filter(c => c.status !== 'running').length
  return { state: done < cells.length ? 'running' : 'done', pid: 0, started, total: cells.length, done, cells: cells.map(c => ({ ...c })) }
}

export function isLive(status: RunStatus): boolean {
  return LIVE_STATES.has(status.state)
}

// The newest cell to finish between two reads, as `security · codex ok`. The
// first read has nothing to compare with, so it names no event.
export function latestEvent(before: Cell[] | undefined, now: Cell[]): string | undefined {
  if (!before) return undefined
  const was = new Map(before.map(c => [`${c.lens}.${c.seat}`, c.status]))
  const ended = now.filter(c => c.status !== 'running' && was.get(`${c.lens}.${c.seat}`) === 'running')
  const last = ended.at(-1)
  return last ? `${last.lens} · ${last.seat} ${last.status}` : undefined
}

// m:ss, or h:mm:ss past the hour, since the run's own start time.
export function clock(startedMs: number, nowMs: number): string {
  const secs = Math.max(0, Math.floor((nowMs - startedMs) / 1000))
  const hours = Math.floor(secs / 3600)
  const mins = Math.floor((secs % 3600) / 60)
  const ss = String(secs % 60).padStart(2, '0')
  return hours > 0 ? `${hours}:${String(mins).padStart(2, '0')}:${ss}` : `${mins}:${ss}`
}

// The line rounds down, so it never reads full while a cell is still out.
export function band(status: RunStatus, followedSinceMs: number, nowMs: number, event?: string): Band {
  const filled = status.total > 0 ? Math.floor((status.done / status.total) * BAR_CELLS) : 0
  const startedMs = Date.parse(status.started)
  return {
    count: `${status.done} of ${status.total}`,
    bar: '━'.repeat(filled) + '─'.repeat(BAR_CELLS - filled),
    clock: clock(Number.isNaN(startedMs) ? followedSinceMs : startedMs, nowMs),
    ...(event ? { event } : {}),
  }
}

// What the band says once the run has ended. A seat that timed out or wrote
// no valid report counts as done, not as ok.
export function finishNotice(status: RunStatus): { text: string; isFailure: boolean } {
  const ok = status.cells.filter(c => c.status === 'ok').length
  const notOk = status.done - ok
  const tally = `${ok} of ${status.total} reports ok${notOk > 0 ? `, ${notOk} failed` : ''}`
  if (status.state === 'done') return { text: `finished: ${tally}`, isFailure: false }
  return { text: `${status.state}: ${tally}`, isFailure: true }
}

export function abandonedNotice(status: RunStatus | undefined): string {
  return status ? `stopped before it finished: ${status.done} of ${status.total} done` : 'stopped before it wrote any status'
}
