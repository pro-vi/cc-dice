# cc-dice

Generic probabilistic dice trigger system for Claude Code hooks.

Consumers register "dice slots" with configuration (die size, target number, accumulation rate, etc.), and cc-dice handles rolling, state persistence, cooldown, and hook integration.

## Quick Start

```bash
# Install
./install.sh

# Register a slot
bun bin/cc-dice.ts register my-trigger \
  --die 20 --target 20 --type accumulator \
  --message "Natural 20! Time to reflect."

# Check status
bun bin/cc-dice.ts status my-trigger

# Manual check (same as stop hook)
bun bin/cc-dice.ts check
```

## Dice Types

### Accumulator (default)
Dice count increases with conversation depth. +1 die per N turns since last trigger.

```
Turns 0-6:   0 dice (0%)
Turns 7-13:  1d20  (5%)
Turns 14-20: 2d20  (9.8%)
Turns 21-27: 3d20  (14.3%)
```

### Fixed
Always rolls a fixed number of dice.

### Single
Always rolls exactly 1 die.

## Target Modes

- `exact`: Roll must equal target (e.g., Natural 20)
- `gte`: Roll must be >= target
- `lte`: Roll must be <= target

## CLI

```
cc-dice register <name> [options]   Register a dice slot
cc-dice unregister <name>           Remove a slot
cc-dice list                        List all slots
cc-dice status <name> [transcript]  Show status
cc-dice roll <name> [transcript]    Dry-run roll
cc-dice reset <name> [transcript]   Reset accumulator
cc-dice clear <name> [transcript]   Clear state
cc-dice session-start               Clear auto-clear slots
cc-dice check [transcript]          Check all slots (stop hook)
```

## Storage

```
~/.claude/dice/
  slots.json                          Registered slot configs
  state/
    {slotName}-{sessionId}.json       Per-slot per-session state
    triggered-{slotName}-{sessionId}  Cooldown markers
```

## Environment Variables

- `CC_DICE_BASE`: Override base directory (default: `~/.claude/dice/`)
- `CC_DICE_SESSION_ID`: Override session ID
- `CC_REFLECTION_SESSION_ID`: Backward-compat session ID
- `DEBUG=1`: Verbose logging to stderr

## Programmatic API

```typescript
import {
  registerSlot,
  checkSlot,
  getSlotStatus,
  resetSlot,
  clearSlot,
  sessionStart,
} from "cc-dice/src/index";

// Register
await registerSlot({
  name: "my-trigger",
  die: 20,
  target: 20,
  type: "accumulator",
  onTrigger: { message: "Triggered!" },
});

// Check
const result = await checkSlot("my-trigger", {
  transcriptPath: "/path/to/transcript.jsonl",
});

if (result.triggered) {
  console.log("Dice triggered!", result.rolls);
}
```

## License

MIT
