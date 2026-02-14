#!/usr/bin/env bun

/**
 * cc-dice CLI entrypoint
 *
 * Usage: cc-dice <command> [options]
 *
 * Slot Management:
 *   register <name> [options]    Register a dice slot
 *   unregister <name>            Remove a slot
 *   list                         List all registered slots
 *
 * Per-Slot Operations:
 *   status <name> [transcript]   Show current dice status
 *   roll <name> [transcript]     Roll without state change (dry run)
 *   reset <name> [transcript]    Reset accumulator
 *   clear <name> [transcript]    Clear state (session start)
 *
 * Session:
 *   session-start                Clear all slots with clearOnSessionStart=true
 *
 * Hook:
 *   check [transcript]           Check all slots (used by stop hook)
 */

import {
  registerSlot,
  unregisterSlot,
  listSlots,
  getSlot,
  getSlotStatus,
  checkSlot,
  resetSlot,
  clearSlot,
  sessionStart,
  rollDice,
  checkTarget,
  calculateProbability,
  extractSessionFromPath,
} from "../src/index";
import type { DiceSlotConfig, CheckContext } from "../src/types";

const args = process.argv.slice(2);
const command = args[0];

function printUsage(): void {
  console.log(`Usage: cc-dice <command> [options]

Slot Management:
  register <name> [options]    Register a dice slot
  unregister <name>            Remove a slot
  list                         List all registered slots

Per-Slot Operations:
  status <name> [transcript]   Show current dice status
  roll <name> [transcript]     Roll without state change (dry run)
  reset <name> [transcript]    Reset accumulator
  clear <name> [transcript]    Clear state (session start)

Session:
  session-start                Clear all slots with clearOnSessionStart=true

Hook:
  check [transcript]           Check all slots (used by stop hook)

Register Options:
  --die <n>                    Die size (default: 20)
  --target <n>                 Target number (default: 20)
  --target-mode <mode>         exact|gte|lte (default: exact)
  --type <type>                accumulator|fixed|single (default: accumulator)
  --accumulation-rate <n>      Turns per +1 die (default: 7)
  --max-dice <n>               Max dice cap (default: 100)
  --fixed-count <n>            Dice count for fixed type (default: 1)
  --cooldown <mode>            per-session|none (default: per-session)
  --no-clear-on-start          Don't clear on session start
  --no-reset-on-trigger        Don't reset accumulator on trigger
  --message <msg>              Trigger message for stderr`);
}

function parseArg(flag: string): string | undefined {
  const idx = args.indexOf(flag);
  if (idx >= 0 && idx + 1 < args.length) return args[idx + 1];
  return undefined;
}

function hasFlag(flag: string): boolean {
  return args.includes(flag);
}

function buildContext(transcriptArg?: string): CheckContext {
  const ctx: CheckContext = {};
  if (transcriptArg) {
    ctx.transcriptPath = transcriptArg;
    ctx.sessionId = extractSessionFromPath(transcriptArg);
  }
  return ctx;
}

