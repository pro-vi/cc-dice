#!/usr/bin/env bats

# cc-dice BATS tests
# Tests registration, accumulator, rolling, state, cooldown, session-start, CLI

BATS_TEST_DIRNAME="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
PROJ_DIR="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
CLI="$PROJ_DIR/bin/cc-dice.ts"

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

setup() {
    export CC_DICE_BASE="$(mktemp -d)"
    mkdir -p "$CC_DICE_BASE/state"
    # Use a UUID-like format so extractSessionFromPath matches correctly
    # This mimics real Claude Code transcript paths
    export TEST_SESSION_ID="abcdef01-2345-6789-abcd-ef$(printf '%06x' $$)"
    # Also set env var as fallback
    export CC_DICE_SESSION_ID="$TEST_SESSION_ID"
    unset CC_REFLECTION_SESSION_ID
}

teardown() {
    rm -rf "$CC_DICE_BASE"
}

# Helper: create a test transcript with N user messages
create_transcript() {
    local path="$1"
    local count="${2:-0}"
    > "$path"
    for ((i=1; i<=count; i++)); do
        echo '{"type":"user","message":{"role":"user","content":"message '$i'"}}' >> "$path"
        echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"response '$i'"}]}}' >> "$path"
    done
}

# ============================================================================
# Registration Tests
# ============================================================================

@test "register: creates slot with defaults" {
    run bun "$CLI" register test-slot --die 20 --target 20 --message "Test trigger"
    assert_success
    assert_output --partial "Registered slot: test-slot"

    # Verify slots.json was created
    [ -f "$CC_DICE_BASE/slots.json" ]

    # Verify slot data
    run bun -e "
        const slots = JSON.parse(await Bun.file('$CC_DICE_BASE/slots.json').text());
        const s = slots['test-slot'];
        console.log(s.name, s.die, s.target, s.targetMode, s.type);
        console.log(s.accumulationRate, s.maxDice, s.cooldown);
        console.log(s.clearOnSessionStart, s.resetOnTrigger);
    "
    assert_success
    assert_line --index 0 "test-slot 20 20 exact accumulator"
    assert_line --index 1 "7 100 per-session"
    assert_line --index 2 "true true"
}

@test "register: custom options" {
    run bun "$CLI" register custom-slot \
        --die 6 --target 1 --target-mode lte \
        --type fixed --fixed-count 3 \
        --cooldown none --no-clear-on-start --no-reset-on-trigger \
        --message "Custom trigger"
    assert_success

    run bun -e "
        const slots = JSON.parse(await Bun.file('$CC_DICE_BASE/slots.json').text());
        const s = slots['custom-slot'];
        console.log(s.die, s.target, s.targetMode);
        console.log(s.type, s.fixedCount);
        console.log(s.cooldown, s.clearOnSessionStart, s.resetOnTrigger);
    "
    assert_success
    assert_line --index 0 "6 1 lte"
    assert_line --index 1 "fixed 3"
    assert_line --index 2 "none false false"
}

@test "register: overwrites existing slot" {
    bun "$CLI" register my-slot --die 20 --target 20 --message "First"
    bun "$CLI" register my-slot --die 6 --target 6 --message "Second"

    run bun -e "
        const slots = JSON.parse(await Bun.file('$CC_DICE_BASE/slots.json').text());
        console.log(Object.keys(slots).length);
        console.log(slots['my-slot'].die);
    "
    assert_success
    assert_line --index 0 "1"
    assert_line --index 1 "6"
}

@test "list: shows registered slots" {
    bun "$CLI" register slot-a --die 20 --target 20 --message "A"
    bun "$CLI" register slot-b --die 6 --target 1 --target-mode lte --message "B"

    run bun "$CLI" list
    assert_success
    assert_output --partial "slot-a"
    assert_output --partial "slot-b"
}

@test "list: empty when no slots" {
    run bun "$CLI" list
    assert_success
    assert_output --partial "No slots registered"
}

@test "unregister: removes slot" {
    bun "$CLI" register temp-slot --die 20 --target 20 --message "Temp"
    run bun "$CLI" unregister temp-slot
    assert_success
    assert_output --partial "Removed slot: temp-slot"

    run bun "$CLI" list
    assert_output --partial "No slots registered"
}

