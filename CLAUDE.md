# CC-Dice

Probabilistic dice trigger system for Claude Code hooks.

## Project Layout

- `src/` — Core library (index.ts is the public API)
- `bin/cc-dice.ts` — CLI entrypoint
- `hooks/` — Claude Code hook scripts (stop, session-start)
- `install.sh` — Installer (symlinks, hook registration, dependency checks)
- `tests/unit/test_cc_dice.bats` — BATS test suite
- `docs/architecture.md` — Architecture, design decisions, origin story

## Development

```bash
bun install                  # install dev dependencies
bun test                     # run test suite
./install.sh check           # verify installation
DEBUG=1 bun hooks/stop.ts    # run stop hook with verbose logging
```

## Key Concepts

- **Slots**: Named dice configurations persisted to `~/.claude/dice/slots.json`
- **Shared pools**: `checkAllSlots()` groups slots by die size, rolls one base die per group
- **Session isolation**: State is per-slot AND per-session via `CC_DICE_SESSION_ID`
- **Hook exit codes**: `0` = silent, `2` = stderr shown to Claude

## Testing

Tests use BATS with git submodules. All tests are isolated via `CC_DICE_BASE` temp directories.

```bash
git submodule update --init --recursive   # if submodules missing
bun test
```

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `CC_DICE_BASE` | Override base directory (default: `~/.claude/dice/`) |
| `CC_DICE_SESSION_ID` | Override session ID |
| `DEBUG=1` | Verbose logging to stderr |
