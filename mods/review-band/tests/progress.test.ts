import { describe, expect, test } from 'bun:test'
import { abandonedNotice, band, finishNotice, latestEvent, parseStatus, tribunalRunDir } from '../hooks/progress'

const DIR = '/tmp/x/review-council/review-pr-508-20261016-182522'

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
