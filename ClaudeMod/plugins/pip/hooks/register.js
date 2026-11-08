// Pip Claude Code mod: writes most recently completed primary turn to a small JSON for notch app to read.
// Reports facts only (turnId, reason, final step stopReason, active background agent count at completion, completion timestamp);
// turn outcome calculation is delegated to App's AgentCore;
// Writes metadata only: never prompts, answers, or tool parameters.
// Rules and file format detailed in docs/agent-integration.md "Pip mod".
// @see https://code.claude.com/docs/en/plugins/mods/events (turn.start / turn.step / turn.complete / agent.spawn)

/** Write only in interactive sessions: claude -p and SDK are omitted (session.start isInteractive; refires on mod reload) */
let interactive = false
/** Active primary turn: { id, lastStop } */
let running = null
/** Active background agent agentIds */
const background = new Set()
/** Previous disk write: writes are queued sequentially so earlier writes never overwrite later ones */
let lastWrite = Promise.resolve()

/** Write newly ended primary turn. sessionId retrieved at write time (changes after /clear) */
async function save($, ended) {
  if (!interactive) return
  const previous = lastWrite
  let finish
  lastWrite = new Promise((resolve) => { finish = resolve })
  await previous
  try {
    const sessionId = await $.session.id()
    const home = await $.env.get('HOME')
    // Full overwrite, non-atomic: App treats partial writes as decode failure and waits for next write
    await $.fs.write(home + '/Library/Application Support/Notchkeeper/turns/' + sessionId + '.json',
      JSON.stringify({ sessionId, ended }))
  } catch (error) {
    // Write failure (disk full, permissions) logs debug only: session suppresses done card, Claude Code continues normally
    $.ui.log('Failed to write turn file: ' + error, { to: 'debug' })
  } finally {
    finish()
  }
}

export function register(on) {
  on('session.start', async ($, e, next) => {
    interactive = e.isInteractive
    return next(e)
  })

  // /clear and resume change session id without re-triggering session.start
  on('session.end', async ($, e, next) => {
    running = null
    background.clear()
    return next(e)
  })

  // Fires on primary turn only (verified)
  on('turn.start', async ($, e, next) => {
    running = { id: e.turnId, lastStop: null }
    return next(e)
  })

  // Record where primary agent final step stopped: stopping at tool_use indicates no model request followed tool result (rejected in approval dialog).
  // Subagent steps carry their own execution turnId, diverging from primary turn
  on('turn.step', async function* ($, e, next) {
    const result = yield* next(e)
    if (running && running.id === e.turnId) running.lastStop = result.stopReason ?? null
    return result
  })

  on('turn.complete', async ($, e, next) => {
    if (e.agentId !== undefined) {
      // Subagent turns (including those stopped via TaskStop, verified): track completion of background agents only
      background.delete(e.agentId)
    } else if (running && running.id === e.turnId) {
      const ended = { turnId: e.turnId, reason: e.reason, lastStop: running.lastStop, backgroundAgents: background.size,
                      at: await $.clock.now() }
      running = null
      await save($, ended)
    }
    return next(e)
  })

  on('agent.spawn', async ($, e, next) => {
    const result = await next(e)
    if (e.background && result.agentId !== undefined) background.add(result.agentId)
    return result
  })
}