@test "unregister: fails for nonexistent slot" {
    run bun "$CLI" unregister nonexistent
    assert_failure
    assert_output --partial "Slot not found"
}

# ============================================================================
# Accumulator Tests
# ============================================================================

@test "accumulator: 0 dice for <7 turns" {
    local transcript="$CC_DICE_BASE/${TEST_SESSION_ID}.jsonl"
    create_transcript "$transcript" 5

    bun "$CLI" register acc-test --die 20 --target 20 --message "Trigger"

    run bun "$CLI" status acc-test "$transcript"
    assert_success
    assert_output --partial "Dice count:      0"
}

@test "accumulator: 1 die for 7 turns" {
    local transcript="$CC_DICE_BASE/${TEST_SESSION_ID}.jsonl"
    create_transcript "$transcript" 7

    bun "$CLI" register acc-test --die 20 --target 20 --message "Trigger"

    run bun "$CLI" status acc-test "$transcript"
    assert_success
    assert_output --partial "Dice count:      1"
}

@test "accumulator: 2 dice for 14 turns" {
    local transcript="$CC_DICE_BASE/${TEST_SESSION_ID}.jsonl"
    create_transcript "$transcript" 14

    bun "$CLI" register acc-test --die 20 --target 20 --message "Trigger"

    run bun "$CLI" status acc-test "$transcript"
    assert_success
    assert_output --partial "Dice count:      2"
}

@test "accumulator: 3 dice for 21 turns" {
    local transcript="$CC_DICE_BASE/${TEST_SESSION_ID}.jsonl"
    create_transcript "$transcript" 21

    bun "$CLI" register acc-test --die 20 --target 20 --message "Trigger"

    run bun "$CLI" status acc-test "$transcript"
    assert_success
    assert_output --partial "Dice count:      3"
}

@test "accumulator: max dice capped" {
    local transcript="$CC_DICE_BASE/${TEST_SESSION_ID}.jsonl"
    create_transcript "$transcript" 100

    bun "$CLI" register acc-test --die 20 --target 20 --max-dice 5 --message "Trigger"

    run bun "$CLI" status acc-test "$transcript"
    assert_success
    assert_output --partial "Dice count:      5"
}

# ============================================================================
# Rolling Tests
# ============================================================================

@test "roll: returns valid numbers for d20" {
    run bun -e "
        import { rollDice } from '$PROJ_DIR/src/roll';
        const rolls = rollDice(10, 20);
        const valid = rolls.every(r => r >= 1 && r <= 20);
        console.log('count:', rolls.length, 'valid:', valid);
    "
    assert_success
    assert_output --partial "count: 10 valid: true"
}

@test "roll: returns valid numbers for d6" {
    run bun -e "
        import { rollDice } from '$PROJ_DIR/src/roll';
        const rolls = rollDice(5, 6);
        const valid = rolls.every(r => r >= 1 && r <= 6);
        console.log('count:', rolls.length, 'valid:', valid);
    "
    assert_success
    assert_output --partial "count: 5 valid: true"
}

@test "roll: 0 count returns empty" {
    run bun -e "
        import { rollDice } from '$PROJ_DIR/src/roll';
        const rolls = rollDice(0, 20);
        console.log('count:', rolls.length);
    "
    assert_success
    assert_output --partial "count: 0"
}

@test "target check: exact mode" {
    run bun -e "
        import { checkTarget } from '$PROJ_DIR/src/roll';
        console.log(checkTarget([5, 10, 20], 20, 'exact'));
        console.log(checkTarget([5, 10, 15], 20, 'exact'));
    "
    assert_success
    assert_line --index 0 "true"
    assert_line --index 1 "false"
}

@test "target check: gte mode" {
    run bun -e "
        import { checkTarget } from '$PROJ_DIR/src/roll';
        console.log(checkTarget([5, 10, 15], 15, 'gte'));
        console.log(checkTarget([5, 10, 14], 15, 'gte'));
    "
    assert_success
    assert_line --index 0 "true"
    assert_line --index 1 "false"
}

