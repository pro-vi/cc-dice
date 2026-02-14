#!/usr/bin/env bun

/**
 * Generic stop hook for cc-dice
 *
 * Reads all registered slots, checks each one.
 * On trigger: stderr + exit 2 (shows to Claude, continues conversation)
 * No trigger: stdout + exit 0 (shows to user only)
 *
 * Installation:
 * 1. Symlink to ~/.claude/hooks/stop-dice.ts
 * 2. Register in settings.json Stop hook
 */

// Import from installed location or relative
let mod: typeof import("../src/index");
try {
  const homeDir = process.env.HOME || "";
  // Try installed location first
  mod = await import(`${homeDir}/.claude/dice/cc-dice.ts`);
} catch {
  // Fall back to relative import (development)
  mod = await import("../src/index");
}

const { listSlots, checkSlot, parseStopHookInput } = mod;

async function main() {
  try {
    const input = await parseStopHookInput();

    const ctx = {
      transcriptPath: input.transcript_path,
      sessionId: input.session_id,
    };

    const slots = await listSlots();

    for (const slot of slots) {
      const result = await checkSlot(slot.name, ctx);

      if (result.triggered) {
        const diceStr = result.rolls.join(", ");
        const message = slot.onTrigger.message
          .replace("{rolls}", diceStr)
          .replace("{best}", String(result.best))
          .replace("{diceCount}", String(result.diceCount))
          .replace("{slotName}", result.slotName);

        console.error(message);
        process.exit(2);
      }

      // Log non-trigger rolls (visible to user only via stdout)
      if (result.diceCount > 0) {
        console.log(
          `${slot.name}: ${result.diceCount}d${slot.die} = [${result.rolls.join(", ")}] (best: ${result.best})`
        );
      }
    }

    process.exit(0);
  } catch (error) {
    if (process.env.DEBUG === "1") {
      console.error("cc-dice stop hook error:", error);
    }
    process.exit(0); // fail gracefully - never block Claude Code
  }
}

main();
