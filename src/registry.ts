#!/usr/bin/env bun

/**
 * Slot Registry
 *
 * File-based registration of dice slot configurations.
 * Stored at {baseDir}/slots.json.
 */

import { existsSync, mkdirSync } from "fs";
import { join } from "path";
import type { DiceSlotConfig } from "./types";

/**
 * Resolve the base directory for cc-dice data.
 * Default: ~/.claude/dice/, overridable via CC_DICE_BASE env var.
 */
export function getBaseDir(): string {
  if (process.env.CC_DICE_BASE) return process.env.CC_DICE_BASE;
  const home = process.env.HOME;
  if (!home) throw new Error("Cannot resolve base dir: set CC_DICE_BASE or HOME");
  return join(home, ".claude", "dice");
}

function ensureBaseDir(): string {
  const baseDir = getBaseDir();
  if (!existsSync(baseDir)) {
    mkdirSync(baseDir, { recursive: true });
  }
  return baseDir;
}

function getSlotsFile(): string {
  return join(ensureBaseDir(), "slots.json");
}

/**
 * Default values applied when registering a slot.
 */
export const SLOT_DEFAULTS: Partial<DiceSlotConfig> = {
  targetMode: "exact",
  type: "accumulator",
  accumulationRate: 7,
  maxDice: 100,
  fixedCount: 1,
  cooldown: "per-session",
  clearOnSessionStart: true,
  resetOnTrigger: true,
};

/**
 * Load all registered slots from disk.
 */
export async function loadSlots(): Promise<Record<string, DiceSlotConfig>> {
  try {
    const file = Bun.file(getSlotsFile());
    if (await file.exists()) {
      return await file.json();
    }
  } catch {
    // Corrupted file — return empty
  }
  return {};
}

/**
 * Save all slots to disk.
 */
async function saveSlots(slots: Record<string, DiceSlotConfig>): Promise<void> {
  ensureBaseDir();
  await Bun.write(getSlotsFile(), JSON.stringify(slots, null, 2));
}

/**
 * Register a dice slot. Merges provided config with defaults.
 * Persists to slots.json.
 */
export async function registerSlot(
  config: Partial<DiceSlotConfig> & { name: string; die: number; target: number; onTrigger: { message: string } }
): Promise<DiceSlotConfig> {
  const fullConfig: DiceSlotConfig = {
    ...SLOT_DEFAULTS,
    ...config,
  } as DiceSlotConfig;

  const slots = await loadSlots();
  // Strip depthProvider before persisting (function can't be serialized)
  const { depthProvider, ...serializable } = fullConfig;
  slots[fullConfig.name] = serializable as DiceSlotConfig;
  await saveSlots(slots);

  return fullConfig;
}

/**
 * Remove a slot from the registry.
 */
export async function unregisterSlot(name: string): Promise<boolean> {
  const slots = await loadSlots();
  if (!(name in slots)) return false;
  delete slots[name];
  await saveSlots(slots);
  return true;
}

/**
 * Get a single slot config by name.
 */
export async function getSlot(name: string): Promise<DiceSlotConfig | null> {
  const slots = await loadSlots();
  return slots[name] ?? null;
}

/**
 * List all registered slot configs.
 */
export async function listSlots(): Promise<DiceSlotConfig[]> {
  const slots = await loadSlots();
  return Object.values(slots);
}
