import { describe, expect, test } from 'bun:test'
import { abandonedNotice, band, finishNotice, latestEvent, lensOf, localStatus, parseStatus, seatRows, tribunalRunDir } from '../hooks/progress'

const DIR = '/tmp/x/review-board/review-pr-508-20261016-182522'

describe('tribunalRunDir', () => {
  test('follows start and wait', () => {
    expect(tribunalRunDir(`bash /p/scripts/run-tribunal.sh wait ${DIR}`)).toBe(DIR)
    expect(tribunalRunDir(`bash /p/scripts/run-tribunal.sh start -m opus -e xhigh ${DIR}/`)).toBe(DIR)
    expect(tribunalRunDir(`bash "/p/scripts/run-tribunal.sh" wait "${DIR}" 2>&1 | tail -5`)).toBe(DIR)
  })
  test('ignores other subcommands, mentions and relative dirs', () => {
    expect(tribunalRunDir(`bash /p/scripts/run-tribunal.sh cancel ${DIR}`)).toBeUndefined()
    expect(tribunalRunDir('bash /p/scripts/run-tribunal.sh discover')).toBeUndefined()
    expect(tribunalRunDir(`grep wait /p/scripts/run-tribunal.sh ${DIR}`)).toBeUndefined()
    expect(tribunalRunDir('bash /p/scripts/run-tribunal.sh wait runs/x')).toBeUndefined()
  })
})

const status = (state: string, statuses: string[]) => JSON.stringify({
  state, pid: 42, started: '2026-10-16T15:25:22Z',
  cells_total: statuses.length, cells_done: statuses.filter(s => s !== 'running').length,
  cells: statuses.map((s, i) => ({ lens: `lens${i}`, seat: 'codex', status: s })),
})

describe('status', () => {
  test('a half-written or foreign file is no status', () => {
    expect(parseStatus('{"state":')).toBeUndefined()
    expect(parseStatus('[]')).toBeUndefined()
  })
  test('band counts, fills and clocks from the run start', () => {
    const s = parseStatus(status('running', ['ok', 'running', 'running', 'running']))!
    const b = band(s, 0, Date.parse('2026-10-16T15:28:12Z'))
    expect(b.count).toBe('1 of 4')
    expect(b.bar).toBe('━━──────')
    expect(b.clock).toBe('2:50')
  })
  test('the event names the cell that just ended', () => {
    const before = parseStatus(status('running', ['ok', 'running']))!
    const after = parseStatus(status('running', ['ok', 'timeout']))!
    expect(latestEvent(undefined, after.cells)).toBeUndefined()
    expect(latestEvent(before.cells, after.cells)).toBe('lens1 · codex timeout')
  })
  test('finish and abandon notices', () => {
    expect(finishNotice(parseStatus(status('done', ['ok', 'timeout']))!)).toEqual({ text: 'finished: 1 of 2 reports ok, 1 failed', isFailure: false })
    expect(finishNotice(parseStatus(status('cancelled', ['ok', 'running']))!).isFailure).toBe(true)
    expect(abandonedNotice(parseStatus(status('running', ['ok', 'running'])))).toBe('stopped before it finished: 1 of 2 done')
  })
})

describe('local run', () => {
  test('only the lens reviewers are followed', () => {
    expect(lensOf('review-board:security-reviewer')).toBe('security')
    expect(lensOf('general-purpose')).toBeUndefined()
    expect(lensOf('other:security-reviewer')).toBeUndefined()
  })
  test('live while a lens runs, done once all have ended', () => {
    const cells = [{ lens: 'simplicity', seat: 'local', status: 'ok' }, { lens: 'security', seat: 'local', status: 'running' }]
    const live = localStatus(cells, '2026-10-16T15:25:22Z')
    expect([live.state, live.done, live.total]).toEqual(['running', 1, 2])
    cells[1]!.status = 'failed'
    expect(live.cells[1]!.status).toBe('running')
    expect(finishNotice(localStatus(cells, ''))).toEqual({ text: 'finished: 1 of 2 reports ok, 1 failed', isFailure: false })
  })
})

describe('seatRows', () => {
  const started = '2026-10-16T15:25:22Z'
  const at = (secs: number) => Date.parse(started) + secs * 1000
  const run = parseStatus(JSON.stringify({
    state: 'running', pid: 42, started, cells_total: 6, cells_done: 4,
    codex_model: 'gpt-6-sol', codex_effort: 'xhigh',
    seat_info: { codex: 'gpt-6-astra, low, week 3%, read-only sandbox', grok: 'default model, xhigh, read-only sandbox', antigravity: 'argon, --sandbox' },
    cells: [
      { lens: 'security', seat: 'codex', status: 'ok', ended: '2026-10-16T15:25:52Z' },
      { lens: 'simplicity', seat: 'codex', status: 'running' },
      { lens: 'security', seat: 'grok', status: 'ok', ended: '2026-10-16T15:26:02Z' },
      { lens: 'simplicity', seat: 'grok', status: 'ok', ended: '2026-10-16T15:26:22Z' },
      { lens: 'security', seat: 'antigravity', status: 'did-not-report', detail: 'quota or auth limit (see security.antigravity.log)', ended: '2026-10-16T15:25:32Z', error: 'Error: out of credits' },
      { lens: 'simplicity', seat: 'antigravity', status: 'ok', ended: '2026-10-16T15:25:42Z' },
    ],
  }))!

  test('a row per seat with its model, count and clock', () => {
    const rows = seatRows(run, 0, at(90))
    expect(rows.map(r => [r.seat, r.model, r.state, r.count, r.clock])).toEqual([
      ['codex', 'gpt-6-sol xhigh', 'running', '1 of 2', '1:30'],
      ['grok', 'default model', 'ok', '2 of 2', '1:00'],
      ['antigravity', 'argon', 'failed', '2 of 2', '0:20'],
    ])
  })
  test('a failed lens carries its reason and the error its log ended on', () => {
    expect(seatRows(run, 0, at(90))[2]!.failures).toEqual([
      { lens: 'security', reason: 'did-not-report: quota or auth limit (see security.antigravity.log)', error: 'Error: out of credits' },
    ])
  })
  test('a status.json from before seat_info still gives rows', () => {
    const old = parseStatus(status('running', ['ok', 'running']))!
    expect(seatRows(old, 0, at(5)).map(r => [r.seat, r.model, r.count])).toEqual([['codex', '', '1 of 2']])
  })
  test('local lens subagents get no seat rows', () => {
    expect(seatRows(localStatus([{ lens: 'security', seat: 'local', status: 'running' }], started), 0, at(1))).toEqual([])
  })
})
