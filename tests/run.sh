#!/usr/bin/env bash
# Runs install.sh against a throwaway HOME with a fake claude that records
# the MCP calls, and checks what lands where. Run from anywhere: tests/run.sh

set -uo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/clod-test.XXXXXX")
trap 'rm -rf "$work"' EXIT

fails=0
# check NAME COMMAND...: runs the command, and counts a failure if it fails
check() {
	local name=$1
	shift
	if "$@"; then
		printf 'ok   %s\n' "$name"
	else
		printf 'FAIL %s\n' "$name"
		fails=$((fails + 1))
	fi
}
same() { [ "$1" = "$2" ]; }
exists() { [ -e "$1" ] || [ -L "$1" ]; }
missing() { ! exists "$1"; }
has() { grep -q "$2" "$1" 2>/dev/null; }

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
check "dry run writes no rule" missing "$claude_dir/rules/clod/example.md"
check "dry run adds no server" missing "$HOME/claude.log"

# install
"$src/install.sh" --yes >"$work/out" 2>&1 || {
	cat "$work/out"
	exit 1
}
settings="$claude_dir/settings.json"
check "rule copied" exists "$claude_dir/rules/clod/example.md"
check "skill copied" exists "$claude_dir/skills/hello/SKILL.md"
check "settings keep yours" same "$(jq -r .model "$settings")" opus
check "settings add clod's" same "$(jq -r .theme "$settings")" dark
check "lists are joined" same "$(jq -c .permissions.allow "$settings")" '["Read(*)","Bash(rg *)"]'
check "no \$schema merged" same "$(grep -c schema "$settings")" 0
check "server added" has "$HOME/claude.log" "^added docs$"
check "clod linked" exists "$HOME/.local/bin/clod"
check "your agent kept" same "$(cat "$claude_dir/agents/mine.md")" mine

# again: nothing new, no second add
"$src/install.sh" --yes >"$work/out2" 2>&1
check "second run adds the server once" same "$(grep -c "added docs" "$HOME/claude.log")" 1

# a skill taken out of the repo is taken out of Claude Code
rm -rf "$src/claude/skills/hello"
"$src/install.sh" --yes >/dev/null 2>&1
check "dropped skill removed" missing "$claude_dir/skills/hello/SKILL.md"

# a file of yours where clod would write is left alone
mkdir -p "$src/claude/agents"
printf 'clods\n' >"$src/claude/agents/mine.md"
"$src/install.sh" --yes >/dev/null 2>"$work/err"
check "your file not overwritten" same "$(cat "$claude_dir/agents/mine.md")" mine
check "and it says so" has "$work/err" "is yours"

# status and uninstall
"$src/install.sh" status >"$work/status"
check "status lists the rule" has "$work/status" "rules/clod/example.md"
"$src/install.sh" uninstall >/dev/null 2>&1
check "uninstall removes the rule" missing "$claude_dir/rules/clod/example.md"
check "uninstall removes the server" has "$HOME/claude.log" "^removed docs$"
check "uninstall removes the link" missing "$HOME/.local/bin/clod"
check "uninstall keeps your agent" exists "$claude_dir/agents/mine.md"

# CLAUDE_CONFIG_DIR moves everything
export CLAUDE_CONFIG_DIR="$work/elsewhere"
"$src/install.sh" --yes >/dev/null 2>&1
check "CLAUDE_CONFIG_DIR is used" exists "$CLAUDE_CONFIG_DIR/rules/clod/example.md"

if [ "$fails" -gt 0 ]; then
	printf '%d failed\n' "$fails"
	exit 1
fi
printf 'all passed\n'
