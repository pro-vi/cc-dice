#!/usr/bin/env bash

# CC-Dice Installer
# Installs the dice trigger system for Claude Code hooks

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DICE_BASE="${HOME}/.claude/dice"
HOOKS_DIR="${HOME}/.claude/hooks"
SETTINGS_FILE="${HOME}/.claude/settings.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}  CC-Dice Installer${NC}"
    echo -e "${BLUE}================================${NC}"
    echo ""
}

print_success() { echo -e "${GREEN}ok${NC} $1"; }
print_error()   { echo -e "${RED}err${NC} $1"; }
print_warning() { echo -e "${YELLOW}warn${NC} $1"; }
print_info()    { echo -e "${BLUE}info${NC} $1"; }

check_dependencies() {
    print_info "Checking dependencies..."
    local missing=()

    if ! command -v bun &> /dev/null; then
        missing+=("bun (runtime)")
    fi

    if ! command -v jq &> /dev/null; then
        missing+=("jq (JSON processing for settings.json)")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        print_error "Missing dependencies:"
        for dep in "${missing[@]}"; do
            echo "  - $dep"
        done
        echo ""
        echo "Install:"
        echo "  bun: curl -fsSL https://bun.sh/install | bash"
        echo "  jq:  brew install jq"
        return 1
    fi

    print_success "All dependencies found"
}

# ---- Hook registration helpers (same pattern as cc-reflection) ----

unregister_hook() {
    local event_name="$1"
    local grep_pattern="$2"

    if [ ! -f "$SETTINGS_FILE" ]; then return 0; fi
    if ! grep -q "$grep_pattern" "$SETTINGS_FILE" 2>/dev/null; then return 0; fi

    cp "$SETTINGS_FILE" "$SETTINGS_FILE.bak"
    local tmp_file=$(mktemp)
    if ! jq --arg event "$event_name" --arg pattern "$grep_pattern" '
        if .hooks[$event] then
            .hooks[$event] |= map(
                if .hooks then
                    .hooks |= map(select(.command | tostring | contains($pattern) | not))
                else . end
            ) | map(select(.hooks | length > 0))
        else . end
    ' "$SETTINGS_FILE" > "$tmp_file"; then
        rm -f "$tmp_file"
        print_error "Failed to parse settings.json (restored from backup)"
        cp "$SETTINGS_FILE.bak" "$SETTINGS_FILE"
        return 2
    fi
    mv "$tmp_file" "$SETTINGS_FILE"
}

register_hook() {
    local event_name="$1"
    local grep_pattern="$2"
    local hook_path="$3"

    if [ -f "$SETTINGS_FILE" ]; then
        # Remove old entry before adding new one
        if grep -q "$grep_pattern" "$SETTINGS_FILE" 2>/dev/null; then
            unregister_hook "$event_name" "$grep_pattern" || true
        fi

        cp "$SETTINGS_FILE" "$SETTINGS_FILE.bak"
        local quoted_path
        quoted_path=$(jq -nr --arg p "$hook_path" '$p | @sh')
        local hook_cmd="bun ${quoted_path}"
        local hook_obj
        hook_obj=$(jq -n --arg cmd "$hook_cmd" '{hooks: [{type: "command", command: $cmd}]}')
        local tmp_file=$(mktemp)
        if ! jq --arg event "$event_name" --argjson hook "$hook_obj" '
            .hooks[$event] = (
                if .hooks[$event] then
                    .hooks[$event] + [$hook]
                else
                    [$hook]
                end
            )
        ' "$SETTINGS_FILE" > "$tmp_file"; then
            rm -f "$tmp_file"
            print_error "Failed to parse settings.json (restored from backup)"
            cp "$SETTINGS_FILE.bak" "$SETTINGS_FILE"
            return 1
        fi
        mv "$tmp_file" "$SETTINGS_FILE"
        print_success "Registered $event_name hook in settings.json"
    else
        mkdir -p "$(dirname "$SETTINGS_FILE")"
        cat > "$SETTINGS_FILE" <<EOFJSON
{
  "hooks": {
    "${event_name}": [{"hooks": [{"type": "command", "command": "bun '${hook_path}'"}]}]
  }
}
EOFJSON
        print_success "Created settings.json with $event_name hook"
    fi
}

# ---- Installation ----

install_dice() {
    print_info "Installing cc-dice..."

    # Create directory structure
    mkdir -p "$DICE_BASE/state"
    mkdir -p "$HOOKS_DIR"
    print_success "Created $DICE_BASE"

    # Symlink the source module so hooks can import it
    ln -sf "$SCRIPT_DIR/src/index.ts" "$DICE_BASE/cc-dice.ts"
    print_success "Symlinked cc-dice module to $DICE_BASE/cc-dice.ts"

    # Symlink hooks
    ln -sf "$SCRIPT_DIR/hooks/stop.ts" "$HOOKS_DIR/stop-dice.ts"
    print_success "Symlinked stop hook to $HOOKS_DIR/stop-dice.ts"

    ln -sf "$SCRIPT_DIR/hooks/session-start.ts" "$HOOKS_DIR/dice-session-start.ts"
    print_success "Symlinked session-start hook to $HOOKS_DIR/dice-session-start.ts"

    # Symlink CLI
    local bin_dir="${HOME}/.local/bin"
    mkdir -p "$bin_dir"
    ln -sf "$SCRIPT_DIR/bin/cc-dice.ts" "$bin_dir/cc-dice"
    print_success "Symlinked CLI to $bin_dir/cc-dice"
}

