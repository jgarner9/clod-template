#!/usr/bin/env bash
# Runs install.sh against a throwaway HOME with a fake claude that records
# the MCP calls, and checks what lands where. Run from anywhere: tests/run.sh

set -uo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/clod-test.XXXXXX")
trap 'rm -rf "$work"' EXIT

fails=0
check() {
	if eval "$2"; then
		printf 'ok   %s\n' "$1"
	else
		printf 'FAIL %s\n' "$1"
		fails=$((fails + 1))
	fi
}

# a copy of the repo with a rule, a skill, a setting and a server to install
src="$work/clod"
mkdir -p "$src"
cp -R "$repo/install.sh" "$repo/claude" "$src/"
mkdir -p "$src/claude/skills/hello"
printf 'say hi\n' >"$src/claude/skills/hello/SKILL.md"
cat >"$src/claude/settings.json" <<'EOF'
{ "$schema": "x", "permissions": { "allow": ["Bash(rg *)"] }, "theme": "dark" }
EOF
cat >"$src/claude/mcp.json" <<'EOF'
{ "servers": { "docs": { "type": "http", "url": "https://example.com/mcp" } } }
EOF

export HOME="$work/home"
export XDG_STATE_HOME="$HOME/.local/state"
unset CLAUDE_CONFIG_DIR
mkdir -p "$HOME/.claude"
cat >"$HOME/.claude/settings.json" <<'EOF'
{ "permissions": { "allow": ["Read(*)"] }, "model": "opus" }
EOF
printf 'mine\n' >"$HOME/.claude/agents-mine.md"
mkdir -p "$HOME/.claude/agents"
printf 'mine\n' >"$HOME/.claude/agents/mine.md"

# fake claude: mcp get fails for servers it hasn't added, add-json records
fake="$work/bin"
mkdir -p "$fake"
cat >"$fake/claude" <<'EOF'
#!/usr/bin/env bash
log="$HOME/claude.log"
case "$1 $2" in
"mcp get") grep -qx "added $3" "$log" 2>/dev/null ;;
"mcp add-json") echo "added $5" >>"$log" ;;
"mcp remove") echo "removed $5" >>"$log" ;;
esac
EOF
chmod +x "$fake/claude"
export PATH="$fake:$PATH"
export CLOD_CLAUDE="$fake/claude"

claude_dir="$HOME/.claude"

# --dry-run changes nothing
"$src/install.sh" --dry-run >/dev/null
check "dry run writes no rule" '[ ! -e "$claude_dir/rules/clod/example.md" ]'
check "dry run adds no server" '[ ! -e "$HOME/claude.log" ]'

# install
"$src/install.sh" --yes >"$work/out" 2>&1 || { cat "$work/out"; exit 1; }
check "rule copied" '[ -f "$claude_dir/rules/clod/example.md" ]'
check "skill copied" '[ -f "$claude_dir/skills/hello/SKILL.md" ]'
check "settings keep yours" '[ "$(jq -r .model "$claude_dir/settings.json")" = opus ]'
check "settings add clod's" '[ "$(jq -r .theme "$claude_dir/settings.json")" = dark ]'
check "lists are joined" '[ "$(jq -c .permissions.allow "$claude_dir/settings.json")" = "[\"Read(*)\",\"Bash(rg *)\"]" ]'
check "no \$schema merged" '[ "$(jq -r ".\"\$schema\" // \"none\"" "$claude_dir/settings.json")" = none ]'
check "server added" 'grep -qx "added docs" "$HOME/claude.log"'
check "clod linked" '[ -L "$HOME/.local/bin/clod" ]'
check "your agent kept" '[ "$(cat "$claude_dir/agents/mine.md")" = mine ]'

# again: nothing new, no second add
"$src/install.sh" --yes >"$work/out2" 2>&1
check "second run adds the server once" '[ "$(grep -c "added docs" "$HOME/claude.log")" = 1 ]'

# a skill taken out of the repo is taken out of Claude Code
rm -rf "$src/claude/skills/hello"
"$src/install.sh" --yes >/dev/null 2>&1
check "dropped skill removed" '[ ! -e "$claude_dir/skills/hello/SKILL.md" ]'

# a file of yours where clod would write is left alone
mkdir -p "$src/claude/agents"
printf 'clods\n' >"$src/claude/agents/mine.md"
"$src/install.sh" --yes >/dev/null 2>"$work/err"
check "your file not overwritten" '[ "$(cat "$claude_dir/agents/mine.md")" = mine ]'
check "and it says so" 'grep -q "is yours" "$work/err"'

# status and uninstall
status_out=$("$src/install.sh" status)
check "status lists the rule" 'printf "%s" "$status_out" | grep -q "rules/clod/example.md"'
"$src/install.sh" uninstall >/dev/null 2>&1
check "uninstall removes the rule" '[ ! -e "$claude_dir/rules/clod/example.md" ]'
check "uninstall removes the server" 'grep -qx "removed docs" "$HOME/claude.log"'
check "uninstall removes the link" '[ ! -e "$HOME/.local/bin/clod" ]'
check "uninstall keeps your agent" '[ -f "$claude_dir/agents/mine.md" ]'

# CLAUDE_CONFIG_DIR moves everything
export CLAUDE_CONFIG_DIR="$work/elsewhere"
"$src/install.sh" --yes >/dev/null 2>&1
check "CLAUDE_CONFIG_DIR is used" '[ -f "$CLAUDE_CONFIG_DIR/rules/clod/example.md" ]'

if [ "$fails" -gt 0 ]; then
	printf '%d failed\n' "$fails"
	exit 1
fi
printf 'all passed\n'
