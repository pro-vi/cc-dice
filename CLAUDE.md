# Development Journal - CC-Dice

This document records the origin, architecture, and development of cc-dice -- a generic probabilistic dice trigger system extracted from cc-reflection.

---

## Quick Reference

**Location**: `/Users/provi/Development/_projs/cc-dice/`

**Sibling**: `/Users/provi/Development/_projs/cc-reflection/` (primary consumer)

**Installed to**: `~/.claude/dice/` (symlinked via `install.sh`)

**Hook**: `hooks/stop.ts` -> `~/.claude/hooks/stop-dice.ts`

**CLI**: `bin/cc-dice.ts` -> `~/.local/bin/cc-dice`

**State**: `~/.claude/dice/slots.json` (registry) + `~/.claude/dice/state/` (per-session)

---

## Origin Story

### The Problem

cc-reflection had a dice accumulator system baked directly into its codebase. The system worked well -- escalating d20 probability that prompted Claude to reflect after long sessions. But it was tightly coupled to reflection:

- `lib/dice.ts` -- accumulator state, rolling, persistence
- `lib/transcript.ts` -- JSONL depth counting, path resolution
- `lib/reflection-utils.ts` -- CLI dispatcher, trigger cooldowns
- `bin/reflection-stop.ts` -- stop hook (100 lines)
- `bin/reflection-stop-simple.ts` -- simple variant (63 lines)

The dice logic itself was generic -- nothing about rolling d20s and checking for Natural 20 is reflection-specific. But it was entangled with reflection's session management, state directories, and CLI dispatcher.

### The Extraction (2026-02-14)

cc-dice was created as a clean extraction of the dice system from cc-reflection. The goal: a reusable package that any Claude Code tool can depend on for probabilistic triggering.

**Why not a Claude Code plugin?** Plugins can register hooks, but they can't expose APIs that other plugins consume. If cc-dice were a plugin and cc-reflection were a plugin, they couldn't import each other. An npm/bun package is the right abstraction -- importable by anything.

**Why not keep it in cc-reflection?** Other tools might want probabilistic hooks. A lint-nag that occasionally reminds you to run tests. A code review prompt that fires after long coding sessions. The dice mechanic is universal; the reflection use case is specific.

### The Cut

The extraction was clean. Almost everything in `dice.ts` was generic:

| Component | Generic? | Destination |
|-----------|----------|-------------|
| DiceState interface | Yes | cc-dice `types.ts` |
| Accumulator math | Yes | cc-dice `accumulator.ts` |
| Rolling mechanics | Yes | cc-dice `roll.ts` |
| State persistence | Yes | cc-dice `state.ts` |
| Trigger cooldowns | Yes | cc-dice `cooldown.ts` |
| JSONL transcript parser | Yes | cc-dice `transcript.ts` |
| Session ID resolution | Yes | cc-dice `session.ts` |
| Trigger message text | No | Consumer-specific |
| "Invoke /reflection" action | No | cc-reflection only |

The only reflection-specific parts were the message text and the action taken on trigger. Everything else was plumbing.

**cc-reflection impact**: -939 lines removed. `lib/dice.ts` deleted entirely. `lib/transcript.ts` trimmed to only `getRecentTurns` (reflection-specific context extraction). Stop hooks became ~15 lines each -- thin wrappers that register a slot and delegate to cc-dice.

---

## Architecture

### Slot System

The core abstraction is a "dice slot" -- a named configuration for probabilistic triggering:

```typescript
registerSlot({
  name: 'reflection',          // unique identifier
  type: 'accumulator',         // accumulator | fixed | single
  die: 20,                     // die size
  target: 20,                  // trigger value
  targetMode: 'exact',         // exact | gte | lte
  accumulationRate: 7,         // turns per +1 die
  cooldown: 'per-session',     // per-session | none
  clearOnSessionStart: true,   // auto-clear on new session
  resetOnTrigger: true,        // auto-reset accumulator on trigger
  onTrigger: {
    message: 'Natural 20! Do the thing.'
  },
});
```

Slots are persisted to `~/.claude/dice/slots.json`. Multiple consumers can register independent slots. The stop hook iterates all slots and checks each one.

### Dice Types

**Accumulator** (default): Dice count scales with conversation depth. +1 die per N turns since last trigger. This creates escalating pressure -- longer sessions have higher trigger probability.

```
Turns since trigger | Dice | Per-turn chance | Cumulative
0-6                 | 0    | 0%              | 0%
7-13                | 1    | 5%              | ~50% by turn 13
14-20               | 2    | 10%             | ~89% by turn 20
21-27               | 3    | 14%             | ~99% by turn 27
```

**Fixed**: Always rolls N dice. Constant probability regardless of depth.

**Single**: Always rolls 1 die. Flat chance every time.