async function main(): Promise<void> {
  if (!command || command === "help" || command === "--help" || command === "-h") {
    printUsage();
    process.exit(0);
  }

  switch (command) {
    case "register": {
      const name = args[1];
      if (!name) {
        console.error("Error: slot name required");
        process.exit(1);
      }

      const die = Number(parseArg("--die") ?? "20");
      const target = Number(parseArg("--target") ?? "20");
      const targetMode = (parseArg("--target-mode") ?? "exact") as "exact" | "gte" | "lte";
      const type = (parseArg("--type") ?? "accumulator") as "accumulator" | "fixed" | "single";
      const accumulationRate = Number(parseArg("--accumulation-rate") ?? "7");
      const maxDice = Number(parseArg("--max-dice") ?? "100");
      const fixedCount = Number(parseArg("--fixed-count") ?? "1");
      const cooldown = (parseArg("--cooldown") ?? "per-session") as "per-session" | "none";
      const clearOnSessionStart = !hasFlag("--no-clear-on-start");
      const resetOnTrigger = !hasFlag("--no-reset-on-trigger");
      const message = parseArg("--message") ?? `Dice trigger: ${name}`;

      const config = await registerSlot({
        name,
        die,
        target,
        targetMode,
        type,
        accumulationRate,
        maxDice,
        fixedCount,
        cooldown,
        clearOnSessionStart,
        resetOnTrigger,
        onTrigger: { message },
      });

      console.log(`Registered slot: ${name}`);
      console.log(JSON.stringify(config, null, 2));
      break;
    }

    case "unregister": {
      const name = args[1];
      if (!name) {
        console.error("Error: slot name required");
        process.exit(1);
      }
      const removed = await unregisterSlot(name);
      if (removed) {
        console.log(`Removed slot: ${name}`);
      } else {
        console.error(`Slot not found: ${name}`);
        process.exit(1);
      }
      break;
    }

    case "list": {
      const slots = await listSlots();
      if (slots.length === 0) {
        console.log("No slots registered.");
      } else {
        for (const slot of slots) {
          console.log(`  ${slot.name} (${slot.type}, ${slot.die}-sided, target=${slot.target} ${slot.targetMode})`);
        }
      }
      break;
    }

    case "status": {
      const name = args[1];
      if (!name) {
        console.error("Error: slot name required");
        process.exit(1);
      }
      const ctx = buildContext(args[2]);
      const status = await getSlotStatus(name, ctx);
      if (!status) {
        console.error(`Slot not found: ${name}`);
        process.exit(1);
      }
      console.log(`Slot: ${status.name} (${status.type})`);
      console.log(`  Dice count:      ${status.diceCount}`);
      console.log(`  Current depth:   ${status.currentDepth}`);
      console.log(`  Since trigger:   ${status.depthSinceTrigger}`);
      console.log(`  Probability:     ${status.probability}%`);
      if (status.type === "accumulator") {
        console.log(`  Next die at:     depth ${status.nextDiceAt}`);
      }
      break;
    }

    case "roll": {
      const name = args[1];
      if (!name) {
        console.error("Error: slot name required");
        process.exit(1);
      }
      const config = await getSlot(name);
      if (!config) {
        console.error(`Slot not found: ${name}`);
        process.exit(1);
      }
      const ctx = buildContext(args[2]);
      const status = await getSlotStatus(name, ctx);
      if (!status) {
        process.exit(1);
        return; // unreachable, satisfies TS
      }
      const diceCount = status.diceCount;
      if (diceCount <= 0) {
        console.log(`${name}: 0 dice (no roll)`);
        break;
      }
      const rolls = rollDice(diceCount, config.die);
      const best = rolls.length > 0 ? Math.max(...rolls) : 0;
      const triggered = checkTarget(rolls, config.target, config.targetMode);
      const probability = calculateProbability(diceCount, config.die, config.target, config.targetMode);
      console.log(`${name}: ${diceCount}d${config.die} = [${rolls.join(", ")}] (best: ${best}, ${probability}%)${triggered ? " TRIGGERED!" : ""}`);
      break;
    }

    case "reset": {
      const name = args[1];
      if (!name) {
        console.error("Error: slot name required");
        process.exit(1);
      }
      const ctx = buildContext(args[2]);
      await resetSlot(name, ctx);
      console.log(`Reset slot: ${name}`);
      break;
    }

    case "clear": {
      const name = args[1];
      if (!name) {
        console.error("Error: slot name required");
        process.exit(1);
      }
      const ctx = buildContext(args[2]);
      await clearSlot(name, ctx);
      console.log(`Cleared slot: ${name}`);
      break;
    }

    case "session-start": {
      const ctx = buildContext(args[1]);
      const cleared = await sessionStart(ctx);
      if (cleared.length > 0) {
        console.log(`Cleared ${cleared.length} slot(s): ${cleared.join(", ")}`);
      } else {
        console.log("No slots to clear.");
      }
      break;
    }

    case "check": {
      const ctx = buildContext(args[1]);
      const slots = await listSlots();
      if (slots.length === 0) {
        process.exit(0);
      }

      const results: string[] = [];
      for (const slot of slots) {
        const result = await checkSlot(slot.name, ctx);

        if (result.triggered) {
          // Trigger: stderr + exit 2
          const diceStr = result.rolls.join(", ");
          const message = slot.onTrigger.message
            .replace("{rolls}", diceStr)
            .replace("{best}", String(result.best))
            .replace("{diceCount}", String(result.diceCount))
            .replace("{slotName}", result.slotName);
          console.error(message);
          process.exit(2);
        }

        if (result.diceCount > 0) {
          results.push(
            `${slot.name}: ${result.diceCount}d${slot.die} = [${result.rolls.join(", ")}] (best: ${result.best})`
          );
        }
      }

      // Non-trigger: show all results on stdout (user visible only)
      if (results.length > 0) {
        console.log(results.join("\n"));
      }
      process.exit(0);
      break;
    }

    default:
      console.error(`Unknown command: ${command}`);
      printUsage();
      process.exit(1);
  }
}

main().catch((error) => {
  if (process.env.DEBUG === "1") {
    console.error("cc-dice error:", error);
  }
  process.exit(0); // fail gracefully
});