@test "target check: lte mode" {
    run bun -e "
        import { checkTarget } from '$PROJ_DIR/src/roll';
        console.log(checkTarget([5, 10, 15], 5, 'lte'));
        console.log(checkTarget([6, 10, 15], 5, 'lte'));
    "
    assert_success
    assert_line --index 0 "true"
    assert_line --index 1 "false"
}

@test "target check: empty rolls returns false" {
    run bun -e "
        import { checkTarget } from '$PROJ_DIR/src/roll';
        console.log(checkTarget([], 20, 'exact'));
    "
    assert_success
    assert_output "false"
}

@test "probability: 1d20 exact 20 is 5%" {
    run bun -e "
        import { calculateProbability } from '$PROJ_DIR/src/roll';
        console.log(calculateProbability(1, 20, 20, 'exact'));
    "
    assert_success
    assert_output "5"
}

@test "probability: 0 dice is 0%" {
    run bun -e "
        import { calculateProbability } from '$PROJ_DIR/src/roll';
        console.log(calculateProbability(0, 20, 20, 'exact'));
    "
    assert_success
    assert_output "0"
}

# ============================================================================
# State Tests
# ============================================================================

@test "state: per-session isolation" {
    local transcript_a="$CC_DICE_BASE/session-a.jsonl"
    local transcript_b="$CC_DICE_BASE/session-b.jsonl"
    create_transcript "$transcript_a" 14
    create_transcript "$transcript_b" 7

    bun "$CLI" register iso-test --die 20 --target 20 --message "Trigger"

    run bun "$CLI" status iso-test "$transcript_a"
    assert_output --partial "Dice count:      2"

    run bun "$CLI" status iso-test "$transcript_b"
    assert_output --partial "Dice count:      1"
}

@test "state: reset sets depth" {
    local transcript="$CC_DICE_BASE/${TEST_SESSION_ID}.jsonl"
    create_transcript "$transcript" 14

    bun "$CLI" register reset-test --die 20 --target 20 --message "Trigger"

    # Should have 2 dice at depth 14
    run bun "$CLI" status reset-test "$transcript"
    assert_output --partial "Dice count:      2"

    # Reset at depth 14
    bun "$CLI" reset reset-test "$transcript"

    # Should have 0 dice now
    run bun "$CLI" status reset-test "$transcript"
    assert_output --partial "Dice count:      0"
}

@test "state: clear resets to 0" {
    local transcript="$CC_DICE_BASE/${TEST_SESSION_ID}.jsonl"
    create_transcript "$transcript" 14

    bun "$CLI" register clear-test --die 20 --target 20 --message "Trigger"

    # Reset to depth 14
    bun "$CLI" reset clear-test "$transcript"

    # Verify reset worked (state file should have depth 14)
    run bun -e "
        const state = JSON.parse(await Bun.file('$CC_DICE_BASE/state/clear-test-${TEST_SESSION_ID}.json').text());
        console.log('depth:', state.depth_at_last_trigger);
    "
    assert_output --partial "depth: 14"

    # Clear back to 0
    bun "$CLI" clear clear-test "$transcript"

    run bun -e "
        const state = JSON.parse(await Bun.file('$CC_DICE_BASE/state/clear-test-${TEST_SESSION_ID}.json').text());
        console.log('depth:', state.depth_at_last_trigger);
    "
    assert_output --partial "depth: 0"
}

@test "state: sentinel -1 calibration" {
    local transcript="$CC_DICE_BASE/${TEST_SESSION_ID}.jsonl"
    create_transcript "$transcript" 21

    bun "$CLI" register sentinel-test --die 20 --target 20 --message "Trigger"

    # Manually write state with sentinel -1
    echo '{"depth_at_last_trigger": -1, "last_reset": "2025-01-01T00:00:00.000Z"}' \
        > "$CC_DICE_BASE/state/sentinel-test-${TEST_SESSION_ID}.json"

    # Status should calibrate: depth_at_last_trigger becomes 21, so dice = 0
    run bun "$CLI" status sentinel-test "$transcript"
    assert_output --partial "Dice count:      0"

    # Verify state was updated
    run bun -e "
        const state = JSON.parse(await Bun.file('$CC_DICE_BASE/state/sentinel-test-${TEST_SESSION_ID}.json').text());
        console.log('depth:', state.depth_at_last_trigger);
    "
    assert_output --partial "depth: 21"
}