### State Model

```
~/.claude/dice/
  slots.json                           # slot registry (all configs)
  state/
    {slotName}-{sessionId}.json        # per-slot per-session accumulator state
    triggered-{slotName}-{sessionId}   # per-session cooldown markers
```

State is per-slot AND per-session. Two Claude sessions in the same project have independent dice counts. Two different slots in the same session have independent state.

### checkSlot Flow

```
checkSlot(name, ctx)
  |
  +-- Load slot config from registry
  +-- Resolve session ID (ctx > transcript path > env var > project hash)
  +-- Check cooldown marker
  |     YES -> return { triggered: false }
  |     NO  -> continue
  +-- Calculate dice count
  |     accumulator: depth provider -> floor((depth - last_trigger) / rate)
  |     fixed: config.fixedCount
  |     single: 1
  +-- Roll dice
  +-- Check target (exact/gte/lte)
  |     NO  -> return { triggered: false, rolls, best, ... }
  |     YES -> continue
  +-- Auto-reset accumulator (if resetOnTrigger)
  +-- Write cooldown marker (if per-session)
  +-- return { triggered: true, rolls, best, ... }
```

### Hook Integration

Stop hook receives JSON on stdin from Claude Code:
```json
{ "session_id": "uuid", "transcript_path": "/path/to/transcript.jsonl" }
```

Exit codes:
- `0` -- silent pass (stdout visible to user only)
- `2` -- show stderr message to Claude, continue conversation

The generic stop hook (`hooks/stop.ts`) iterates all registered slots. On first trigger, it prints the slot's `onTrigger.message` to stderr and exits 2. Consumer-specific hooks (like cc-reflection's `reflection-stop.ts`) can register their slot and delegate to `checkSlot` directly.

### Depth Provider

The default depth provider reads Claude Code JSONL transcripts -- counts entries with `type === "user"` (excluding tool results). This is shipped with cc-dice because it's what 99% of users need.

For exotic use cases, slots accept a custom `depthProvider` callback:

```typescript
registerSlot({
  name: 'custom',
  type: 'accumulator',
  depthProvider: async (ctx) => getDepthFromSomewhere(ctx),
  // ...
});
```

The `depthProvider` is not serialized to `slots.json` -- it's set at runtime by the consumer.

### Sentinel -1

