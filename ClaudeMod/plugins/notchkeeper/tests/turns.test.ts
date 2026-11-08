import { expect, mock, test } from 'claude-code/testing'

const FILE = '/Users/u/Library/Application Support/Notchkeeper/turns/s1.json'

/** Stub calls used by mod, returning all turn files it wrote (parsed into objects) */
function stubs(on) {
  const writes = []
  const clock = mock.clock(on, { now: 1000 })
  on('session.id', () => ({ value: 's1' }))
  on('env.get', () => ({ value: '/Users/u' }))
  on('fs.write', ($, e) => {
    expect(e.path).toBe(FILE)
    writes.push(JSON.parse(e.text))
    return { value: undefined }
  })
  on('session.start', () => ({ cwd: '/work' }))
  on('session.end', ($, e) => ({ sessionId: e.sessionId }))
  on('turn.start', ($, e) => ({ turnId: e.turnId }))
  on('turn.complete', () => ({ text: '' }))
  on('agent.spawn', ($, e) => ({ model: 'haiku', agentId: e.tool_use_id }))
  on('turn.step', async function* ($, e) {
    return { turnId: e.turnId, index: e.index, answer: '', toolUses: [], stopReason: e.model, usage: null }
  })
  return { writes, clock }
}

/** Execute one step; tests borrow model field to specify where step stops */
async function step($, turnId, stopReason, agentId) {
  const stream = $.turn.step({ turnId, index: 0, model: stopReason, messageCount: 1, ...(agentId ? { agentId } : {}) })
  let s = await stream.next()
  while (s.done !== true) s = await stream.next()
}

async function start($, interactive = true) {
  await $.session.start({ surface: interactive ? 'terminal' : null, isInteractive: interactive, cwd: '/work' })
}

function complete($, turnId, reason, extra = {}) {
  return $.turn.complete({ turnId, answer: '', durationMs: 1, isAborted: reason === 'aborted', reason, usage: null, ...extra })
}

function spawn($, id, background) {
  return $.agent.spawn({ tool_use_id: id, prompt: '', description: '', subagentType: 'general-purpose', background })
}

test('primary turn normal completion: writes reason, final step stopReason, completion time', async ($, on) => {
  const { writes, clock } = stubs(on)
  await start($)
  await $.turn.start({ text: '', turnId: 't1' })
  await step($, 't1', 'tool_use')
  await step($, 't1', 'end_turn')
  await clock.advance(500)
  await complete($, 't1', 'answer')
  expect(writes).toEqual([{ sessionId: 's1', ended: { turnId: 't1', reason: 'answer', lastStop: 'end_turn', backgroundAgents: 0, at: 1500 } }])
})

test('rejected at approval prompt: final step stops at tool_use', async ($, on) => {
  const { writes } = stubs(on)
  await start($)
  await $.turn.start({ text: '', turnId: 't1' })
  await step($, 't1', 'tool_use')
  await complete($, 't1', 'answer')
  expect(writes.at(-1).ended.lastStop).toBe('tool_use')
})

test('error: writes reason as usual; lastStop is null when no step ran', async ($, on) => {
  const { writes } = stubs(on)
  await start($)
  await $.turn.start({ text: '', turnId: 't1' })
  await complete($, 't1', 'error')
  expect(writes.at(-1).ended).toMatchObject({ reason: 'error', lastStop: null })
})

test('subagent steps do not count as primary agent final step', async ($, on) => {
  const { writes } = stubs(on)
  await start($)
  await $.turn.start({ text: '', turnId: 't1' })
  await step($, 't1', 'end_turn')
  await step($, 'sub', 'tool_use', 'a1')
  await complete($, 't1', 'answer')
  expect(writes.at(-1).ended.lastStop).toBe('end_turn')
})

test('active background agents recorded; foreground subagents excluded; subagent turns not written', async ($, on) => {
  const { writes } = stubs(on)
  await start($)
  await $.turn.start({ text: '', turnId: 't1' })
  await spawn($, 'fg', false)
  await spawn($, 'bg', true)
  await complete($, 't1', 'answer')
  expect(writes.at(-1).ended.backgroundAgents).toBe(1)
  await complete($, 'x', 'answer', { agentId: 'bg' })
  expect(writes.length).toBe(1)
  // Notification turn arriving after background agent completion
  await $.turn.start({ text: '', turnId: 't2' })
  await complete($, 't2', 'answer')
  expect(writes.at(-1).ended).toMatchObject({ turnId: 't2', backgroundAgents: 0 })
})

test('next turn starting does not clear previous turn record (queued messages)', async ($, on) => {
  const { writes } = stubs(on)
  await start($)
  await $.turn.start({ text: '', turnId: 't1' })
  await complete($, 't1', 'answer')
  await $.turn.start({ text: '', turnId: 't2' })
  expect(writes).toHaveLength(1)
  expect(writes[0].ended.turnId).toBe('t1')
})

test('after /clear: background agents and running turns cleared', async ($, on) => {
  const { writes } = stubs(on)
  await start($)
  await $.turn.start({ text: '', turnId: 't1' })
  await spawn($, 'bg', true)
  await $.session.end({ reason: 'clear', sessionId: 's0', resume: { id: 's0' } })
  await complete($, 't1', 'answer')
  expect(writes).toEqual([])
  await $.turn.start({ text: '', turnId: 't2' })
  await complete($, 't2', 'answer')
  expect(writes.at(-1).ended.backgroundAgents).toBe(0)
})

test('non-interactive sessions (claude -p, SDK) not written', async ($, on) => {
  const { writes } = stubs(on)
  await start($, false)
  await $.turn.start({ text: '', turnId: 't1' })
  await complete($, 't1', 'answer')
  expect(writes).toEqual([])
})

test('never writes prompts or answers', async ($, on) => {
  const { writes } = stubs(on)
  await start($)
  await $.turn.start({ text: 'secret prompt', turnId: 't1' })
  await $.turn.complete({ turnId: 't1', answer: 'secret answer', durationMs: 1, isAborted: false, reason: 'answer', usage: null })
  expect(JSON.stringify(writes)).not.toContain('secret')
})
