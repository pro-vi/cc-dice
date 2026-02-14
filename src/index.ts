/**
 * cc-dice — Generic probabilistic dice trigger system for Claude Code hooks
 *
 * Public API re-exports.
 */

// Types
export type {
  DiceSlotConfig,
  DiceState,
  CheckContext,
  DiceResult,
  SlotStatus,
} from "./types";

// Registration
export { registerSlot, unregisterSlot, getSlot, listSlots, getBaseDir } from "./registry";

// State
export { loadState, saveState, resetState, clearState } from "./state";

// Cooldown
export { hasCooldown, markTriggered, clearCooldown } from "./cooldown";

// Roll
export { rollDice, checkTarget, calculateProbability } from "./roll";

// Transcript
export { getTranscriptPath, countExchanges } from "./transcript";

// Session
export { getClaudeSessionId, getSessionId, extractSessionFromPath, getProjectHash } from "./session";

// Hook helpers
export { parseStopHookInput, exitWithResult } from "./hook-helpers";

// Accumulator
export { getAccumulatorDiceCount } from "./accumulator";

// ============================================================================
// High-level API
// ============================================================================

import type { DiceSlotConfig, CheckContext, DiceResult, SlotStatus } from "./types";
import { getSlot, listSlots as listSlotsInternal } from "./registry";
import { loadState, resetState as resetStateInternal, clearState as clearStateInternal } from "./state";
import { hasCooldown, markTriggered as markTriggeredInternal, clearCooldown } from "./cooldown";
import { rollDice, checkTarget, calculateProbability } from "./roll";
import { countExchanges } from "./transcript";
import { extractSessionFromPath, getSessionId } from "./session";
import { getAccumulatorDiceCount } from "./accumulator";

/**
 * Resolve session ID from context, falling back to env/project hash.
 */
function resolveSessionId(ctx: CheckContext): string {
  if (ctx.sessionId) return ctx.sessionId;
  if (ctx.transcriptPath) {
    const extracted = extractSessionFromPath(ctx.transcriptPath);
    if (extracted) return extracted;
  }
  return getSessionId();
}

/**
 * Calculate dice count for any slot type.
 */
async function getDiceCount(
  config: DiceSlotConfig,
  sessionId: string,
  ctx: CheckContext
): Promise<{ diceCount: number; currentDepth: number; depthSinceTrigger: number }> {
  switch (config.type) {
    case "accumulator":
      return getAccumulatorDiceCount(config, sessionId, ctx);

    case "fixed":
      return { diceCount: config.fixedCount, currentDepth: 0, depthSinceTrigger: 0 };

    case "single":
      return { diceCount: 1, currentDepth: 0, depthSinceTrigger: 0 };

    default:
      return { diceCount: 0, currentDepth: 0, depthSinceTrigger: 0 };
  }
}

/**
 * Main entry point: check a slot.
 *
 * 1. Load slot config from registry
 * 2. Check cooldown (if per-session)
 * 3. Calculate dice count based on type
 * 4. Roll dice
 * 5. If triggered AND resetOnTrigger: reset accumulator state
 * 6. If triggered AND cooldown === 'per-session': write cooldown marker
 * 7. Return result
 */
export async function checkSlot(name: string, ctx: CheckContext = {}): Promise<DiceResult> {
  const config = await getSlot(name);
  if (!config) {
    return { triggered: false, rolls: [], best: 0, diceCount: 0, probability: 0, slotName: name };
  }

  const sessionId = resolveSessionId(ctx);

  // Check cooldown
  if (config.cooldown === "per-session") {
    if (await hasCooldown(name, sessionId)) {
      return { triggered: false, rolls: [], best: 0, diceCount: 0, probability: 0, slotName: name };
    }
  }

  // Calculate dice count
  const { diceCount } = await getDiceCount(config, sessionId, ctx);

  if (diceCount <= 0) {
    return { triggered: false, rolls: [], best: 0, diceCount: 0, probability: 0, slotName: name };
  }

  // Roll
  const rolls = rollDice(diceCount, config.die);
  const best = rolls.length > 0 ? Math.max(...rolls) : 0;
  const triggered = checkTarget(rolls, config.target, config.targetMode);
  const probability = calculateProbability(diceCount, config.die, config.target, config.targetMode);

  // Handle trigger
  if (triggered) {
    if (config.resetOnTrigger && config.type === "accumulator") {
      // Get current depth for reset
      let currentDepth = 0;
      if (config.depthProvider) {
        currentDepth = await config.depthProvider(ctx);
      } else if (ctx.transcriptPath) {
        currentDepth = await countExchanges(ctx.transcriptPath);
      }
      await resetStateInternal(name, sessionId, currentDepth);
    }

    if (config.cooldown === "per-session") {
      await markTriggeredInternal(name, sessionId);
    }
  }

  return { triggered, rolls, best, diceCount, probability, slotName: name };
}

/**
 * Reset a slot's accumulator (set depth_at_last_trigger = current depth).
 * If no transcript is available, uses sentinel -1.
 */
export async function resetSlot(name: string, ctx: CheckContext = {}): Promise<void> {
  const config = await getSlot(name);
  if (!config) return;

  const sessionId = resolveSessionId(ctx);

  let currentDepth = -1; // sentinel
  if (config.depthProvider) {
    currentDepth = await config.depthProvider(ctx);
  } else if (ctx.transcriptPath) {
    currentDepth = await countExchanges(ctx.transcriptPath);
  }

  await resetStateInternal(name, sessionId, currentDepth);
}

/**
 * Clear a slot's state completely (depth = 0, remove cooldown).
 */
export async function clearSlot(name: string, ctx: CheckContext = {}): Promise<void> {
  const config = await getSlot(name);
  if (!config) return;

  const sessionId = resolveSessionId(ctx);
  await clearStateInternal(name, sessionId);
  clearCooldown(name, sessionId);
}

/**
 * Get status for a slot without rolling.
 */
export async function getSlotStatus(name: string, ctx: CheckContext = {}): Promise<SlotStatus | null> {
  const config = await getSlot(name);
  if (!config) return null;

  const sessionId = resolveSessionId(ctx);
  const { diceCount, currentDepth, depthSinceTrigger } = await getDiceCount(config, sessionId, ctx);
  const probability = calculateProbability(diceCount, config.die, config.target, config.targetMode);

  // Calculate next dice threshold
  let nextDiceAt = 0;
  if (config.type === "accumulator") {
    const state = await loadState(name, sessionId);
    nextDiceAt = state.depth_at_last_trigger + (diceCount + 1) * config.accumulationRate;
  }

  return {
    name: config.name,
    type: config.type,
    diceCount,
    currentDepth,
    depthSinceTrigger,
    probability,
    nextDiceAt,
    sessionId,
  };
}

/**
 * Session start: clear all slots with clearOnSessionStart=true.
 */
export async function sessionStart(ctx: CheckContext = {}): Promise<string[]> {
  const slots = await listSlotsInternal();
  const sessionId = resolveSessionId(ctx);
  const cleared: string[] = [];

  for (const slot of slots) {
    if (slot.clearOnSessionStart) {
      await clearStateInternal(slot.name, sessionId);
      clearCooldown(slot.name, sessionId);
      cleared.push(slot.name);
    }
  }

  return cleared;
}
