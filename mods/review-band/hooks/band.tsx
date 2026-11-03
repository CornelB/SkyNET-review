// ABOUTME: Hooks module that draws a live review run's progress in a band above the prompt
// ABOUTME: Follows a tribunal's status.json, or the local lens subagents through their spawn and turn end
import type { Elements, EngineInterface, Register, Timer } from 'claude-code'
import { abandonedNotice, band, finishNotice, isLive, latestEvent, lensOf, localStatus, parseStatus, tribunalRunDir, type Cell, type RunStatus } from './progress'

const POLL_MS = 1000
const PID_CHECK_MS = 5000
// A run that never writes status.json (start refused, zero seats) is let go.
const NO_STATUS_MS = 60_000
const FINISH_NOTICE_MS = 20_000

// Theme keys follow the person's theme; the chip fill is fixed so its white
// letters keep their contrast on light and dark alike (claude-council's values).
const COLOR = { accent: 'claude', success: 'success', danger: 'error', warning: 'warning', onFill: 'white' } as const
const FILL = { chip: 'rgb(180,85,50)', chipMark: 'rgb(150,68,40)' } as const

// A tribunal is followed by its run dir; a local run has no files, only its
// lens subagents, keyed by agent id.
type Source = { runDir: string } | { agents: Map<string, Cell>; started: string }
type Follow = { source: Source; sinceMs: number; status?: RunStatus; event?: string; pidCheckedAtMs: number }
type Notice = { text: string; isFailure: boolean; untilMs: number }
type BandState = { run?: Follow; finished?: Notice; ended: Set<string>; timer?: Timer; nowMs: number }

async function readStatus($: EngineInterface, runDir: string): Promise<RunStatus | undefined> {
  const path = `${runDir}/status.json`
  if (!(await $.fs.exists(path))) return undefined
  return parseStatus(await $.fs.read(path))
}

// A subagent that fails or is killed may end no turn, and one the engine has
// dropped from its list is over: either counts as a failed lens.
async function readLocal($: EngineInterface, state: BandState, run: Follow, agents: Map<string, Cell>, started: string): Promise<RunStatus> {
  if (state.nowMs - run.pidCheckedAtMs >= PID_CHECK_MS) {
    run.pidCheckedAtMs = state.nowMs
    const listed = new Map((await $.agent.list()).map(a => [a.id, a.status]))
    for (const [id, cell] of agents) {
      const now = listed.get(id)
      if (cell.status === 'running' && (now === undefined || now === 'completed' || now === 'failed' || now === 'killed')) {
        cell.status = now === 'completed' ? 'ok' : 'failed'
      }
    }
  }
  return localStatus([...agents.values()], started)
}

function end(state: BandState, run: Follow, text: string, isFailure: boolean): void {
  if ('runDir' in run.source) state.ended.add(run.source.runDir)
  state.run = undefined
  state.finished = { text, isFailure, untilMs: state.nowMs + FINISH_NOTICE_MS }
}

async function poll($: EngineInterface, state: BandState): Promise<void> {
  state.nowMs = await $.clock.now()
  if (state.finished && state.nowMs >= state.finished.untilMs) state.finished = undefined
  const run = state.run
  if (run) {
    const source = run.source
    const status = 'runDir' in source ? await readStatus($, source.runDir) : await readLocal($, state, run, source.agents, source.started)
    if (status) {
      run.event = latestEvent(run.status?.cells, status.cells) ?? run.event
      run.status = status
      if (!isLive(status)) {
        const notice = finishNotice(status)
        end(state, run, notice.text, notice.isFailure)
      } else if ('runDir' in source && status.pid > 0 && state.nowMs - run.pidCheckedAtMs >= PID_CHECK_MS) {
        // A SIGKILL skips the worker's final status write; without this the
        // band would show the run as live for the rest of the session.
        run.pidCheckedAtMs = state.nowMs
        const alive = await $.process.run(['kill', '-0', String(status.pid)])
        const again = alive.exitCode === 0 ? status : await readStatus($, source.runDir)
        if (again && isLive(again) && alive.exitCode !== 0) end(state, run, abandonedNotice(again), true)
      }
    } else if (state.nowMs - run.sinceMs >= NO_STATUS_MS) {
      end(state, run, abandonedNotice(undefined), true)
    }
  }
  // The clock moves every second while a run is live, so every tick redraws.
  $.ui.invalidate('ui.render')
  if (!state.run && !state.finished) {
    state.timer?.cancel()
    state.timer = undefined
  }
}