register_hooks() {
    echo ""
    print_info "Registering hooks in settings.json..."
    register_hook "Stop" "stop-dice" "$HOOKS_DIR/stop-dice.ts"
    register_hook "SessionStart" "dice-session-start" "$HOOKS_DIR/dice-session-start.ts"
}

show_check() {
    echo ""
    echo "CC-Dice Installation Check"
    echo ""

    local errors=0
    local warnings=0

    # Check base dir
    if [ -d "$DICE_BASE" ]; then
        echo -e "  ${GREEN}ok${NC} Base directory: $DICE_BASE"
    else
        echo -e "  ${RED}err${NC} Base directory missing"
        errors=$((errors + 1))
    fi

    # Check module symlink
    if [ -L "$DICE_BASE/cc-dice.ts" ]; then
        echo -e "  ${GREEN}ok${NC} Module symlink"
    else
        echo -e "  ${YELLOW}warn${NC} Module not symlinked"
        warnings=$((warnings + 1))
    fi

    # Check stop hook
    if [ -f "$HOOKS_DIR/stop-dice.ts" ]; then
        echo -e "  ${GREEN}ok${NC} Stop hook file"
        if [ -f "$SETTINGS_FILE" ] && grep -q "stop-dice" "$SETTINGS_FILE" 2>/dev/null; then
            echo -e "  ${GREEN}ok${NC} Stop hook registered"
        else
            echo -e "  ${YELLOW}warn${NC} Stop hook not registered in settings.json"
            warnings=$((warnings + 1))
        fi
    else
        echo -e "  ${YELLOW}warn${NC} Stop hook not installed"
        warnings=$((warnings + 1))
    fi

    # Check session-start hook
    if [ -f "$HOOKS_DIR/dice-session-start.ts" ]; then
        echo -e "  ${GREEN}ok${NC} SessionStart hook file"
        if [ -f "$SETTINGS_FILE" ] && grep -q "dice-session-start" "$SETTINGS_FILE" 2>/dev/null; then
            echo -e "  ${GREEN}ok${NC} SessionStart hook registered"
        else
            echo -e "  ${YELLOW}warn${NC} SessionStart hook not registered"
            warnings=$((warnings + 1))
        fi
    else
        echo -e "  ${BLUE}info${NC} SessionStart hook not installed"
    fi

    # Check CLI
    if [ -L "${HOME}/.local/bin/cc-dice" ]; then
        echo -e "  ${GREEN}ok${NC} CLI symlink"
    else
        echo -e "  ${YELLOW}warn${NC} CLI not symlinked"
        warnings=$((warnings + 1))
    fi

    # Check slots
    if [ -f "$DICE_BASE/slots.json" ]; then
        local count
        count=$(jq 'length' "$DICE_BASE/slots.json" 2>/dev/null || echo "0")
        echo -e "  ${GREEN}ok${NC} Slots: $count registered"
    else
        echo -e "  ${BLUE}info${NC} No slots registered yet"
    fi

    echo ""
    if [ $errors -eq 0 ] && [ $warnings -eq 0 ]; then
        echo -e "${GREEN}Status: OK${NC}"
    elif [ $errors -eq 0 ]; then
        echo -e "${YELLOW}Status: OK with $warnings warning(s)${NC}"
    else
        echo -e "${RED}Status: $errors error(s), $warnings warning(s)${NC}"
    fi
    echo ""
}

uninstall() {
    print_info "Uninstalling cc-dice..."

    # Unregister hooks
    unregister_hook "Stop" "stop-dice" || true
    unregister_hook "SessionStart" "dice-session-start" || true

    # Remove hook files
    rm -f "$HOOKS_DIR/stop-dice.ts"
    rm -f "$HOOKS_DIR/dice-session-start.ts"
    print_success "Removed hooks"

    # Remove CLI
    rm -f "${HOME}/.local/bin/cc-dice"
    print_success "Removed CLI symlink"

    # Remove module symlink
    rm -f "$DICE_BASE/cc-dice.ts"

    echo ""
    read -p "Remove dice data ($DICE_BASE)? [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$DICE_BASE"
        print_success "Removed dice data"
    else
        print_info "Kept dice data at $DICE_BASE"
    fi

    print_success "Uninstall complete"
}

show_usage() {
    echo "Usage: ./install.sh [command]"
    echo ""
    echo "Commands:"
    echo "  (default)     Install cc-dice"
    echo "  uninstall     Remove installation"
    echo "  check         Verify installation"
    echo "  help          Show this help"
}

# ---- Main ----

print_header

case "${1:-}" in
    ""|install)
        if ! check_dependencies; then
            exit 1
        fi
        install_dice
        register_hooks
        echo ""
        print_success "Installation complete!"
        echo ""
        print_info "Next steps:"
        echo "  1. Register a slot:  bun cc-dice register my-slot --message 'Triggered!'"
        echo "  2. Verify:           ./install.sh check"
        echo ""
        ;;
    uninstall|-u)
        uninstall
        ;;
    check|-c)
        show_check
        ;;
    help|--help|-h)
        show_usage
        ;;
    *)
        print_error "Unknown command: $1"
        show_usage
        exit 1
        ;;
esac