When `resetSlot` is called without transcript access (e.g., cross-project invocation where the transcript file isn't available), it saves `depth_at_last_trigger = -1`. On the next `checkSlot` call (when the transcript IS available), it detects the sentinel and calibrates to the current depth. This prevents the accumulator from counting from 0 after a reset where the real depth was unknown.

---

## Relationship to cc-reflection

### cc-reflection depends on cc-dice

cc-reflection is the primary consumer. After extraction:

**Before** (tightly coupled):
```
cc-reflection/
  lib/dice.ts            142 lines -- accumulator, rolling, state
  lib/transcript.ts      299 lines -- depth counting, path resolution, recent turns
  lib/reflection-utils.ts 242 lines -- CLI dispatcher, cooldowns, re-exports
  bin/reflection-stop.ts  101 lines -- full hook implementation
```

**After** (thin wrapper):
```
cc-reflection/
  lib/transcript.ts       181 lines -- ONLY getRecentTurns (for expand context)
  lib/reflection-utils.ts  53 lines -- ONLY get-recent CLI command
  bin/reflection-stop.ts    64 lines -- registers slot, delegates to cc-dice
```

### How cc-reflection uses cc-dice

The stop hook registers a slot and delegates:

```typescript
// bin/reflection-stop.ts (the entire logic)
const ccDice = await import(`${homeDir}/.claude/dice/cc-dice.ts`);

registerSlot({
  name: 'reflection',
  type: 'accumulator',
  die: 20,
  target: 20,
  accumulationRate: 7,
  resetOnTrigger: true,
  onTrigger: { message: 'Natural 20! Invoke /reflection' },
});

const input = await parseStopHookInput();
const result = await checkSlot('reflection', input);
exitWithResult(result, getSlot('reflection'));
```

**No manual dice-reset needed.** The old system required the reflection skill to call `dice-reset` after creating a seed. Now `resetOnTrigger: true` handles it automatically inside `checkSlot`.

**No manual session-start clearing.** The old system required the session-start hook to call `dice-clear`. Now `clearOnSessionStart: true` is handled by `sessionStart()`.

### Shared Session ID

Both packages need the Claude Code session UUID. Resolution order:
1. `CC_DICE_SESSION_ID` env var (set by session-start hook)
2. `CC_REFLECTION_SESSION_ID` env var (backward compat)
3. Extract from transcript path regex
4. Project hash fallback (MD5 of PWD)

The session-start hook in cc-reflection now sets both env vars:
```typescript
appendFileSync(envFile, `export CC_REFLECTION_SESSION_ID="${sessionId}"\n`);
appendFileSync(envFile, `export CC_DICE_SESSION_ID="${sessionId}"\n`);
```

---

## Design Decisions

### Decision: Auto-reset on trigger

**Why**: The two-step dance (dice triggers -> consumer acts -> consumer calls dice-reset) was unnecessary friction. If the dice triggered, the accumulator should reset immediately. The cooldown marker prevents re-triggering in the same session anyway.

**Override**: Set `resetOnTrigger: false` for slots that want trigger-without-reset.

### Decision: Default transcript parser shipped with package

**Why**: DX. Nobody installing a Claude Code dice package should have to write their own JSONL parser. The default depth provider handles the common case. Custom `depthProvider` exists for edge cases.

### Decision: File-based slot registry

**Why**: Simple, portable, inspectable. `slots.json` can be edited by hand, backed up, or version-controlled. No database, no daemon, no IPC.

**Tradeoff**: Runtime `depthProvider` callbacks can't be serialized. Consumers must re-register slots with callbacks at startup.

### Decision: npm/bun package, not Claude Code plugin

**Why**: Plugins can't expose APIs to other plugins. cc-dice needs to be importable as a library. A package is the right abstraction -- consumable by plugins, scripts, hooks, or standalone tools.

### Decision: Separate repo, not monorepo

**Why**: Independent versioning, independent install, independent git history. cc-dice may get consumers beyond cc-reflection. It should stand alone.

---

## Environment Variables

| Variable | Purpose | Set by |
|----------|---------|--------|
| `CC_DICE_BASE` | Override base directory (default: `~/.claude/dice/`) | Test setup |
| `CC_DICE_SESSION_ID` | Session UUID for state isolation | SessionStart hook |
| `CC_REFLECTION_SESSION_ID` | Backward-compat session UUID | cc-reflection's SessionStart hook |
| `DEBUG` | Verbose logging to stderr when `"1"` | User |

---

## Testing

### Test Infrastructure

BATS (Bash Automated Testing System) with submodules:
```
tests/
  bats/                  # bats-core
  test_helper/
    bats-support/        # assertion helpers
    bats-assert/         # output assertions
  unit/
    test_cc_dice.bats    # 41 tests
```

### Test Isolation

All tests use temp directories via `CC_DICE_BASE` override:
```bash
setup() {
    export CC_DICE_BASE="$(mktemp -d)"
    mkdir -p "$CC_DICE_BASE/state"
    export TEST_SESSION_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
}
```

This ensures tests never touch `~/.claude/dice/`.

### Running Tests

```bash
./tests/bats/bin/bats tests/unit/test_cc_dice.bats
# or
bun test
```

---

## File Map

```
cc-dice/
  package.json              Package config (bun-only)
  tsconfig.json             TypeScript config
  README.md                 User-facing docs
  CLAUDE.md                 This file (development journal)
  install.sh                Install wizard (symlinks, hook registration)

  src/
    index.ts       228 lines  Public API + high-level functions (checkSlot, etc.)
    types.ts        57 lines  All interfaces
    registry.ts     80 lines  Slot CRUD + file persistence
    roll.ts         65 lines  Pure rolling + target checking + probability
    accumulator.ts  47 lines  Depth-based dice count calculation
    state.ts        67 lines  Per-slot per-session state persistence
    cooldown.ts     48 lines  Per-session trigger markers
    transcript.ts   90 lines  Claude Code JSONL parser (default depth provider)
    session.ts      85 lines  Session ID resolution
    hook-helpers.ts 55 lines  Stdin parsing + exit code handling

  bin/
    cc-dice.ts     300 lines  CLI (register, status, roll, reset, clear, check)

  hooks/
    stop.ts         72 lines  Generic stop hook (checks all slots)

  tests/
    unit/
      test_cc_dice.bats  41 tests
```

---

## Commands Reference

### CLI

```bash
cc-dice register <name> [opts]    Register a dice slot
cc-dice unregister <name>         Remove a slot
cc-dice list                      List all registered slots
cc-dice status <name> [path]      Show current dice status
cc-dice roll <name> [path]        Dry-run roll (no state change)
cc-dice reset <name> [path]       Reset accumulator
cc-dice clear <name> [path]       Clear state completely
cc-dice session-start             Clear all auto-clear slots
cc-dice check [path]              Check all slots (stop hook mode)
```

### Installation

```bash
./install.sh                      Install (symlinks + directories)
./install.sh check                Verify installation
./install.sh uninstall            Remove installation
```

### Development

```bash
bun test                          Run all 41 tests
bun link                          Register for local development
DEBUG=1 bun hooks/stop.ts         Run stop hook with verbose logging
```
