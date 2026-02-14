/**
 * Accumulator dice type logic
 *
 * Calculates how many dice to roll based on conversation depth
 * and accumulation rate.
 */

import type { DiceSlotConfig, CheckContext } from "./types";
import { countExchanges } from "./transcript";
import { loadState, saveState } from "./state";

/**
 * Calculate the number of dice for an accumulator slot.
 *
 * Formula: floor((currentDepth - depth_at_last_trigger) / accumulationRate)
 * Capped at maxDice.
 *
 * Handles sentinel -1: if depth_at_last_trigger is -1, calibrate to current depth
 * (this happens when reset ran without transcript access).
 */
export async function getAccumulatorDiceCount(
  config: DiceSlotConfig,
  sessionId: string,
  ctx: CheckContext
): Promise<{ diceCount: number; currentDepth: number; depthSinceTrigger: number }> {
  // Resolve current depth
  let currentDepth = 0;
  if (config.depthProvider) {
    currentDepth = await config.depthProvider(ctx);
  } else if (ctx.transcriptPath) {
    currentDepth = await countExchanges(ctx.transcriptPath);
  }

  const state = await loadState(config.name, sessionId);

  // Sentinel -1: calibrate to current depth
  if (state.depth_at_last_trigger < 0) {
    state.depth_at_last_trigger = currentDepth;
    await saveState(config.name, sessionId, state);
  }

  const depthSinceTrigger = Math.max(0, currentDepth - state.depth_at_last_trigger);
  const diceCount = Math.min(
    Math.floor(depthSinceTrigger / config.accumulationRate),
    config.maxDice
  );

  return { diceCount, currentDepth, depthSinceTrigger };
}