# ============================================================================
# Cooldown Tests
# ============================================================================

@test "cooldown: marker prevents re-trigger" {
    bun "$CLI" register cd-test --die 20 --target 20 --cooldown per-session --message "Trigger"

    # Create a cooldown marker (no .json extension — matches cooldown.ts)
    echo "2025-01-01" > "$CC_DICE_BASE/state/triggered-cd-test-${TEST_SESSION_ID}"

    # checkSlot should return not triggered due to cooldown
    run bun -e "
        process.env.CC_DICE_BASE = '$CC_DICE_BASE';
        process.env.CC_DICE_SESSION_ID = '$TEST_SESSION_ID';
        const { checkSlot } = await import('$PROJ_DIR/src/index');
        const result = await checkSlot('cd-test', { sessionId: '$TEST_SESSION_ID' });
        console.log('triggered:', result.triggered, 'diceCount:', result.diceCount);
    "
    assert_success
    assert_output --partial "triggered: false diceCount: 0"
}

@test "cooldown: clear removes marker" {
    bun "$CLI" register cd-clear-test --die 20 --target 20 --message "Trigger"

    # Create marker (no .json extension — matches cooldown.ts)
    echo "2025-01-01" > "$CC_DICE_BASE/state/triggered-cd-clear-test-${TEST_SESSION_ID}"
    [ -f "$CC_DICE_BASE/state/triggered-cd-clear-test-${TEST_SESSION_ID}" ]

    # Clear should remove marker
    local transcript="$CC_DICE_BASE/${TEST_SESSION_ID}.jsonl"
    create_transcript "$transcript" 0
    bun "$CLI" clear cd-clear-test "$transcript"

    # Marker should be gone
    [ ! -f "$CC_DICE_BASE/state/triggered-cd-clear-test-${TEST_SESSION_ID}" ]
}

# ============================================================================
# Session Start Tests
# ============================================================================

@test "session-start: clears auto-clear slots" {
    # Register two slots: one auto-clear, one not
    bun "$CLI" register auto-slot --die 20 --target 20 --message "Auto"
    bun "$CLI" register manual-slot --die 20 --target 20 --no-clear-on-start --message "Manual"

    local transcript="$CC_DICE_BASE/${TEST_SESSION_ID}.jsonl"
    create_transcript "$transcript" 14

    # Set some state
    bun "$CLI" reset auto-slot "$transcript"
    bun "$CLI" reset manual-slot "$transcript"

    # Both should have depth 14 in state
    run bun -e "
        const auto = JSON.parse(await Bun.file('$CC_DICE_BASE/state/auto-slot-${TEST_SESSION_ID}.json').text());
        const manual = JSON.parse(await Bun.file('$CC_DICE_BASE/state/manual-slot-${TEST_SESSION_ID}.json').text());
        console.log('auto:', auto.depth_at_last_trigger, 'manual:', manual.depth_at_last_trigger);
    "
    assert_output --partial "auto: 14 manual: 14"

    # Session start
    run bun "$CLI" session-start "$transcript"
    assert_success
    assert_output --partial "auto-slot"
    refute_output --partial "manual-slot"

    # Auto-slot should be cleared to 0, manual should still be 14
    run bun -e "
        const auto = JSON.parse(await Bun.file('$CC_DICE_BASE/state/auto-slot-${TEST_SESSION_ID}.json').text());
        const manual = JSON.parse(await Bun.file('$CC_DICE_BASE/state/manual-slot-${TEST_SESSION_ID}.json').text());
        console.log('auto:', auto.depth_at_last_trigger, 'manual:', manual.depth_at_last_trigger);
    "
    assert_output --partial "auto: 0 manual: 14"
}

# ============================================================================
# CLI Tests
# ============================================================================

