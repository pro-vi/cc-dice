#!/usr/bin/env bun

/**
 * Per-session trigger cooldown markers
 *
 * Marker files: {baseDir}/state/triggered-{slotName}-{sessionId}
 * Presence of file = cooldown active.
 */

import { existsSync, mkdirSync, unlinkSync } from "fs";
import { join } from "path";
import { getBaseDir, validateName } from "./registry";

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
 * Get the cooldown marker file path.
 */
function getMarkerFile(slotName: string, sessionId: string): string {
  validateName(slotName, "slot name");
  validateName(sessionId, "session ID");
  return join(getStateDir(), `triggered-${slotName}-${sessionId}`);
}

/**
 * Check if a slot has already triggered this session.
 */
export async function hasCooldown(slotName: string, sessionId: string): Promise<boolean> {
  return existsSync(getMarkerFile(slotName, sessionId));
}

/**
 * Mark a slot as triggered for this session.
 */
export async function markTriggered(slotName: string, sessionId: string): Promise<void> {
  const markerFile = getMarkerFile(slotName, sessionId);
  await Bun.write(markerFile, new Date().toISOString());
}

/**
 * Clear the cooldown marker for a slot + session.
 */
export function clearCooldown(slotName: string, sessionId: string): void {
  const markerFile = getMarkerFile(slotName, sessionId);
  if (existsSync(markerFile)) {
    unlinkSync(markerFile);
  }
}