// Polling starts with the first tribunal command or lens subagent and stops
// once nothing is left to show: a session that never runs a review pays nothing.
function watch($: EngineInterface, state: BandState, source: Source): Follow {
  const run = { source, sinceMs: state.nowMs, pidCheckedAtMs: state.nowMs }
  state.run = run
  state.finished = undefined
  if (!state.timer) state.timer = $.clock.every(POLL_MS, () => { void poll($, state) })
  return run
}

async function follow($: EngineInterface, state: BandState, runDir: string): Promise<void> {
  const current = state.run?.source
  if (state.ended.has(runDir) || (current && 'runDir' in current && current.runDir === runDir)) return
  state.nowMs = await $.clock.now()
  watch($, state, { runDir })
}

// The four lens subagents start in one message: the first opens the run, the
// rest join it. A live tribunal keeps the band.
async function followLens($: EngineInterface, state: BandState, agentId: string, lens: string): Promise<void> {
  state.nowMs = await $.clock.now()
  let source = state.run?.source
  if (source && 'runDir' in source) return
  if (!source) source = watch($, state, { agents: new Map(), started: new Date(state.nowMs).toISOString() }).source
  if ('agents' in source) source.agents.set(agentId, { lens, seat: 'local', status: 'running' })
}

function chip(ui: Pick<Elements['terminal'], 'Box' | 'Text'>) {
  return (
    <ui.Box key="chip" flexDirection="row" flexShrink={0}>
      <ui.Text bold color={COLOR.onFill} backgroundColor={FILL.chipMark}>{' ✦ '}</ui.Text>
      <ui.Text bold color={COLOR.onFill} backgroundColor={FILL.chip}>{' REVIEW '}</ui.Text>
    </ui.Box>
  )
}

export const register: Register = on => {
  const state: BandState = { ended: new Set(), nowMs: 0 }

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const runDir = tribunalRunDir(e.command)
    // The band is a convenience: a failure to follow never holds the run up.
    if (runDir) await follow($, state, runDir).catch((err: unknown) => $.ui.log(`review band: ${String(err)}`))
    return next(e)
  })

  on('agent.spawn', async ($, e, next) => {
    const result = await next(e)
    const lens = lensOf(e.subagentType)
    if (lens && result.agentId) await followLens($, state, result.agentId, lens).catch((err: unknown) => $.ui.log(`review band: ${String(err)}`))
    return result
  })

  // A lens subagent's one turn ending is its lens done.
  on('turn.complete', ($, e, next) => {
    const source = state.run?.source
    const cell = e.agentId && source && 'agents' in source ? source.agents.get(e.agentId) : undefined
    if (cell?.status === 'running') cell.status = e.reason === 'answer' ? 'ok' : 'failed'
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, ($, e, next) => {
    if (e.props.hasSurvey) return next(e)
    const finished = state.finished
    const run = state.run
    if (!finished && !run) return next(e)
    const ui = $.ui.resolve(e)
    if (finished) {
      return (
        <ui.Box key="finished" flexDirection="row" marginTop={1}>
          {chip(ui)}
          <ui.Text bold {...(finished.isFailure ? { color: COLOR.danger } : {})}>{` ${finished.isFailure ? '✗' : '✓'} ${finished.text}  `}</ui.Text>
          <ui.Button key="finished:dismiss" hotkey="x" label={'x · dismiss'} onPress={() => { state.finished = undefined; $.ui.invalidate('ui.render') }} />
        </ui.Box>
      )
    }
    const status = run?.status
    if (!run || !status) {
      return (
        <ui.Box key="starting" flexDirection="row" marginTop={1}>
          {chip(ui)}
          <ui.Text dimColor>{'  starting…'}</ui.Text>
        </ui.Box>
      )
    }
    const shown = band(status, run.sinceMs, state.nowMs, run.event)
    return (
      <ui.Box key="progress" flexDirection="row" marginTop={1}>
        {chip(ui)}
        <ui.Box flexShrink={0}>
          <ui.Text>
            <ui.Text bold>{`  ${shown.count}`}</ui.Text>
            <ui.Text color={COLOR.accent}>{`  ${shown.bar}`}</ui.Text>
            <ui.Text bold color={COLOR.warning}>{`  ● ${shown.clock}`}</ui.Text>
          </ui.Text>
        </ui.Box>
        <ui.Box flexGrow={1} flexShrink={1}>
          <ui.Text dimColor wrap="truncate-end">{`  ${shown.event ?? ''}  `}</ui.Text>
        </ui.Box>
      </ui.Box>
    )
  })
}