@test "cli: help shows usage" {
    run bun "$CLI" help
    assert_success
    assert_output --partial "Usage: cc-dice"
    assert_output --partial "register"
    assert_output --partial "status"
}

@test "cli: unknown command fails" {
    run bun "$CLI" foobar
    assert_failure
    assert_output --partial "Unknown command"
}

@test "cli: register without name fails" {
    run bun "$CLI" register
    assert_failure
    assert_output --partial "slot name required"
}

@test "cli: status without name fails" {
    run bun "$CLI" status
    assert_failure
    assert_output --partial "slot name required"
}

@test "cli: status for nonexistent slot fails" {
    run bun "$CLI" status nonexistent
    assert_failure
    assert_output --partial "Slot not found"
}

@test "cli: roll with slot" {
    local transcript="$CC_DICE_BASE/${TEST_SESSION_ID}.jsonl"
    create_transcript "$transcript" 14

    bun "$CLI" register roll-test --die 20 --target 20 --message "Trigger"

    run bun "$CLI" roll roll-test "$transcript"
    assert_success
    assert_output --partial "roll-test: 2d20"
}

@test "cli: roll with 0 dice" {
    local transcript="$CC_DICE_BASE/${TEST_SESSION_ID}.jsonl"
    create_transcript "$transcript" 3

    bun "$CLI" register roll-zero --die 20 --target 20 --message "Trigger"

    run bun "$CLI" roll roll-zero "$transcript"
    assert_success
    assert_output --partial "0 dice"
}

@test "cli: check with no slots exits 0" {
    run bun "$CLI" check
    assert_success
}

# ============================================================================
# Fixed & Single Dice Type Tests
# ============================================================================

@test "fixed: always rolls fixedCount dice" {
    bun "$CLI" register fixed-test --die 6 --target 6 --type fixed --fixed-count 3 --message "Trigger"

    run bun -e "
        process.env.CC_DICE_BASE = '$CC_DICE_BASE';
        const { getSlotStatus } = await import('$PROJ_DIR/src/index');
        const status = await getSlotStatus('fixed-test', { sessionId: 'test' });
        console.log('dice:', status.diceCount);
    "
    assert_success
    assert_output --partial "dice: 3"
}

@test "single: always rolls 1 die" {
    bun "$CLI" register single-test --die 20 --target 20 --type single --message "Trigger"

    run bun -e "
        process.env.CC_DICE_BASE = '$CC_DICE_BASE';
        const { getSlotStatus } = await import('$PROJ_DIR/src/index');
        const status = await getSlotStatus('single-test', { sessionId: 'test' });
        console.log('dice:', status.diceCount);
    "
    assert_success
    assert_output --partial "dice: 1"
}

# ============================================================================
# Transcript Counting Tests
# ============================================================================

@test "transcript: counts user messages correctly" {
    local transcript="$CC_DICE_BASE/test-transcript.jsonl"
    create_transcript "$transcript" 10

    run bun -e "
        import { countExchanges } from '$PROJ_DIR/src/transcript';
        const count = await countExchanges('$transcript');
        console.log('count:', count);
    "
    assert_success
    assert_output "count: 10"
}

@test "transcript: ignores toolUseResult entries" {
    local transcript="$CC_DICE_BASE/test-transcript.jsonl"
    echo '{"type":"user","message":{"role":"user","content":"hello"}}' > "$transcript"
    echo '{"type":"user","toolUseResult":true,"message":{"role":"user","content":"tool"}}' >> "$transcript"
    echo '{"type":"user","message":{"role":"user","content":"world"}}' >> "$transcript"

    run bun -e "
        import { countExchanges } from '$PROJ_DIR/src/transcript';
        const count = await countExchanges('$transcript');
        console.log('count:', count);
    "
    assert_success
    assert_output "count: 2"
}

@test "transcript: returns 0 for nonexistent file" {
    run bun -e "
        import { countExchanges } from '$PROJ_DIR/src/transcript';
        const count = await countExchanges('/nonexistent/path.jsonl');
        console.log('count:', count);
    "
    assert_success
    assert_output "count: 0"
}
