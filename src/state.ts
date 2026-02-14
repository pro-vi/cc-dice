#!/usr/bin/env bun

/**
 * Per-slot per-session state persistence
 *
 * State files: {baseDir}/state/{slotName}-{sessionId}.json
 */

import { existsSync, mkdirSync } from "fs";
import { join } from "path";
import { getBaseDir } from "./registry";
import type { DiceState } from "./types";

const DEFAULT_DICE_STATE: DiceState = {
  depth_at_last_trigger: 0,
  last_reset: new Date().toISOString(),
};

/**
 * Get the state directory, creating it if needed.
 */
function getStateDir(): string {
  const stateDir = join(getBaseDir(), "state");
  if (!existsSync(stateDir)) {
    mkdirSync(stateDir, { recursive: true });
  }
  return stateDir;
}

/**
 * Get the state file path for a slot + session combination.
 */
export function getStateFile(slotName: string, sessionId: string): string {
  return join(getStateDir(), `${slotName}-${sessionId}.json`);
}

/**
 * Load dice state for a slot + session.
 */
export async function loadState(slotName: string, sessionId: string): Promise<DiceState> {
  try {
    const stateFile = getStateFile(slotName, sessionId);
    const file = Bun.file(stateFile);
    if (await file.exists()) {
      return await file.json();
    }
  } catch {
    // Corrupted state — return default
  }
  return { ...DEFAULT_DICE_STATE };
}

/**
 * Save dice state for a slot + session.
 */
export async function saveState(
  slotName: string,
  sessionId: string,
  state: DiceState
): Promise<void> {
  const stateFile = getStateFile(slotName, sessionId);
  await Bun.write(stateFile, JSON.stringify(state, null, 2));
}

/**
 * Reset state — set depth_at_last_trigger to given depth (or -1 sentinel).
 */
export async function resetState(
  slotName: string,
  sessionId: string,
  currentDepth: number
): Promise<void> {
  await saveState(slotName, sessionId, {
    depth_at_last_trigger: currentDepth,
    last_reset: new Date().toISOString(),
  });
}

/**
 * Clear state — set depth_at_last_trigger to 0 (full reset).
 */
export async function clearState(slotName: string, sessionId: string): Promise<void> {
  await saveState(slotName, sessionId, {
    depth_at_last_trigger: 0,
    last_reset: new Date().toISOString(),
  });
}
